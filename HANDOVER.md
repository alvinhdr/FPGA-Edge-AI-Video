# HANDOVER — Real-Time Edge AI Video Processor on FPGA

Written 2026-10-07 as a backup before a possible Claude account change. Work may continue in the old
account after this; **always check `PROGRESS.md` and `git log` for anything newer than this file.**

---

## 1. Project summary
- Solo CV/portfolio project: live 1280x720@60 HDMI video goes through a Digilent **Zybo Z7-10**.
- A small int8 CNN (hand-written SystemVerilog, no HLS) will recognize a handwritten digit (0-9) inside a 224x224 box in the middle of the screen.
- The result (digit, confidence bar, 28x28 "AI view") is drawn on the live video with no frame buffer (a few clocks of latency).
- The Python integer golden model is the spec (`docs/QUANTIZATION.md`); the hardware must match it bit-exactly.
- Goal: real measured numbers (accuracy on board, latency, speedup vs ARM, resources) + demo video + CV bullets. Full spec: `CLAUDE.md`.

## 2. User profile
- Beginner FPGA student (earlier: ultrasonic sensor + PuTTY; team project at KCCI). Intermediate English: **talk in simple, short English**, explain jargon once.
- Must be able to explain everything in an interview: **teach** after each module, update `docs/LEARNING.md`.
- Physical steps (cables, board, TV, looking at the screen) are done by the user: give short numbered steps and wait.
- Likes progress over side-tests; asked to be told explicitly when to switch model/effort (CLAUDE.md section 5).
- Hardware: **Zybo Z7-10** (XC7Z010-1CLG400C; JTAG confirms `xc7z010`), laptop = build PC (Windows 11, MSI with RTX 2050, i5-12450H, 16 GB), TV Sharp AQUOS as monitor, 2 HDMI cables (user sometimes has only 1 with them).
- Tools: **Vivado 2025.1 + Vitis 2025.1 (Vitis Unified Software Platform edition, upgraded on 2026-10-07)**, at `C:\Xilinx\2025.1`. Python 3.13 + repo venv `.venv`. Git 2.55, GitHub CLI logged in as `alvinhdr`.
- Git identity: Alvin Hadar <hadaralvin@gmail.com>.

## 3. Current status
| Phase | Status | Evidence |
|---|---|---|
| 0 Setup | DONE (tag `phase-0-done`) | repo + env recorded in PROGRESS.md |
| 1 HDMI pass-through | DONE (tag `phase-1-done`) | user saw laptop picture on TV through FPGA; LEDs; UART "hello"/"alive N" in PuTTY |
| 2 Pixel pipeline overlay | DONE (tag `phase-2-done`) | sim 3 tests bit-exact; board: green box + green "7", SW0 gray, SW1 hide; photo `docs/images/phase2_board_first_light_1080p.jpg` |
| 3 ML golden model | DONE (tag `phase-3-done`) | float 98.24 %, int8 golden 98.25 % on MNIST test; independent PyTorch cross-check bit-exact (2,000 images) |
| 4 ROI capture + CDC | DONE (tag `phase-4-done`) | sims pass; board (SD boot): AI view live, captures saved, first real capture 7 predicted correctly |
| 5 CNN accelerator RTL | not started | |
| 6 Integration | not started | |
| 7 Benchmarks | not started | |
| 8 Polish | not started | |

## 4. What works right now (on the board)
With the **Phase 2-era bitstream** (last board-tested): laptop HDMI → board HDMI RX → FPGA → HDMI TX → TV shows the laptop picture with a green 224x224 box (centered when the laptop sends 1280x720) and a big green "7"; SW0 up = grayscale, SW1 up = overlay hidden. LEDs: LD0 blink (board clock), LD1 on (200 MHz PLL), LD2 on (HDMI input locked), LD3 blink (pixel clock). ARM UART prints over COM16/COM17 at 115200.
The **current Phase 4 bitstream** (in `build/`, not committed) has not been tested on the board yet.

