# HANDOVER — Real-Time Edge AI Video Processor on FPGA

Last full rewrite: 2026-10-08 (end of Phase 6). **Updated 2026-10-08 ~01:10: Phase 7 USB-only part done.** Work may continue after this;
**always check `PROGRESS.md` and `git log` for anything newer than this file.**

---

## 1. Project summary
- Solo CV/portfolio project: live 1280x720@60 HDMI video goes through a Digilent **Zybo Z7-10**.
- A small int8 CNN (hand-written SystemVerilog, no HLS) recognizes a handwritten digit (0-9) inside a 224x224 box in the middle of the screen, on every frame.
- The result (digit, confidence bar, 28x28 "AI view") is drawn on the live video with no frame buffer (7 pixel clocks of video latency; result of frame N shown on frame N+1).
- The Python integer golden model is the spec (`docs/QUANTIZATION.md`); the hardware matches it bit-exactly.
- Goal now: real measured numbers (Phase 7), then README/demo video/CV bullets (Phase 8). Full spec: `CLAUDE.md`.

## 2. User profile
- Beginner FPGA student (earlier: ultrasonic sensor + PuTTY; team project at KCCI). Intermediate English: **talk in simple, short English**, explain jargon once.
- Must be able to explain everything in an interview: **teach** after each module, update `docs/LEARNING.md`.
- Physical steps (cables, jumpers, SD card, TV, drawing) are done by the user: give short numbered steps and wait.
- Likes progress over side-tests. Wants the "Recommended setting" line (CLAUDE.md section 5) and the user switches model/effort when told.
- Account may run out (Pro plan): **refresh this file at every phase start/finish** and push.
- Hardware: **Zybo Z7-10** (XC7Z010-1CLG400C), laptop = build PC (Windows 11, i5-12450H, 16 GB), TV Sharp AQUOS as monitor, 2 HDMI cables.
- Tools: **Vivado 2025.1 + Vitis 2025.1 (Unified Software Platform, Zynq-7000 ARM toolchain)** at `C:\Xilinx\2025.1`. Python 3.13 + repo venv `.venv`. Git 2.55, GitHub CLI logged in as `alvinhdr`. Git identity: Alvin Hadar <hadaralvin@gmail.com>.

## 3. Current status
| Phase | Status | Evidence |
|---|---|---|
| 0 Setup | DONE (`phase-0-done`) | repo + env in PROGRESS.md |
| 1 HDMI pass-through | DONE (`phase-1-done`) | user saw laptop picture on TV through FPGA; UART hello |
| 2 Pixel pipeline overlay | DONE (`phase-2-done`) | sims bit-exact; board: green box + "7", SW0 gray, SW1 hide |
| 3 ML golden model | DONE (`phase-3-done`) | float 98.24 %, int8 golden 98.25 % (MNIST test); PyTorch cross-check bit-exact (2,000 img) |
| 4 ROI capture + CDC | DONE (`phase-4-done`) | sims pass; board: AI view live, ROI captures saved to PC |
| 5 CNN accelerator RTL | DONE (`phase-5-done`) | P=8: 1000/1000 bit-exact; 23,965 cycles = 240 us @100 MHz; all P=1..16 bit-exact |
| 6 Integration | DONE (`phase-6-done`, 2026-10-08) | full build WNS +0.302 ns; board (SD boot): `j` -> INJECT 20/20 bit-exact; drawn digits predicted live on TV with confidence bar (user-confirmed) |
| 7 Benchmarks | **IN PROGRESS** | on board: 10,000 MNIST images 98.25 %, 10,000/10,000 bit-exact; 9.3x vs ARM; P sweep done. Missing: FPS test + real drawings (need HDMI) |
| 8 Polish | not started | |

## 4. What works right now (on the board)
`build/BOOT.bin` (FSBL + bitstream + `edge_ai_demo`) on the microSD, boot jumper on SD. Laptop (1280x720, now forced by
our own EDID) -> HDMI RX -> FPGA -> HDMI TX -> TV: live video, green 224x224 box at the center, AI view (28x28 x8) left of it,
predicted digit (128x128 green) + confidence bar right of it, updated every frame. PuTTY (COM17 or COM16, 115200 8N1):
keys p s j c w/a/z/d x i t + - h (see `sw/edge_ai_demo/main.c` header). `j` = 20-image injection self-test.
LEDs: LD0 blink (board clock), LD1 (200 MHz PLL locked), LD2 (HDMI input locked), LD3 blink (pixel clock).

