# =============================================================================
# File   : sim_pixel_pipeline.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Image-based verification of rtl/pixel_pipeline.sv with Vivado xsim.
#
#   1. Make a 1280x720 test picture (color bars, gradients, a drawn digit in the ROI).
#   2. Turn it into a 2-frame 720p video stream file (with real blanking/sync).
#   3. Compile and run tb/tb_pixel_pipeline.sv in xsim for several test cases.
#   4. For each case check:
#        a) DE/HSYNC/VSYNC come out unchanged, delayed by exactly the pipeline latency
#        b) every visible output pixel of BOTH frames == Python reference model (bit-exact)
#   5. Save before/after pictures to docs/images/.
#
# Usage (from the repo root, in PowerShell):
#   .venv\Scripts\python.exe scripts/sim_pixel_pipeline.py
# Exit code 0 = all tests passed.
# =============================================================================
import os
import shutil
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import video_stream as vs  # noqa: E402

ROOT = vs.ROOT_DIR
SIM_DIR = os.path.join(ROOT, "build", "sim", "pixel_pipeline")
IMG_DIR = os.path.join(ROOT, "docs", "images")
VIVADO_BIN = os.environ.get("VIVADO_BIN", r"C:\Xilinx\2025.1\Vivado\bin")

# Sources in compile order (package first). top.sv is not needed here.
SOURCES = ["rtl/video_pkg.sv", "rtl/pix_pos_counter.sv", "rtl/rgb2gray.sv", "rtl/font_rom.sv",
           "rtl/roi_overlay.sv", "rtl/digit_overlay.sv", "rtl/pixel_pipeline.sv",
           "tb/tb_pixel_pipeline.sv"]

TESTS = [
    # name,          gray, overlay, roi_x0, roi_y0, digit
    ("color_overlay", 0,    1,       528,    248,    7),
    ("gray_overlay",  1,    1,       100,    60,     3),
    ("passthrough",   0,    0,       528,    248,    5),
]


