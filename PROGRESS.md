# PROGRESS

## Current phase
Phases 0-4 **DONE** (tags phase-0..4-done). **Phase 5 STARTED** (CNN accelerator RTL; plan approved 2026-10-07:
P-wide MAC array (parameter), pooling fused into conv, wide weight ROM `ml/export/wrom_p{P}.mem`).

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
- 2026-10-07, `xsdb.bat scripts/program.tcl all hello`: ARM runs `sw/hello`; UART output read by Claude
  with pyserial ("alive 7..10") and confirmed by the user in PuTTY ("alive 72..74"). **UART hello: DONE.**
- Board USB: FTDI "USB Serial Converter A/B". UART COM port number depends on the laptop USB port
  (COM16 on one port, **COM17** on another). PuTTY session `zybo`: serial, 115200, 8N1, no flow control.

## Phase 2 (started 2026-10-07, before the Phase 1 TX test; agreed with the user because only the
## board test with 2 HDMI cables is missing for Phase 1)
- RTL: `video_pkg.sv` (R-B-G order, `video_t`, named colors), `pix_pos_counter.sv` (DE-based x/y, frame
  detect by long DE-low gap), `rgb2gray.sv` ((77R+150G+29B)>>8), `font_rom.sv` + `font_digits_8x8.mem`,
  `roi_overlay.sv` (3-px green frame OUTSIDE the 224x224 ROI), `digit_overlay.sv` (8x8 font x16 = 128x128),
  `pixel_pipeline.sv` (4 stages, latency 4 clocks). `top.sv`: sw0 = gray view, sw1 = hide overlay, digit fixed 7.
- Verification: `scripts/sim_pixel_pipeline.py` (xsim, run from PowerShell with `.venv`):
  3 tests x 2 full 720p frames, bit-exact vs Python reference + sync timing check: **ALL PASS**.
  Negative check done (wrong digit / ROI off by 1 px are detected). Images in `docs/images/phase2_sim_*.png`.
- Build: timing met **WNS +0.870 ns, WHS +0.059 ns**, 732 LUT (4.2%), 870 FF (2.5%), **0 critical warnings**.
- **Board test pending** (needs 2 HDMI cables): expect laptop screen + green box + green "7"; sw0 gray; sw1 hides.

## Phase 3 - ML golden model (2026-10-07)
- Spec: `docs/QUANTIZATION.md`. Code in `ml/`: `model.py`, `data_utils.py` (augmentation), `train.py`,
  `quantize.py`, `golden_int.py` (integer-only), `check_golden.py`, `evaluate.py`, `export.py`.
- Trained 12 epochs (seed 0, about 3.5 min on CPU): float 98.24 % on clean MNIST test (10,000 images).
- Quantized: **integer golden model 98.25 %** (same prediction as float on 99.90 % of images).
  Requant constants M1=20725/S1=23, M2=20000/S2=23, Mc=26807/Sc=21. No activation saturates; accumulators < 2^24.
- `ml/check_golden.py`: independent PyTorch integer implementation vs golden model: **bit-exact on all layers, 2,000 images**.
- Augmented-test stress row: float 90.88 % / int 90.76 % (synthetic, NOT real camera data). Real ROI captures come in Phase 4.
- Export in `ml/export/`: weights `.mem`, `quant_params.svh`, full layer vectors for 20 images (committed),
  1000-image vectors (git-ignored, run `ml/export.py` to regenerate). Report: `ml/reports/accuracy.md`.
- Reproduce: `.venv\Scripts\python.exe ml/train.py; ml/quantize.py; ml/check_golden.py; ml/evaluate.py; ml/export.py`.

## Board test Phase 1 + 2 (user-confirmed 2026-10-07, TV Sharp AQUOS, laptop HDMI out)
- Laptop picture appears on the TV through the FPGA (pass-through) -> **Phase 1 DONE**.
- Green ROI box + green "7" drawn on live video; colors correct (R-B-G order confirmed).
  SW0 up -> gray picture; SW1 up -> box and digit hidden -> **Phase 2 DONE**. Photo: `docs/images/phase2_board_first_light_1080p.jpg`.
- First "TV black" problem was a loose HDMI cable (not a design bug).
- **Found:** Windows picked **1920x1080** (Digilent's `dgl_720p_cea.data` EDID also offers 1080p). The photo was taken at
  1080p (box left of center). At 1080p the pixel clock is 148.5 MHz: outside our timing constraint and above the
  dvi2rgb MMCM VCO range (1485 > 1200 MHz) -> worked by luck. With Windows set to **1280x720** (Extend mode, or
  Duplicate with 1280x720) the box is centered. **Demo must use 1280x720.** TODO later: own EDID with only 720p.

## In progress
- **Phase 4 (ROI capture + CDC), 2026-10-07, commit cda5fc1:**
  - RTL done: roi_capture, ai_view_overlay, ram_tdp, cdc_pulse_sync, cdc_bus_sync, axil_regs (base 0x43C00000,
    map in sw/common/edge_ai_regs.h); top.sv + block design (PS M_AXI_GP0 -> SmartConnect -> M_AXI_LITE, clk_acc 100 MHz).
  - Sims ALL PASS: scripts/sim_pixel_pipeline.py (ROI data bit-exact vs QUANTIZATION.md s8, banks, AI view);
    scripts/sim_unit.py (tb_cdc, tb_axil_regs). Mutation test: naive per-bit bus sync fails tb_cdc (127 torn values).
  - Build: timing met WNS +1.226 ns, 1588 LUT (9%), 1871 FF, 1 BRAM.
  - XDC issue SOLVED: the clk_fpga_0 warning came only from synthesis (block design is out-of-context);
    implementation applied the group all along. Clock groups moved to `constraints/zybo_z7_10_impl.xdc`
    (USED_IN_SYNTHESIS false). Rebuild: **0 critical warnings**, WNS +1.226 ns. CDC report reviewed (docs/CDC.md):
    the 5 criticals are inside Digilent dvi2rgb. TIMING.md #3 written (incl. my first wrong guess).
  - `sw/roi_capture` built: `build/sw/roi_capture.elf` (main.c 0 warnings).
  - **Board test PASSED (2026-10-07, booted from microSD, BOOT.bin via scripts/make_boot.py):** AI view shows the
    drawn digit white-on-black; UART status frames counting (~60/s); `c` capture works; `scripts/capture_roi.py --once`
    saves PNGs. ROI moved live via xsdb register write (`mwr -force 0x43C0000C`, needs `memmap -addr 0x43C00000 -size 0x10000`).
    With Paint not full-screen, ROI y0=296 keeps the Paint toolbar out of the box (hardware default stays 248).
    First real capture classified correctly: a drawn 7 -> golden model 7 (`ml/captures/7_20261007_193029.png`).
    Earlier bad captures (toolbar in ROI, digit touching edges -> predicted 2) were deleted.
    Photo: docs/images/phase4_board_ai_view.jpg. **Phase 4 DONE.**
  - Old note: board test `xsdb.bat scripts/program.tcl all roi_capture`,
    `scripts/capture_roi.py --port COM17`, LEARNING.md update, tag phase-4-done.

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
1. With two HDMI cables: laptop -> HDMI RX, HDMI TX -> monitor (Phase 2 bitstream already built). Run from PowerShell (Git Bash gives
   "Access is denied"): `& "C:\Xilinx\2025.1\Vivado\bin\xsdb.bat" scripts/program.tcl bit`, check the monitor.
2. Fix problem 1 (Vitis platform), then `vitis.bat -s scripts/build_sw.py hello` and
   `xsdb.bat scripts/program.tcl all hello`, check PuTTY (115200 baud).
