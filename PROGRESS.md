# PROGRESS

## Current phase
Phase 0 â€” Setup (in progress)

## Environment (checked 2026-10-07)
- Board: **Digilent Zybo Z7-10** (XC7Z010-1CLG400C), confirmed by user
- OS: Windows 11 Home (10.0.26200)
- Vivado 2025.1 and Vitis 2025.1 at `C:\Xilinx\2025.1`
- Python 3.13.15 (NumPy, Pillow installed; PyTorch, matplotlib, pyserial NOT yet installed)
- Git 2.55.0 (user: Alvin Hadar, hadaralvin@gmail.com)
- GitHub CLI 2.102.0 installed with winget, logged in as `alvinhdr`
- Simulators: Verilator / Icarus / cocotb not installed

## Decisions made
- Simulator: **Vivado xsim** with SystemVerilog testbenches (already installed; Verilator + cocotb are hard on Windows).
- Repo is **private** until Phase 8, then public.
- Repo root = this folder. GitHub repo name: `fpga-edge-ai-video`.
- Python packages are installed only when needed (PyTorch in Phase 3).

## What works
- Repo folder structure and .gitignore created.

## In progress
- GitHub login and first push.
- `docs/LEARNING.md` created.

## Open problems
- Vitis 2025.1: old `xsct` command not found at the expected path. Check in Phase 1 (Vitis 2025.1 uses the new unified IDE; CLAUDE.md says Digilent supports Classic mode only for 2024.1+ releases).

## Next step
Finish Phase 0: `gh auth login`, create private repo, push, tag `phase-0-done`. Then wait for the user to say OK before Phase 1.