**Important:** the laptop must send **1280x720 @ 60 Hz** (Windows: Extend mode or Duplicate with 1280x720). Digilent's EDID also offers 1080p and Windows picks it in Duplicate mode; 1080p runs the input MMCM out of spec (works by luck only).

## 5. Work in progress (Phase 4)
Done (commit `cda5fc1`, `0d66d1c`):
- `rtl/roi_capture.sv` (224x224 ROI → gray → invert → 8x8 average → threshold → 28x28, 2-bank buffer, freeze, frame toggle), `rtl/ai_view_overlay.sv` (28x28 shown 8x at x=256..479, y=248..471), `rtl/ram_tdp.sv` (dual-clock BRAM), `rtl/cdc_pulse_sync.sv`, `rtl/cdc_bus_sync.sv` (req/ack handshake), `rtl/axil_regs.sv`; `rtl/pixel_pipeline.sv` latency now 6; `rtl/top.sv` integrates all.
- `scripts/build_hw.tcl`: block design PS M_AXI_GP0 → SmartConnect → external `M_AXI_LITE` (base **0x43C00000**, 64 KB), `clk_acc` = FCLK_CLK0 100 MHz, `rst_acc_n` from proc_sys_reset.
- Sims: `scripts/sim_pixel_pipeline.py` (3 tests ALL PASS, includes ROI data bit-exact vs QUANTIZATION.md §8), `scripts/sim_unit.py` (tb_cdc PASS, tb_axil_regs PASS). Mutation test: naive per-bit bus sync fails tb_cdc with 127 torn values.
- Build: timing met **WNS +1.226 ns**, 1588 LUT (9 %), 1871 FF, 1 BRAM tile.
- Written, NOT yet built/tested: `sw/roi_capture/main.c` (UART commands c/i/t/+/-/s/h), `sw/common/edge_ai_regs.h`, `scripts/capture_roi.py`.

Unfinished: see section 6 and 11.

