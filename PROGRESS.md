# PROGRESS

## Current phase
Phase 0 - Setup: **DONE** (tag `phase-0-done`). Waiting for the user's OK to start Phase 1.

## Environment (checked 2026-10-07)
- Board: **Digilent Zybo Z7-10** (XC7Z010-1CLG400C), confirmed by user
- OS: Windows 11 Home (10.0.26200)
- Vivado 2025.1 and Vitis 2025.1 at `C:\Xilinx\2025.1`
- Python 3.13.15 (NumPy, Pillow installed; PyTorch, matplotlib, pyserial NOT yet installed)
- Git 2.55.0 (user: Alvin Hadar, hadaralvin@gmail.com)
- GitHub CLI 2.102.0 (installed with winget), logged in as `alvinhdr`
- Simulators: Verilator / Icarus / cocotb not installed; Vivado xsim is available

## Decisions made
- Simulator: **Vivado xsim** with SystemVerilog testbenches (already installed; Verilator + cocotb are hard on Windows).
- Repo is **private** until Phase 8, then public.
- Repo root = this folder. GitHub repo: https://github.com/alvinhdr/fpga-edge-ai-video
- Python packages are installed only when needed (PyTorch in Phase 3).

## What works
- Repo folder structure, `.gitignore`, `README.md` (placeholder), `PROGRESS.md`, `docs/LEARNING.md`.
- Private GitHub repo created; `main` pushed; tag `phase-0-done` pushed.

## In progress
- Nothing.

## Open problems
- Vitis 2025.1: the old `xsct` command was not found at `C:\Xilinx\2025.1\Vitis\bin\xsct.bat`. Check in Phase 1 (CLAUDE.md says Digilent supports Vitis Classic mode only for 2024.1+ releases).
- Digilent `vivado-library` and board files must match Vivado 2025.1. Check whether a 2025.1-compatible release exists (latest known Digilent HDMI demo release is for 2024.1).

## Next step
Phase 1 (HDMI pass-through). Recommended: `/model opus` `/effort high` for planning, then `sonnet` `medium` for Tcl scripts. First action: get Digilent `vivado-library` and the Zybo Z7 master XDC, and check the Vitis 2025.1 flow.
