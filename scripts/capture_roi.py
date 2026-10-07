# =============================================================================
# File   : capture_roi.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Save real 28x28 ROI captures from the board (sw/roi_capture on the ARM)
#          as labeled PNG files in ml/captures/, for testing and fine-tuning the CNN.
#          Also runs the integer golden model on each capture, so you immediately
#          see what the CNN would predict for that exact input.
#
# Usage (repo root, PowerShell; close PuTTY first, only one program can use the port):
#   .venv\Scripts\python.exe scripts/capture_roi.py --port COM17
#
# At the prompt:
#   0..9   draw that digit in the box on the laptop, then type the digit + Enter:
#          capture, save as ml/captures/<digit>_<time>.png
#   Enter  capture without saving (just look)
#   i t + - s   send that command to the board (invert, threshold on/off, threshold +/-, status)
#   q      quit
# =============================================================================
import argparse
import os
import sys
import time

import numpy as np
import serial
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT_DIR = os.path.join(ROOT, "ml", "captures")
sys.path.insert(0, os.path.join(ROOT, "ml"))


def read_line(ser, timeout=3.0):
    end = time.time() + timeout
    buf = b""
    while time.time() < end:
        buf += ser.read(ser.in_waiting or 1)
        if b"\n" in buf:
            line, _, rest = buf.partition(b"\n")
            return line.decode(errors="replace").strip()
    return buf.decode(errors="replace").strip()


def capture(ser):
    ser.reset_input_buffer()
    ser.write(b"c")
    for _ in range(20):          # skip live "PRED" lines until the ROI line arrives
        line = read_line(ser)
        if line.startswith("ROI "):
            hexdata = line[4:].strip()
            if len(hexdata) != 784 * 2:
                print(f"  bad capture length {len(hexdata)}")
                return None
            return np.frombuffer(bytes.fromhex(hexdata), dtype=np.uint8).reshape(28, 28)
        if line.startswith("ERR"):
            print("  board says:", line)
            return None
    print("  no answer from the board (is sw/roi_capture running? right COM port?)")
    return None


def ascii_art(img):
    chars = " .:-=+*#%@"
    for row in img:
        print("  " + "".join(chars[min(9, int(v) * 10 // 256)] * 2 for v in row))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True, help="board UART, e.g. COM17")
    ap.add_argument("--once", default=None, metavar="LABEL",
                    help="capture one image and exit; LABEL 0-9 saves it, 'x' only shows it")
    args = ap.parse_args()

    try:
        import golden_int
        q = golden_int.load_params()
    except Exception as e:                          # model not exported yet: still capture
        print("(golden model not available:", e, ")")
        golden_int, q = None, None

    os.makedirs(OUT_DIR, exist_ok=True)
    with serial.Serial(args.port, 115200, timeout=0.1) as ser:
        ser.write(b"s")
        print(read_line(ser))
        while True:
            if args.once is not None:
                cmd = args.once if args.once != "x" else ""
            else:
                cmd = input("digit 0-9 to capture+save, Enter = capture only, i/t/+/-/s, q = quit > ").strip()
            if cmd == "q":
                break
            if cmd in ("i", "t", "+", "-", "s"):
                ser.write(cmd.encode())
                print(read_line(ser))
                continue
            img = capture(ser)
            if img is None:
                continue
            ascii_art(img)
            if golden_int is not None:
                r = golden_int.infer(img[None], q)
                print(f"  golden model predicts {int(r['digit'][0])} (confidence {int(r['conf'][0])}/255)")
            if cmd.isdigit() and len(cmd) == 1:
                name = f"{cmd}_{time.strftime('%Y%m%d_%H%M%S')}.png"
                Image.fromarray(img).save(os.path.join(OUT_DIR, name))
                print(f"  saved ml/captures/{name}")
            if args.once is not None:
                break


if __name__ == "__main__":
    main()
