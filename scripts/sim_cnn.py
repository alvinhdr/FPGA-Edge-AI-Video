# =============================================================================
# File   : sim_cnn.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Run tb/tb_cnn.sv (CNN accelerator vs golden model vectors) in xsim.
#
# Usage (repo root, PowerShell):
#   .venv\Scripts\python.exe scripts/sim_cnn.py                  # P=8: 20 images all layers + 1000 images
#   .venv\Scripts\python.exe scripts/sim_cnn.py --p 1 2 4 8 16 --n 100
# Needs ml/export/ (run ml/export.py first; the 1000-image vectors are git-ignored).
# =============================================================================
import argparse
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
EXPORT = os.path.join(ROOT, "ml", "export")
VIVADO_BIN = os.environ.get("VIVADO_BIN", r"C:\Xilinx\2025.1\Vivado\bin")
SOURCES = ["ml/export/cnn_params_pkg.sv", "rtl/cnn_pkg.sv", "rtl/ram_tdp.sv", "rtl/cnn_mac_array.sv",
           "rtl/cnn_requant.sv", "rtl/cnn_argmax.sv", "rtl/cnn_controller.sv", "rtl/cnn_top.sv",
           "tb/tb_cnn.sv"]


def run(cmd, cwd, log):
    with open(log, "w") as f:
        r = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
    return r.returncode


def build(p):
    sim = os.path.join(ROOT, "build", "sim", f"cnn_p{p}")
    os.makedirs(sim, exist_ok=True)
    with open(os.path.join(sim, "tb_cnn_cfg.svh"), "w") as f:
        f.write(f"localparam int TB_P = {p};\n")
    for name in os.listdir(EXPORT):
        if name.endswith(".mem"):
            shutil.copy(os.path.join(EXPORT, name), sim)
    with open(os.path.join(sim, "sim.prj"), "w") as f:
        for s in SOURCES:
            rel = os.path.relpath(os.path.join(ROOT, s), sim).replace("\\", "/")
            f.write(f'sv xil_defaultlib "{rel}"\n')
    for cmd, log in (([os.path.join(VIVADO_BIN, "xvlog.bat"), "-i", ".", "-prj", "sim.prj"], "xvlog.log"),
                     ([os.path.join(VIVADO_BIN, "xelab.bat"), "-timescale", "1ns/1ps", "-s", "snap",
                       "xil_defaultlib.tb_cnn"], "xelab.log")):
        if run(cmd, sim, os.path.join(sim, log)) != 0:
            print(open(os.path.join(sim, log)).read()[-3000:])
            sys.exit(f"compile failed for P={p} ({log})")
    return sim


def sim_run(sim, full, n):
    log = os.path.join(sim, f"xsim_full{full}.log")
    t0 = time.time()
    run([os.path.join(VIVADO_BIN, "xsim.bat"), "snap", "-runall",
         "-testplusarg", f"full{full}", "-testplusarg", f"n{n}"], sim, log)
    out = open(log).read()
    ok = "TEST PASSED" in out and "TEST FAILED" not in out
    for line in out.splitlines():
        if re.match(r"\s*(img |P=|CYCLES|ACCURACY|\.\.\.)", line):
            print("    " + line.strip())
    return ok, time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--p", type=int, nargs="+", default=[8])
    ap.add_argument("--n", type=int, default=1000, help="images for the fc+result test")
    args = ap.parse_args()
    all_ok = True
    for p in args.p:
        sim = build(p)
        ok1, t1 = sim_run(sim, 1, 20)
        print(f"[{'PASS' if ok1 else 'FAIL'}] P={p} all layers, 20 images ({t1:.0f} s)")
        ok2 = True
        if ok1 and args.n > 0:
            ok2, t2 = sim_run(sim, 0, args.n)
            print(f"[{'PASS' if ok2 else 'FAIL'}] P={p} FC+digit+conf, {args.n} images ({t2:.0f} s)")
        all_ok &= ok1 and ok2
    print("ALL CNN TESTS PASSED" if all_ok else "SOME CNN TESTS FAILED")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
