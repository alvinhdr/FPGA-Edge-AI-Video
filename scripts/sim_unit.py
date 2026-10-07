# =============================================================================
# File   : sim_unit.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Compile and run the self-checking unit testbenches in Vivado xsim.
#          Each testbench prints "TEST PASSED" or "TEST FAILED".
#
# Usage (repo root, PowerShell):
#   .venv\Scripts\python.exe scripts/sim_unit.py            (all tests)
#   .venv\Scripts\python.exe scripts/sim_unit.py tb_cdc     (one test)
# =============================================================================
import os
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
VIVADO_BIN = os.environ.get("VIVADO_BIN", r"C:\Xilinx\2025.1\Vivado\bin")

TESTS = {
    "tb_cdc":       ["rtl/cdc_bus_sync.sv", "rtl/cdc_pulse_sync.sv", "tb/tb_cdc.sv"],
    "tb_axil_regs": ["rtl/ram_tdp.sv", "rtl/axil_regs.sv", "tb/tb_axil_regs.sv"],
}


def run(cmd, cwd, log):
    with open(log, "w") as f:
        return subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT).returncode


def run_test(name, sources):
    sim_dir = os.path.join(ROOT, "build", "sim", name)
    os.makedirs(sim_dir, exist_ok=True)
    with open(os.path.join(sim_dir, "sim.prj"), "w") as f:
        for s in sources:
            rel = os.path.relpath(os.path.join(ROOT, s), sim_dir).replace("\\", "/")
            f.write(f'sv xil_defaultlib "{rel}"\n')
    t0 = time.time()
    steps = [([os.path.join(VIVADO_BIN, "xvlog.bat"), "-prj", "sim.prj"], "xvlog.log"),
             ([os.path.join(VIVADO_BIN, "xelab.bat"), "-timescale", "1ns/1ps", "-s", "snap",
               f"xil_defaultlib.{name}"], "xelab.log"),
             ([os.path.join(VIVADO_BIN, "xsim.bat"), "snap", "-runall"], "xsim.log")]
    for cmd, log in steps:
        if run(cmd, sim_dir, os.path.join(sim_dir, log)) != 0:
            print(open(os.path.join(sim_dir, log)).read()[-2500:])
            return False, f"{log} failed"
    out = open(os.path.join(sim_dir, "xsim.log")).read()
    for line in out.splitlines():
        if line.startswith(("ERROR", "bus ", "pulses ")):
            print("        " + line)
    ok = "TEST PASSED" in out and "TEST FAILED" not in out
    return ok, f"{time.time() - t0:.1f} s"


def main():
    names = sys.argv[1:] or list(TESTS)
    all_ok = True
    for n in names:
        ok, info = run_test(n, TESTS[n])
        all_ok &= ok
        print(f"[{'PASS' if ok else 'FAIL'}] {n}  ({info})")
    print("ALL UNIT TESTS PASSED" if all_ok else "SOME UNIT TESTS FAILED")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
