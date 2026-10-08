# =============================================================================
# File   : build_sw.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Build the bare-metal ARM software with the Vitis 2025.1 Python API.
#          Creates a platform from build/edge_ai_video.xsa, a standalone domain
#          for Cortex-A9 core 0, and one application from a folder in sw/.
#
# Usage (from the repo root):
#   C:\Xilinx\2025.1\Vitis\bin\vitis.bat -s scripts/build_sw.py [app_name]
#   app_name defaults to "hello" (= folder sw/hello).
#
# Notes for this install (Windows, Vitis 2025.1):
#   - The Vitis workspace is OUTSIDE the repo, in ~/fpga_ws/fpga-edge-ai-video,
#     because the repo path contains spaces and the Vitis make/cmake flow does not
#     handle spaces well. Sources are copied (imported) from sw/<app_name>/.
#   - Needs the FULL "Vitis Unified Software Platform" edition with Zynq-7000 (ARM
#     toolchain in C:\Xilinx\2025.1\gnu\aarch32, lopper/sdtgen in Vitis\bin). With only
#     "Vivado ML Standard" installed, platform creation fails with the vague message
#     "Error in generating SDT" (full story in notes/PROGRESS.md / notes/HANDOVER.md).
#   - Vivado\bin is also added to PATH (harmless; vitis.bat only does it for the old
#     C:\Xilinx\Vivado\<ver> install layout).
#   - The XSA is copied to a path without spaces before Vitis reads it.
#
# Output: build/sw/<app_name>.elf and build/hw/ps7_init.tcl (for scripts/program.tcl)
# =============================================================================
import os
import re
import sys
import glob
import stat
import subprocess
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
HW_DIR    = WORKSPACE + "_hw"        # XSA copy + SDT, next to (not inside) the workspace
PLATFORM  = "zybo_platform"
DOMAIN    = "standalone_a9_0"

XILINX    = os.environ.get("XILINX_VITIS", r"C:/Xilinx/2025.1/Vitis")
VIVADO_BIN = os.path.normpath(os.path.join(os.path.dirname(XILINX), "Vivado", "bin"))

# Workaround for vitis.bat (see header): make lopper/sdtgen/xsdb findable. The Vitis
# server started by vitis.create_client() inherits this environment.
os.environ["PATH"] = VIVADO_BIN + os.pathsep + os.environ.get("PATH", "")

if not os.path.isfile(XSA):
    sys.exit(f"ERROR: {XSA} not found. Run scripts/build_hw.tcl first.")
if not os.path.isdir(SRC_DIR):
    sys.exit(f"ERROR: source folder {SRC_DIR} not found.")

# 1. Extract ps7_init.tcl (PS clock/DDR/MIO setup) from the XSA for xsdb.
os.makedirs(OUT_HW, exist_ok=True)
with zipfile.ZipFile(XSA) as z:
    for name in z.namelist():
        if os.path.basename(name) in ("ps7_init.tcl", "ps7_init.c", "ps7_init.h"):
            with open(os.path.join(OUT_HW, os.path.basename(name)), "wb") as f:
                f.write(z.read(name))

# 2. Fresh workspace and hardware folder every time (fully reproducible from the repo).
def _force_remove(func, path, _exc):
    # Vitis/sdtgen copy some header files as read-only; clear the flag and retry.
    os.chmod(path, stat.S_IWRITE)
    func(path)

for d in (WORKSPACE, HW_DIR):
    if os.path.isdir(d):
        shutil.rmtree(d, onexc=_force_remove)
os.makedirs(WORKSPACE)          # set_workspace() needs an empty folder
os.makedirs(HW_DIR)
xsa_copy = os.path.join(HW_DIR, "edge_ai_video.xsa")
shutil.copy(XSA, xsa_copy)