## 6. Open problems and bugs
1. **(SOLVED after this file was first written: synthesis-only warning; see TIMING.md #3, clock groups now in zybo_z7_10_impl.xdc, 0 critical warnings.)** Old text: XDC clock group for clk_acc not applied. `constraints/zybo_z7_10.xdc` line ~75: `-group [get_clocks -include_generated_clocks clk_fpga_0]` gives CRITICAL WARNING "No valid object(s) found". So paths between clk_acc and clk_pix are not declared async (timing still met, but must be fixed). Fix idea: open the project and run `report_clocks` to get the real name, or use
   `get_clocks -of_objects [get_pins -hier -filter {NAME =~ *processing_system7_0/FCLK_CLK0}]`.
2. After that, review `build/reports/cdc.rpt`: CDC-7 Critical (3, async reset unknown circuitry) and CDC-11 Critical (2, fan-out from launch flop). CDC-15 warnings on `u_cfg_sync/hold_q -> data_q` are the expected handshake structure.
3. Known harmless warnings: project-stage CRITICAL WARNINGs from Digilent's packaged ILA (IP_Flow 19-4965) and board preset DDR DQS (PSU-1..4). Synthesis/implementation logs had 0 critical warnings in Phase 2 (before problem 1).
4. Synthetic augmented-MNIST stress test is only ~91 % (domain gap). Plan: real ROI captures in Phase 4 + fine-tune.

## 7. Decisions made (beyond / differing from CLAUDE.md)
- Simulator: **Vivado xsim** (Verilator/cocotb not used on Windows). Testbenches in SV; image tests driven by Python.
- Digilent `vivado-library` as git submodule `third_party/vivado-library`, pinned to commit `f4613ff` (same as Digilent's 10/HDMI/2025.1-1 demo).
- Top level hand-written SV (`rtl/top.sv`); Digilent IPs via `create_ip`; PS in small block design `ps_bd`.
- 200 MHz ref clock from the 125 MHz board clock (clk_wiz PLL), not from the PS → video works without ARM software. `sysclk` drives only the PLL; our logic uses `clk_sys` (TIMING.md #1). No own `create_clock` on sysclk; clock group refers to the IP's clock by pin (TIMING.md #2).
- dvi2rgb kClkRange=2, EDID `dgl_720p_cea.data`, kAddBUFG=true; rgb2dvi internal MMCM, kClkRange=2. HPD = PLL locked.
- Pixel bus order is Digilent **R-B-G** (`[23:16]=R, [15:8]=B, [7:0]=G`), confirmed on board; defined only in `rtl/video_pkg.sv`.
- Position from DE only (polarity-independent); new frame = long DE-low gap.
- ROI frame drawn OUTSIDE the ROI (AI input never contains the green box). Digit 8x8 font x16 = 128x128 at (784,248). AI view at (256,248) 224x224.
- Quantization: int8 symmetric weights, uint8 activations, **zero point 0 everywhere**, requant `(acc*M + 2^(S-1)) >> S` with M in [16384,32767], S in 15..40; ReLU = clamp; no requant on FC; confidence = top1-top2 margin scaled so margin 8.0 → 255.
- PyTorch **CPU** build (tiny CNN). Training: 12 epochs, augmentation prob 0.7, seed 0.
- ROI buffer double-banked + freeze bit; settings latched at start of frame.
- Vitis workspace outside repo (`~/fpga_ws/fpga-edge-ai-video`) because the repo path has spaces.
- Run Vivado/Vitis/xsdb tools from **PowerShell** (Git Bash sometimes gives "Access is denied" for `.bat`).
- Plusargs without "=" (`+gray1`), because Windows `.bat` splits at "=".

## 8. File map
- `CLAUDE.md` spec/rules. `PROGRESS.md` running log. `HANDOVER.md` this file.
- `rtl/`: `top.sv` (top level), `video_pkg.sv` (types, colors, R-B-G), `pixel_pipeline.sv` (6-stage chain), `pix_pos_counter.sv`, `rgb2gray.sv`, `roi_overlay.sv`, `digit_overlay.sv`, `font_rom.sv` + `font_digits_8x8.mem`, `ai_view_overlay.sv`, `roi_capture.sv`, `ram_tdp.sv`, `cdc_sync_2ff.sv`, `cdc_pulse_sync.sv`, `cdc_bus_sync.sv`, `axil_regs.sv`.
- `tb/`: `tb_pixel_pipeline.sv` (stream in/out, ROI write log), `tb_cdc.sv`, `tb_axil_regs.sv`.
- `constraints/zybo_z7_10.xdc`: pins (from Digilent master XDC) + clocks + async groups + false paths.
- `scripts/`: `build_hw.tcl` (whole Vivado project, `-tclargs project|all`), `build_sw.py` (Vitis Python API; builds `sw/<app>`), `program.tcl` (xsdb: `bit` or `all <app>`), `video_stream.py` (720p stream + Python reference model), `sim_pixel_pipeline.py`, `sim_unit.py`, `capture_roi.py`.
- `sw/`: `hello/main.c` (Phase 1 UART test), `roi_capture/main.c` (Phase 4), `common/edge_ai_regs.h` (register map).
- `ml/`: `model.py`, `data_utils.py`, `train.py`, `quantize.py`, `golden_int.py` (integer golden model), `check_golden.py`, `evaluate.py`, `export.py`, `download_mnist.py`, `requirements.txt`, `model_float.npz`, `quant_params.npz`, `export/` (weights `.mem`, `quant_params.svh`, 20-image full vectors; 1000-image vectors git-ignored), `reports/accuracy.md`, `data/` (MNIST, git-ignored), `captures/` (Phase 4 real ROI PNGs, to be created).
- `docs/`: `LEARNING.md`, `QUANTIZATION.md`, `CDC.md`, `TIMING.md`, `images/`.
- `third_party/vivado-library` (submodule). `build/` (git-ignored outputs: bitstream, xsa, reports, sims).

## 9. How to build and test (repo root `C:\Users\User\Documents\FPGA\Project\FPGA Edge AI Video`, PowerShell)
```
git submodule update --init                                      # after a fresh clone
python -m venv .venv; .\.venv\Scripts\python.exe -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
.\.venv\Scripts\python.exe -m pip install -r ml/requirements.txt; .\.venv\Scripts\python.exe ml/download_mnist.py
.\.venv\Scripts\python.exe scripts/sim_pixel_pipeline.py          # image sims (3 tests)
.\.venv\Scripts\python.exe scripts/sim_unit.py                    # tb_cdc, tb_axil_regs
& "C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -nojournal -log build/vivado_build.log -source scripts/build_hw.tcl -tclargs all   # ~10 min
& "C:\Xilinx\2025.1\Vitis\bin\vitis.bat" -s scripts/build_sw.py roi_capture     # or hello
& "C:\Xilinx\2025.1\Vivado\bin\xsdb.bat" scripts/program.tcl bit                 # FPGA only
& "C:\Xilinx\2025.1\Vivado\bin\xsdb.bat" scripts/program.tcl all roi_capture     # FPGA + ARM app
.\.venv\Scripts\python.exe ml/train.py; ml/quantize.py; ml/check_golden.py; ml/evaluate.py; ml/export.py
```
Board: power jumper USB, boot jumper JTAG, micro-USB in PROG/UART. UART: **115200 baud, 8N1, no flow control**, COM16 or COM17 (depends on USB port). PuTTY saved session `zybo`. Laptop display must be 1280x720@60.

## 10. Measured results so far
- Build (Phase 4): WNS +1.226 ns, WHS +0.033 ns; 1588 LUT (9.0 %), 1871 FF (5.3 %), 1 BRAM tile, 0 DSP.
- Build (Phase 2): WNS +0.870 ns, 732 LUT, 870 FF, 0 critical warnings. Pixel pipeline latency 4 clocks (Phase 2) / 6 clocks (Phase 4).
- ML: float 98.24 %, **int8 golden 98.25 %** (MNIST test 10,000), float/int agreement 99.90 %; augmented stress test float 90.88 % / int 90.76 %. Requant M1=20725 S1=23, M2=20000 S2=23, Mc=26807 Sc=21.
- Model: 5,224 int8 weights, 34 biases, 192,064 MACs/image.
- No on-board CNN numbers yet.

## 11. Next steps
(UPDATE: steps 1-4 below are DONE except collecting more captures. Next = collect ~10 captures per digit with `scripts/capture_roi.py --port COM17`, then Phase 5. SD card: `scripts/make_boot.py --copy-to G:\`, boot jumper on SD.)
1. DONE: XDC fix, clean rebuild, CDC review. 2. DONE: `build/sw/roi_capture.elf` built (rebuild with `vitis.bat -s scripts/build_sw.py roi_capture` if `build/` is missing).
3. Board test (user, 2 HDMI cables, laptop at 1280x720): `xsdb.bat scripts/program.tcl all roi_capture`; check TV shows AI view (white digit on black, left of box) when drawing dark on white in the box; PuTTY `s` status shows frames counting.
4. Close PuTTY, run `.venv\Scripts\python.exe scripts/capture_roi.py --port COM17`, capture ~10 images per digit into `ml/captures/`; note golden-model predictions. Update PROGRESS/LEARNING, tag `phase-4-done`.
5. Phase 5: plan CNN accelerator RTL (MAC array, conv/pool/FC engines, requant, controller) with self-checking TBs against `ml/export/vec_full_*`.

## 12. Recommended model/effort for the next task
- Step 1 (constraint/CDC report review): `/model opus`, `/effort high`.
- Steps 2-4 (scripts, board test): `/model sonnet`, `/effort medium`.
- Phase 5 planning: `/model opus`, `/effort high`; Phase 5 RTL writing: `/model opus`, `/effort medium`.

## 13. Git state
- Repo: https://github.com/alvinhdr/fpga-edge-ai-video (private), branch `main`.
- Last commit before this file: `0d66d1c` "PROGRESS: Phase 4 status and open XDC issue". This file is committed right after it.
- Tags: `phase-0-done`, `phase-1-done`, `phase-2-done`, `phase-3-done`.
- Everything pushed (`main...origin/main` clean). Submodule `third_party/vivado-library` @ `f4613ff`.