def make_test_image():
    """Deterministic test picture with known colors, gradients and a handwritten-style digit."""
    h, w = vs.V_ACTIVE, vs.H_ACTIVE
    img = np.zeros((h, w, 3), dtype=np.uint8)
    # Top: 8 color bars
    bars = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
            (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
    for i, c in enumerate(bars):
        img[0:240, i * w // 8:(i + 1) * w // 8] = c
    # Middle: horizontal gray ramp
    img[240:480] = (np.arange(w) * 255 // (w - 1)).astype(np.uint8)[None, :, None]
    # Bottom: red changes with x, blue with y, green fixed
    xs = (np.arange(w) * 255 // (w - 1)).astype(np.uint8)
    ys = (np.arange(240) * 255 // 239).astype(np.uint8)
    img[480:, :, 0] = xs[None, :]
    img[480:, :, 1] = 64
    img[480:, :, 2] = ys[:, None]
    # ROI area: white "paper" with a thick dark "3", like the live demo (pen on a white screen)
    pil = Image.fromarray(img)
    d = ImageDraw.Draw(pil)
    d.rectangle([528, 248, 751, 471], fill=(255, 255, 255))
    d.arc([580, 270, 700, 370], start=180, end=90, fill=(20, 20, 20), width=18)
    d.arc([580, 355, 700, 455], start=270, end=180, fill=(20, 20, 20), width=18)
    return np.array(pil)


def run(cmd, log):
    with open(log, "w") as f:
        r = subprocess.run(cmd, cwd=SIM_DIR, stdout=f, stderr=subprocess.STDOUT)
    if r.returncode != 0:
        print(open(log).read()[-3000:])
        sys.exit(f"FAILED: {' '.join(cmd[:2])} (see {log})")


def compile_tb():
    with open(os.path.join(SIM_DIR, "sim.prj"), "w") as f:
        for s in SOURCES:
            # Relative paths from SIM_DIR: avoids the spaces in the absolute repo path.
            rel = os.path.relpath(os.path.join(ROOT, s), SIM_DIR).replace("\\", "/")
            f.write(f'sv xil_defaultlib "{rel}"\n')
    shutil.copy(vs.FONT_FILE, SIM_DIR)    # font_rom reads it from the working directory
    run([os.path.join(VIVADO_BIN, "xvlog.bat"), "-prj", "sim.prj"], os.path.join(SIM_DIR, "xvlog.log"))
    run([os.path.join(VIVADO_BIN, "xelab.bat"), "-timescale", "1ns/1ps", "-s", "tb_snap",
         "xil_defaultlib.tb_pixel_pipeline"], os.path.join(SIM_DIR, "xelab.log"))


def check(name, in_words, img, gray, overlay, roi_x0, roi_y0, digit):
    out_words = vs.read_stream(os.path.join(SIM_DIR, "stream_out.txt"))
    errors = []

    # a) Timing signals: output line (i + LATENCY - 1) must equal input line i.
    #    (The TB samples the output just after the clock edge where input i entered
    #    stage 1, so a 4-stage pipeline shows up as a shift of 3 lines.)
    shift = vs.LATENCY - 1
    sync_mask = vs.DE_BIT | vs.HS_BIT | vs.VS_BIT
    n = len(in_words)
    got = out_words[shift:shift + n]
    if len(got) != n or np.any(got < 0):
        errors.append(f"output stream too short or has unknown values ({len(got)} of {n})")
    else:
        bad = np.nonzero((got & sync_mask) != (in_words.astype(np.int64) & sync_mask))[0]
        if len(bad):
            errors.append(f"timing signals differ at {len(bad)} clocks (first at clock {bad[0]})")

    # b) Pixels of each frame vs the reference model
    ref = vs.reference_pipeline(img, gray, overlay, roi_x0, roi_y0, digit)
    frames = vs.stream_to_frames(out_words)
    if len(frames) != 2:
        errors.append(f"expected 2 output frames, got {len(frames)}")
    for i, fr in enumerate(frames):
        diff = np.any(fr != ref, axis=-1)
        if diff.any():
            yx = np.argwhere(diff)[0]
            errors.append(f"frame {i}: {int(diff.sum())} pixels differ "
                          f"(first at x={yx[1]}, y={yx[0]}: got {fr[yx[0], yx[1]]}, expected {ref[yx[0], yx[1]]})")
    if frames:
        Image.fromarray(frames[-1]).save(os.path.join(IMG_DIR, f"phase2_sim_{name}.png"))
    return errors


def main():
    os.makedirs(SIM_DIR, exist_ok=True)
    os.makedirs(IMG_DIR, exist_ok=True)

    img = make_test_image()
    Image.fromarray(img).save(os.path.join(IMG_DIR, "phase2_sim_input.png"))
    one = vs.frame_words(img)
    in_words = np.concatenate([one, one])           # 2 frames: also tests frame re-sync
    vs.write_stream(os.path.join(SIM_DIR, "stream_in.txt"), in_words)
    print(f"Input stream: {len(in_words):,} clocks (2 frames of {vs.H_TOTAL}x{vs.V_TOTAL})")

    t0 = time.time()
    compile_tb()
    print(f"Compiled in {time.time() - t0:.1f} s")

    all_ok = True
    for name, gray, overlay, rx, ry, digit in TESTS:
        t0 = time.time()
        args = [os.path.join(VIVADO_BIN, "xsim.bat"), "tb_snap", "-runall",
                "-testplusarg", f"gray{gray}", "-testplusarg", f"overlay{overlay}",
                "-testplusarg", f"roix{rx}", "-testplusarg", f"roiy{ry}",
                "-testplusarg", f"digit{digit}"]
        run(args, os.path.join(SIM_DIR, f"xsim_{name}.log"))
        errors = check(name, in_words, img, gray, overlay, rx, ry, digit)
        status = "PASS" if not errors else "FAIL"
        all_ok &= not errors
        print(f"[{status}] {name:14s} gray={gray} overlay={overlay} roi=({rx},{ry}) digit={digit}"
              f"  ({time.time() - t0:.1f} s)")
        for e in errors:
            print("        " + e)

    print("ALL TESTS PASSED" if all_ok else "SOME TESTS FAILED")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
