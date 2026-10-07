# =============================================================================
# File   : make_boot.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Make build/BOOT.bin for booting the Zybo Z7-10 from a microSD card
#          (no laptop/JTAG needed). BOOT.bin contains, in this order:
#            1. FSBL (first stage boot loader, built by Vitis with the platform):
#               sets up the PS (clocks, DDR, MIO/UART) like ps7_init does over JTAG
#            2. the FPGA bitstream (build/edge_ai_video.bit)
#            3. the ARM application (build/sw/<app>.elf), started after loading
#
# Usage (repo root, PowerShell):
#   .venv\Scripts\python.exe scripts/make_boot.py [--app roi_capture] [--copy-to G:\]
#   --copy-to copies BOOT.bin to the root of the FAT32 microSD card. Only BOOT.bin
#   is written; other files on the card are not touched.
# Board: set the boot-mode jumper (printed labels JTAG / QSPI / SD) to SD, insert the card, power on.
# =============================================================================
import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
BUILD = os.path.join(ROOT, "build")
FSBL = os.path.join(os.path.expanduser("~"), "fpga_ws", "fpga-edge-ai-video",
                    "zybo_platform", "export", "zybo_platform", "sw", "boot", "fsbl.elf")
BOOTGEN = os.environ.get("BOOTGEN", r"C:\Xilinx\2025.1\Vivado\bin\bootgen.bat")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", default="roi_capture", help="ARM app in build/sw/<app>.elf")
    ap.add_argument("--copy-to", default=None, help="microSD drive root, e.g. G:\\")
    args = ap.parse_args()

    bit = os.path.join(BUILD, "edge_ai_video.bit")
    elf = os.path.join(BUILD, "sw", f"{args.app}.elf")
    for f, how in ((FSBL, "run scripts/build_sw.py (it builds the FSBL with the platform)"),
                   (bit, "run scripts/build_hw.tcl"), (elf, f"run scripts/build_sw.py {args.app}")):
        if not os.path.isfile(f):
            sys.exit(f"ERROR: {f} not found: {how}")

    # bootgen does not like spaces in paths: work in a folder without spaces
    work = os.path.join(os.path.expanduser("~"), "fpga_ws", "boot")
    os.makedirs(work, exist_ok=True)
    for src, name in ((FSBL, "fsbl.elf"), (bit, "edge_ai_video.bit"), (elf, "app.elf")):
        shutil.copy(src, os.path.join(work, name))
    with open(os.path.join(work, "boot.bif"), "w") as f:
        f.write("the_ROM_image:\n{\n  [bootloader] fsbl.elf\n  edge_ai_video.bit\n  app.elf\n}\n")

    r = subprocess.run([BOOTGEN, "-image", "boot.bif", "-arch", "zynq", "-o", "BOOT.bin", "-w", "on"],
                       cwd=work, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.isfile(os.path.join(work, "BOOT.bin")):
        print(r.stdout[-2000:], r.stderr[-2000:])
        sys.exit("ERROR: bootgen failed")
    out = os.path.join(BUILD, "BOOT.bin")
    shutil.copy(os.path.join(work, "BOOT.bin"), out)
    print(f"INFO: ===== {out} ({os.path.getsize(out) / 1024:.0f} KB) = FSBL + bitstream + {args.app}.elf")

    if args.copy_to:
        dst = os.path.join(args.copy_to, "BOOT.bin")
        if os.path.exists(dst):
            print(f"INFO: replacing existing {dst}")
        shutil.copy(out, dst)
        print(f"INFO: copied to {dst}")


if __name__ == "__main__":
    main()
