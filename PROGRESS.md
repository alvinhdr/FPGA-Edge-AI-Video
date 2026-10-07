# PROGRESS

## Current phase
Phase 1 - HDMI pass-through: **IN PROGRESS** (hardware built, waiting for board test; ARM software build blocked).

## Environment (checked 2026-10-07)
- Board: **Digilent Zybo Z7-10** (XC7Z010-1CLG400C), confirmed by user
- OS: Windows 11 Home (10.0.26200)
- Vivado 2025.1 and Vitis 2025.1 (unified IDE only, no `xsct`) at `C:\Xilinx\2025.1`
- `xsdb`, `sdtgen`, `hw_server`, `bootgen` are in `C:\Xilinx\2025.1\Vivado\bin`
- Python 3.13.15 (NumPy, Pillow installed; PyTorch, matplotlib, pyserial NOT yet installed)
- Git 2.55.0 (user: Alvin Hadar, hadaralvin@gmail.com); GitHub CLI 2.102.0, logged in as `alvinhdr`
- Simulator: Vivado xsim (Verilator / Icarus / cocotb not installed)
- Installed Zybo Z7-10 board file: version 1.1 (Digilent demo uses 1.2; script picks newest installed)

## Decisions made
- Simulator: **Vivado xsim** with SystemVerilog testbenches.
- Repo **private** until Phase 8. GitHub: https://github.com/alvinhdr/fpga-edge-ai-video
- Python packages installed only when needed.
- Digilent `vivado-library` is a git submodule at `third_party/vivado-library`, pinned to commit
  `f4613ff` (the same commit used by Digilent's `10/HDMI/2025.1-1` demo). New folder `third_party/`.
- Top level is hand-written SystemVerilog (`rtl/top.sv`); Digilent IPs created with `create_ip`;
  the Zynq PS is in a small block design `ps_bd` (PS only, no AXI yet).
- **200 MHz reference clock comes from the 125 MHz board clock** (clk_wiz PLL), not from the PS.
  Reason: the video path works as soon as the FPGA is programmed, without ARM software.
- `sysclk` drives only the PLL; our logic uses `clk_sys` (125 MHz PLL output). See docs/TIMING.md #1.
- dvi2rgb: kClkRange=2, EDID `dgl_720p_cea.data`, kAddBUFG=true, active-low reset = PLL locked.
  rgb2dvi: internal MMCM serial clock, kClkRange=2, reset = dvi2rgb pLocked. HPD = PLL locked.
- Vitis workspace lives outside the repo (`~/fpga_ws/fpga-edge-ai-video`) because the repo path has spaces.

## What works
- `scripts/build_hw.tcl` builds the full design in batch mode. **Timing met: WNS +1.071 ns, WHS +0.033 ns.**
  Utilization: 574 LUT (3.3%), 691 FF (2.0%), 0 BRAM, 0 DSP, 2/2 MMCM, 1/2 PLL. Power estimate 2.0 W.
- Outputs: `build/edge_ai_video.bit`, `build/edge_ai_video.xsa`, reports in `build/reports/`.
- `build/hw/ps7_init.tcl` extracted from the XSA.

## In progress
- Board test of the video pass-through (user's board was borrowed for a class; back ~2 h after 2026-10-07 10:15).

## Open problems
1. **Vitis 2025.1 cannot create the platform from our XSA.**
   Symptom: `create_platform_component` -> "Error in generating SDT for given XSA".
   Tried: (a) XSA copy in a path without spaces, (b) generate_dtb=False + no_boot_bsp=True,
   (c) running Vitis' own SDT script (`Vitis/vitis-server/scripts/platformutil.tcl`) with
   `Vivado/bin/sdtgen.bat` by hand -> **works**, produces system-top.dts, (d) passing that SDT folder as
   hw_design -> "Unsupported Target 'HW'", (e) Vivado/bin on PATH (vitis.bat already sets it) -> same error.
   Guess: the Vitis server starts sdtgen differently (environment/path) and the real error is hidden.
   Next ideas: get the Vitis server debug log; try the Vitis GUI once with the same XSA; try
   `vitis -w` / `vitis-run`; check AMD forums for "Error in generating SDT" on Windows 2025.1.
2. Known harmless warnings: dvi2rgb's unused ILA cores (CRITICAL WARNING Designutils 20-1280 / Vivado 12-4739),
   and Digilent board preset negative DQS-to-CLK delays (PSU-1..4).

## Next step
1. When the board is back: user connects cables (power jumper USB, boot jumper JTAG, PROG/UART micro-USB,
   laptop -> HDMI RX, HDMI TX -> monitor), then run
   `C:\Xilinx\2025.1\Vivado\bin\xsdb.bat scripts/program.tcl bit` and check LEDs + monitor.
2. Fix problem 1 (Vitis platform), then `vitis.bat -s scripts/build_sw.py hello` and
   `xsdb.bat scripts/program.tcl all hello`, check PuTTY (115200 baud).