## 5. Work in progress
Phase 7. Decision: option A (fine-tune with real drawings only if their accuracy < ~90 %, then with separate
train/test capture sets). Details and all numbers: `PROGRESS.md` "Phase 7" and `docs/RESULTS.md`.
- DONE: ARM C model (`sw/common/cnn_ref.h`, weights `sw/common/cnn_weights.h` from `ml/export.py`), `sw/benchmark` +
  `scripts/bench_mnist.py` (10,000 images run on the board), P sweep OOC + full builds P=1/8/16 (`build_hw.tcl all <P>`,
  `rtl/top.sv` parameter `CNN_P`), RESULTS.md sections 1, 2, 3, 6, LEARNING Phase 7.
- READY, NOT RUN: `sw/edge_ai_demo` (built, -O2) has `f` (60 s FPS / skipped-frame test) and `c` returns the hardware
  result for the captured image; `scripts/capture_roi.py` logs to `ml/captures/captures.csv`. Needs HDMI connected.
- Board right now: boot jumper on **JTAG**, running `sw/benchmark` (loaded with `program.tcl all benchmark`).
  The SD card still has the OLD Phase 6 BOOT.bin (works, but without `f`). Rebuild with `make_boot.py --app edge_ai_demo`.

## 6. Open problems and bugs
- **Vitis 2025.1 platform.build() fails every time** ("Application error processing RPC"): the BSP misses its final
  CMake configure, so driver headers (xscugic.h) are not copied. `scripts/build_sw.py` now catches it, runs `cmake .` +
  `ninja` in each `gen_bsp` folder, and builds again: works. If a Vitis build locks the workspace (WinError 32),
  kill leftover java/python/vitis_c++ processes whose command line contains `fpga_ws` or `vitis`.
- xsdb `program.tcl all` failed once in `ps7_init` (mask_delay) right after power-on; running it again worked.
- Nothing else blocking. Known harmless warnings: Digilent dvi2rgb unused ILA XDCs (disabled in build_hw.tcl), board preset DQS delays (PSU-1..4). CDC report criticals are inside Digilent dvi2rgb (docs/CDC.md).
- Real-drawing accuracy not measured yet (synthetic augmented MNIST only 90.8 %; domain gap). First real captures predicted correctly.

