# =============================================================================
# File   : build_sw.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Build the bare-metal ARM software with the Vitis 2025.1 Python API.
#          Creates a platform from build/edge_ai_video.xsa, a standalone domain
#          for Cortex-A9 core 0, and one application per folder in sw/.
#
# Usage (from the repo root):
#   C:\Xilinx\2025.1\Vitis\bin\vitis.bat -s scripts/build_sw.py [app_name]
#   app_name defaults to "hello" (= folder sw/hello).
#
# The Vitis workspace is placed OUTSIDE the repo, in ~/fpga_ws/fpga-edge-ai-video,
# because the repo path contains spaces and the Vitis make/cmake flow does not
# handle spaces well. Sources are copied (imported) from sw/<app_name>/.
#
# Output: build/sw/<app_name>.elf and build/hw/ps7_init.tcl (for scripts/program.tcl)
# =============================================================================
import os
import sys
import glob
import shutil
import zipfile

import vitis

APP_NAME  = sys.argv[1] if len(sys.argv) > 1 else "hello"
ROOT_DIR  = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
XSA       = os.path.join(ROOT_DIR, "build", "edge_ai_video.xsa")
SRC_DIR   = os.path.join(ROOT_DIR, "sw", APP_NAME)
OUT_SW    = os.path.join(ROOT_DIR, "build", "sw")
OUT_HW    = os.path.join(ROOT_DIR, "build", "hw")
WORKSPACE = os.path.join(os.path.expanduser("~"), "fpga_ws", "fpga-edge-ai-video")
PLATFORM  = "zybo_platform"
DOMAIN    = "standalone_a9_0"

if not os.path.isfile(XSA):
    sys.exit(f"ERROR: {XSA} not found. Run scripts/build_hw.tcl first.")
if not os.path.isdir(SRC_DIR):
    sys.exit(f"ERROR: source folder {SRC_DIR} not found.")

# Extract ps7_init.tcl (PS clock/DDR/MIO setup) from the XSA for xsdb.
os.makedirs(OUT_HW, exist_ok=True)
with zipfile.ZipFile(XSA) as z:
    for name in z.namelist():
        if os.path.basename(name) in ("ps7_init.tcl", "ps7_init.c", "ps7_init.h"):
            with open(os.path.join(OUT_HW, os.path.basename(name)), "wb") as f:
                f.write(z.read(name))

# Fresh workspace every time (the build is fully reproducible from the repo).
if os.path.isdir(WORKSPACE):
    shutil.rmtree(WORKSPACE)
os.makedirs(WORKSPACE)

client = vitis.create_client()
client.set_workspace(path=WORKSPACE)

platform = client.create_platform_component(name=PLATFORM, hw_design=XSA,
                                            os="standalone", cpu="ps7_cortexa9_0",
                                            domain_name=DOMAIN)
platform.build()

xpfm = client.find_platform_in_repos(PLATFORM)
app = client.create_app_component(name=APP_NAME, platform=xpfm, domain=DOMAIN)
src_files = [os.path.basename(p) for p in glob.glob(os.path.join(SRC_DIR, "*.[ch]"))]
app.import_files(from_loc=SRC_DIR, files=src_files, dest_dir_in_cmp="src")
app.build()

# Copy the ELF to build/sw/
elfs = glob.glob(os.path.join(WORKSPACE, APP_NAME, "build", "*.elf"))
if not elfs:
    sys.exit("ERROR: no ELF produced")
os.makedirs(OUT_SW, exist_ok=True)
shutil.copy(elfs[0], os.path.join(OUT_SW, APP_NAME + ".elf"))
print(f"INFO: ===== SW BUILD DONE: build/sw/{APP_NAME}.elf")

vitis.dispose()
