# PROGRESS

## Current phase
Phase 1 - HDMI pass-through: **IN PROGRESS** (hardware built, waiting for board test; ARM software build blocked).

## Environment (checked 2026-10-07)
- Board: **Digilent Zybo Z7-10** (XC7Z010-1CLG400C), confirmed by user
- OS: Windows 11 Home (10.0.26200)
- Vivado 2025.1 and Vitis 2025.1 (unified IDE only, no `xsct`) at `C:\Xilinx\2025.1`
- `xsdb`, `sdtgen`, `hw_server`, `bootgen` are in `C:\Xilinx\2025.1\Vivado\bin`
- Python 3.13.15. Project venv `.venv` (git-ignored) with torch 2.14.1+cpu, torchvision 0.29.1+cpu,
  numpy 2.5.2, matplotlib 3.11.2, pyserial 3.5, tqdm, pillow. See `ml/requirements.txt`.
  CPU build on purpose: the CNN is tiny; laptop has i5-12450H, 16 GB RAM (GPU RTX 2050 4 GB not used).
- MNIST downloaded to `ml/data/MNIST/raw` (git-ignored) with `ml/download_mnist.py`.
- Vitis edition upgraded to **Vitis Unified Software Platform** + Zynq-7000 (ARM toolchain present).
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

## Board tests (user-confirmed)
- 2026-10-07, bitstream only (`xsdb.bat scripts/program.tcl bit`), JTAG shows target `xc7z010` (Z7-10 confirmed).
  - LD0 blinking, LD1 on -> board clock + 200 MHz PLL OK.
  - Laptop HDMI out -> board HDMI RX: Windows shows a second display named **"DGL 720P CEA"** (our EDID) -> HPD + DDC/EDID OK.
  - LD2 on (dvi2rgb pLocked), LD3 blinking (pixel clock running) -> HDMI input locks to the laptop video.
  - **Not yet tested:** HDMI TX -> monitor (user had only one HDMI cable). Test next session.
- Board USB: FTDI "USB Serial Converter A/B", UART = **COM16** on this PC (the laptop and the build PC are the same computer).

## In progress
- Output half of the pass-through (needs a second HDMI cable).

## Open problems
1. **SOLVED (2026-10-07):** the installed edition was "Vivado ML Standard" (Vivado only, partial Vitis).
   User upgraded with `C:\Xilinx\.xinstall\2025.1\xsetup.exe` to **Vitis Unified Software Platform** +
   SoCs/Zynq-7000 (8 GB download). Now `gnu\aarch32` exists and `vitis.bat -s scripts/build_sw.py hello`
   builds `build/sw/hello.elf` (and an FSBL). Run Vitis/xsdb from PowerShell, not Git Bash.
   History:
   **ROOT CAUSE FOUND (2026-10-07 12:40): the ARM toolchain is not installed.**
   `C:\Xilinx\2025.1\gnu` has only `microblaze` and `riscv`; no `arm-none-eabi-gcc.exe` anywhere in
   `C:\Xilinx\2025.1`. Also `vitis.bat` adds `Vivado\bin` (lopper, sdtgen, xsdb) to PATH only for the old
   install layout, so `scripts/build_sw.py` now adds it itself -> Vitis now prints "SDT generated successfully".
   Domain/BSP creation then fails: pyesw `create_bsp.py` (run by hand) says
   "CMAKE_C_COMPILER arm-none-eabi-gcc ... was not found". Vitis only says "Application error processing RPC".
   **Fix needed (user):** add the Zynq-7000 / ARM Cortex-A9 embedded toolchain with the AMD installer
   ("Add Design Tools or Devices 2025.1"), then re-run `vitis.bat -s scripts/build_sw.py hello` (from PowerShell).
   Earlier history of this problem:
   **Vitis 2025.1 cannot create the platform from our XSA.**
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
1. With two HDMI cables: laptop -> HDMI RX, HDMI TX -> monitor. Run from PowerShell (Git Bash gives
   "Access is denied"): `& "C:\Xilinx\2025.1\Vivado\bin\xsdb.bat" scripts/program.tcl bit`, check the monitor.
2. Fix problem 1 (Vitis platform), then `vitis.bat -s scripts/build_sw.py hello` and
   `xsdb.bat scripts/program.tcl all hello`, check PuTTY (115200 baud).