# 3. Platform (standalone BSP for Cortex-A9 #0) and application.
client = vitis.create_client()
try:
    client.set_workspace(path=WORKSPACE)

    platform = client.create_platform_component(name=PLATFORM, hw_design=xsa_copy,
                                                os="standalone", cpu="ps7_cortexa9_0",
                                                domain_name=DOMAIN)
    try:
        platform.build()
    except Exception as e:
        # Vitis 2025.1 sometimes builds the BSP without its final CMake configure pass, so
        # the driver headers (xscugic.h, ...) are never copied into the BSP include folder
        # and the build stops with the vague "Application error processing RPC".
        # Fix: re-run CMake configure + ninja in each BSP build folder, then build again.
        print(f"WARNING: platform build failed ({str(e).splitlines()[0]}); re-configuring BSPs and retrying")
        tools = [os.path.join(os.path.dirname(XILINX), "gnu", "aarch32", "nt", "gcc-arm-none-eabi", "bin"),
                 os.path.join(XILINX, "bin"),
                 os.path.join(os.path.dirname(XILINX), "tps", "win64", "cmake-3.24.2", "bin")]
        env = dict(os.environ, PATH=os.pathsep.join(tools) + os.pathsep + os.environ.get("PATH", ""))
        for gen in glob.glob(os.path.join(WORKSPACE, PLATFORM, "**", "build_configs", "gen_bsp"), recursive=True):
            for cmd in (["cmake", "."], ["ninja"]):
                r = subprocess.run(cmd, cwd=gen, env=env, capture_output=True, text=True, shell=True)
                if r.returncode != 0:
                    sys.exit(f"ERROR: {' '.join(cmd)} failed in {gen}:\n{r.stdout[-2000:]}{r.stderr[-2000:]}")
            print(f"INFO: BSP rebuilt by hand: {gen}")
        platform.build()

    xpfm = client.find_platform_in_repos(PLATFORM)
    app = client.create_app_component(name=APP_NAME, platform=xpfm, domain=DOMAIN)
    src_files = [os.path.basename(p) for p in glob.glob(os.path.join(SRC_DIR, "*.[ch]"))]
    app.import_files(from_loc=SRC_DIR, files=src_files, dest_dir_in_cmp="src")
    # Shared headers (register map) from sw/common
    common_dir = os.path.join(ROOT_DIR, "sw", "common")
    common = [os.path.basename(p) for p in glob.glob(os.path.join(common_dir, "*.h"))]
    if common:
        app.import_files(from_loc=common_dir, files=common, dest_dir_in_cmp="src")
    # Optimization: Vitis defaults to -O0 (no optimization). The software CNN baseline in
    # Phase 7 must be compiled fairly, so every app is built with -O2 (override: EAI_OPT=-O3).
    opt = os.environ.get("EAI_OPT", "-O2")
    cfg = os.path.join(WORKSPACE, APP_NAME, "src", "UserConfig.cmake")
    with open(cfg) as f:
        txt = f.read()
    new_txt = re.sub(r"set\(USER_COMPILE_OPTIMIZATION_LEVEL [^)]*\)",
                     f"set(USER_COMPILE_OPTIMIZATION_LEVEL {opt})", txt)
    if new_txt == txt and opt != "-O0":
        sys.exit("ERROR: could not set the optimization level in " + cfg)
    with open(cfg, "w") as f:
        f.write(new_txt)
    print(f"INFO: compiler optimization level {opt}")
    app.build()

    # 4. Copy the ELF to build/sw/
    elfs = glob.glob(os.path.join(WORKSPACE, APP_NAME, "build", "*.elf"))
    if not elfs:
        sys.exit("ERROR: no ELF produced")
    os.makedirs(OUT_SW, exist_ok=True)
    shutil.copy(elfs[0], os.path.join(OUT_SW, APP_NAME + ".elf"))
    print(f"INFO: ===== SW BUILD DONE: build/sw/{APP_NAME}.elf")
finally:
    # Always stop the Vitis server, even after an error; otherwise it keeps the
    # workspace locked and the next run fails with WinError 32.
    vitis.dispose()