## 7. Decisions made (beyond / differing from CLAUDE.md)
- Simulator: **Vivado xsim** (SV testbenches; image tests driven by Python). No Verilator/cocotb on Windows.
- Digilent `vivado-library` = git submodule `third_party/vivado-library` @ `f4613ff`. Submodule is never modified.
- Top level hand-written SV (`rtl/top.sv`); Digilent IPs via `create_ip`; PS in block design `ps_bd`: M_AXI_GP0 -> SmartConnect -> `M_AXI_LITE`, base **0x43C00000** (64 KB); `clk_acc` = FCLK_CLK0 100 MHz.
- 200 MHz ref clock from the 125 MHz board clock (clk_wiz PLL) -> video works without ARM software (TIMING.md #1, #2).
- dvi2rgb kClkRange=2, kAddBUFG=true; rgb2dvi internal MMCM kClkRange=2; HPD = PLL locked.
- **Own EDID with only 720p60** (`scripts/make_edid.py` -> `rtl/edid_720p_only.data`, copied over the IP's `dgl_720p_cea.data` in `build/` after generate_target). Reason: Windows chose 1080p with Digilent's EDID (TIMING.md #5).
- Pixel bus order Digilent **R-B-G** (`[23:16]=R, [15:8]=B, [7:0]=G`), only in `rtl/video_pkg.sv`.
- Position from DE only; new frame = long DE-low gap. ROI frame drawn OUTSIDE the ROI.
- Quantization: int8 symmetric weights, uint8 activations, zero point 0, requant `(acc*M + 2^(S-1)) >> S`; fused max-pool on accumulators (QUANTIZATION.md s7); no requant on FC; confidence = top1-top2 margin scaled (margin 8.0 -> 255).
- CNN: P=8 MACs (parameter), output-channel parallel, DSP48 2-stage MAC. ROI buffer double-banked + freeze bit; CNN auto-starts on frame-done; inject mode for ARM test images.
- PyTorch CPU build. Training 12 epochs, augmentation prob 0.7, seed 0.
- Vitis workspace outside repo (`~/fpga_ws/fpga-edge-ai-video`) because repo path has spaces. Run Vivado/Vitis/xsdb from **PowerShell** (Git Bash: "Access is denied" for .bat). Plusargs without "=".

## 8. File map
- `CLAUDE.md` spec/rules. `PROGRESS.md` running log. `HANDOVER.md` this file.
- `rtl/`: `top.sv` (top level), `video_pkg.sv`, `pixel_pipeline.sv` (7-stage chain), `pix_pos_counter.sv`, `rgb2gray.sv`, `roi_overlay.sv`, `digit_overlay.sv`, `conf_bar_overlay.sv`, `font_rom.sv` + `font_digits_8x8.mem`, `ai_view_overlay.sv`, `roi_capture.sv`, `ram_tdp.sv`, `cdc_sync_2ff.sv`, `cdc_pulse_sync.sv`, `cdc_bus_sync.sv`, `axil_regs.sv`, `ai_core.sv` (clk_acc: regs + CNN + inject RAM), CNN: `cnn_pkg.sv`, `cnn_top.sv`, `cnn_controller.sv`, `cnn_mac_array.sv`, `cnn_requant.sv`, `cnn_argmax.sv`; `edid_720p_only.data`.
- `tb/`: `tb_pixel_pipeline.sv`, `tb_cdc.sv`, `tb_axil_regs.sv`, `tb_cnn_units.sv`, CNN/ai_core testbenches (see `scripts/sim_cnn.py`, `scripts/sim_unit.py`).
- `constraints/`: `zybo_z7_10.xdc` (pins from Digilent master XDC, clocks), `zybo_z7_10_impl.xdc` (async clock groups, implementation only).
- `scripts/`: `build_hw.tcl` (whole Vivado project, `-tclargs project|all`), `build_sw.py` (Vitis Python API, `sw/<app>`), `program.tcl` (xsdb JTAG: `bit` or `all <app>`), `make_boot.py` (BOOT.bin, `--app`, `--copy-to`), `make_edid.py`, `synth_cnn.tcl` (OOC CNN per P), `sim_pixel_pipeline.py`, `sim_unit.py`, `sim_cnn.py`, `video_stream.py`, `capture_roi.py`.
- `sw/`: `hello/`, `roi_capture/`, `edge_ai_demo/main.c` (Phase 6 live demo), `common/edge_ai_regs.h` (register map), `common/mnist_test_images.h` (20 images + golden results, generated).
- `ml/`: `model.py`, `data_utils.py`, `train.py`, `quantize.py`, `golden_int.py`, `check_golden.py`, `evaluate.py`, `export.py` (weights .mem, `cnn_params_pkg.sv`, `wrom_p{P}.mem`, `brom_p{P}.mem`, vectors, `mnist_test_images.h`), `model_float.npz`, `quant_params.npz`, `export/`, `reports/accuracy.md`, `captures/`, `data/` (git-ignored).
- `docs/`: `LEARNING.md`, `QUANTIZATION.md`, `CDC.md`, `TIMING.md` (#1-#5), `images/`. `RESULTS.md` to be written in Phase 7.

## 9. How to build and test (repo root `C:\Users\User\Documents\FPGA\Project\FPGA Edge AI Video`, PowerShell)
```
git submodule update --init                                      # after a fresh clone
python -m venv .venv; .\.venv\Scripts\python.exe -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
.\.venv\Scripts\python.exe -m pip install -r ml/requirements.txt; .\.venv\Scripts\python.exe ml/download_mnist.py
.\.venv\Scripts\python.exe ml/export.py                           # regenerate weights/vectors (1000-image vectors are git-ignored)
.\.venv\Scripts\python.exe scripts/sim_pixel_pipeline.py          # image sims
.\.venv\Scripts\python.exe scripts/sim_unit.py                    # unit tbs incl. tb_ai_core
.\.venv\Scripts\python.exe scripts/sim_cnn.py --p 8 --n 1000      # CNN bit-exact vs golden
& "C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -nojournal -log build/vivado_build.log -source scripts/build_hw.tcl -tclargs all   # ~5-10 min
& "C:\Xilinx\2025.1\Vivado\bin\vivado.bat" -mode batch -nojournal -log build/synth_cnn.log -source scripts/synth_cnn.tcl -tclargs 1 2 4 8 16
& "C:\Xilinx\2025.1\Vitis\bin\vitis.bat" -s scripts/build_sw.py edge_ai_demo
.\.venv\Scripts\python.exe scripts/make_boot.py --app edge_ai_demo --copy-to G:\    # check SD drive letter first
& "C:\Xilinx\2025.1\Vivado\bin\xsdb.bat" scripts/program.tcl all edge_ai_demo       # JTAG instead of SD (boot jumper JTAG)
```
Board: power jumper USB; boot jumper SD (BOOT.bin) or JTAG (xsdb). UART **115200 baud, 8N1, no flow control**, COM17 or COM16. Laptop display 1280x720@60 (EDID now only offers that).

## 10. Measured results so far
All in `docs/RESULTS.md` with methods. Key numbers:
- **On board, 10,000 MNIST test images: 98.25 % accuracy, 10,000/10,000 bit-exact vs golden (all FC accumulators);**
  ARM C model also bit-exact. FPGA CNN 239.65 us (23,965 cycles @100 MHz) vs ARM Cortex-A9 C -O2 2,236 us -> **9.3x**;
  ARM-driven (incl. 784 AXI writes) 381 us -> 5.9x.
- P sweep (OOC, 100 MHz met for all): P1 1,767 us / 726 LUT / 3 DSP ... P8 240 us / 888 LUT / 10 DSP ... P16 176 us / 1,056 LUT / 18 DSP.
- Full design P=8: WNS +0.302 ns, 2,710 LUT (15.4 %), 2,985 FF, 5 BRAM, 10 DSP, power est. 2.04 W (PS7 1.40 W, CNN 0.023 W).
  P=1: WNS +0.866, 2,547 LUT; P=16: WNS +0.515, 2,873 LUT.
- ML: float 98.24 %, int8 golden 98.25 %. Not yet measured: FPS/skipped frames, real-drawing accuracy.

## 11. Next steps
1. User connects laptop HDMI -> board HDMI RX and HDMI TX -> TV (laptop 1280x720). Board on JTAG.
2. `& "C:\Xilinx\2025.1\Vivado\bin\xsdb.bat" scripts/program.tcl all edge_ai_demo`, then send `f` on COM17 (pyserial,
   115200) and read the "FPS ..." line (60 s) -> RESULTS.md section 4 (also: pipeline latency 7 pixel clocks from sim,
   throughput 1280x720x60x24 bit = 1.33 Gbit/s active pixels, 74.25 MHz x 24 = 1.78 Gbit/s incl. blanking).
3. Drawing session: `.venv\Scripts\python.exe scripts/capture_roi.py --port COM17`, ~10 per digit -> accuracy from
   `ml/captures/captures.csv` -> RESULTS.md section 5. If < ~90 %: discuss fine-tuning with the user.
4. `make_boot.py --app edge_ai_demo` (new BOOT.bin), PROGRESS/HANDOVER, tag `phase-7-done`. Then Phase 8 (README, demo video, CV bullets).

## 12. Recommended model/effort
- Phase 7 planning: `/model opus` `/effort high`. C model, scripts, benchmark app: `/model sonnet` `/effort medium`. RESULTS.md/docs: `/model sonnet` `/effort low`.

## 13. Git state
- Repo: https://github.com/alvinhdr/fpga-edge-ai-video (private), branch `main`.
- Tags `phase-0-done` .. `phase-6-done`. Submodule `third_party/vivado-library` @ `f4613ff`.
- See `git log -1` for the last commit (this file is committed together with the Phase 6 close).
