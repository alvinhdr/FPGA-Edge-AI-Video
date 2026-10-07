# RESULTS — measured numbers and how each one was measured

Board: Digilent Zybo Z7-10 (XC7Z010-1CLG400C, speed grade -1). Tools: Vivado / Vitis 2025.1.
Rule of this project: **every number here was measured** (on the board, in simulation, or from a
Vivado report). The method is written next to each number. "Estimate" is said where it is one.

## 1. Accuracy and bit-exactness on the board (full MNIST test set)

Measured 2026-10-08, demo bitstream (P = 8), all 10,000 MNIST test images:

| Check | Result |
|---|---|
| **Hardware accuracy vs. true labels** | **98.25 %** (9,825 / 10,000) |
| Python integer golden model accuracy (same images) | 98.25 % |
| Hardware vs. golden model: 10 FC accumulators of every image | **10,000 / 10,000 bit-exact** |
| Hardware vs. golden model: digit + confidence | 10,000 / 10,000 identical |
| ARM C model vs. golden model: digit + confidence | 10,000 / 10,000 identical |
| ARM C model vs. hardware: 10 FC accumulators | 10,000 / 10,000 identical |
| Float (PyTorch) model accuracy, for reference | 98.24 % |

So int8 quantization costs no accuracy here, and the hardware is an exact implementation of the
integer model on every test image (not only "the same digit": the same 32-bit accumulators).

**Method.** `scripts/bench_mnist.py` sends every MNIST test image (10,000) over the UART to the
ARM program `sw/benchmark`. The ARM writes the image into the FPGA's inject RAM, starts the
hardware CNN, and reads back the digit, confidence and the 10 FC accumulators. The same image is
also classified by the C model on the ARM (`sw/common/cnn_ref.h`). The PC compares both with the
Python integer golden model (`ml/golden_int.py`) and with the true labels.
Raw data: `build/bench_mnist.csv` (git-ignored), summary: `ml/reports/hw_benchmark.json`.

## 2. Inference latency and speedup vs. the ARM Cortex-A9

Per image, mean over the same 10,000 images (min-max in brackets):

| | Time per image | Images / s | Speedup |
|---|---|---|---|
| ARM Cortex-A9 @ 666.67 MHz, C model, `-O2` | **2,236 µs** (2,229-2,242) | 447 | 1× |
| FPGA CNN, P = 8 @ 100 MHz (hardware cycle counter: 23,965 cycles for every image) | **239.65 µs** | 4,173 | **9.3×** |
| FPGA CNN as seen by the ARM (784 AXI writes + start + wait + read) | 381 µs | 2,622 | 5.9× |

- The ARM needs about 7.8 CPU clocks per multiply-accumulate (192,064 MACs in 2,236 µs at
  666.67 MHz). The FPGA does 8 MACs per clock at a 6.7× lower clock.
- The ARM-driven time includes about 140 µs of moving the image over AXI-Lite (one 32-bit write
  per pixel). In the live video demo this cost does not exist: the image is already in the
  FPGA's ROI buffer, so the CNN result is ready 240 µs after the frame's ROI is complete.
- 240 µs is 1.4 % of one video frame (16.7 ms), so the CNN can run on every frame with a lot of
  spare time; the ARM alone (2.2 ms) could also keep up with 60 FPS, but would use ~13 % of a CPU
  core for this tiny network and could not scale to larger ones.
- Honest limits: the ARM baseline is plain C (no NEON SIMD, one core). A NEON-optimized version
  would be faster; the FPGA is also not at its limit (P = 16: 176 µs).

**Method.**
- FPGA CNN time: the hardware cycle counter `CNN_CYCLES` (clk_acc = 100 MHz), read for every image.
- ARM software time: the Cortex-A9 global timer (CPU clock / 2 = 333.33 MHz, 3 ns resolution)
  around `cnn_ref_infer()` only, for every image.
- "ARM-driven" FPGA time: the same timer around the full sequence the ARM sees: 784 AXI-Lite
  writes of the image + start + wait + read result.
- The C model is plain portable C (no NEON, no hand optimization), compiled with **`-O2`**
  (arm-none-eabi-gcc 13.3, `-mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard`), single core,
  caches enabled (standalone BSP default), CPU at 666.67 MHz. Vitis' default is `-O0`; the
  build script sets `-O2` so the comparison is fair.

## 3. Speed vs. area: MAC parallelism P

CNN accelerator alone (`cnn_top`), out-of-context, XC7Z010-1, 100 MHz clock constraint:

| P (MACs) | Cycles / image | Time @100 MHz | Speed vs P=1 | Slice LUTs | FFs | BRAM (36 Kb) | DSP48 | WNS @100 MHz | Fmax (est.) |
|---|---|---|---|---|---|---|---|---|---|
| 1  | 176,711 | 1,767 µs | 1.0× | 726   | 745   | 3.5 | 3  | +0.510 ns | ~105 MHz |
| 2  |  89,251 |   893 µs | 2.0× | 758   | 776   | 3.5 | 4  | +1.170 ns | ~113 MHz |
| 4  |  45,725 |   457 µs | 3.9× | 787   | 839   | 4.0 | 6  | +0.602 ns | ~106 MHz |
| **8** (demo) | **23,965** | **240 µs** | **7.4×** | **888** | **966** | **3.5** | **10** | **+0.507 ns** | **~105 MHz** |
| 16 |  17,613 |   176 µs | 10.0× | 1,056 | 1,216 | 3.5 | 18 | +0.405 ns | ~104 MHz |

Whole design (video pipeline + ROI capture + CNN + AXI + PS), placed and routed, `build_hw.tcl all <P>`:

| P | Slice LUTs | FFs | BRAM tiles | DSP48 | WNS (all clocks) | WHS | Power (estimate) | of which ai_core |
|---|---|---|---|---|---|---|---|---|
| 1  | 2,547 (14.5 %) | 2,764 | 5 | 3  | +0.866 ns | +0.054 ns | 2.028 W | 0.016 W |
| **8** | **2,710 (15.4 %)** | **2,985** | **5** | **10** | **+0.302 ns** | **+0.011 ns** | **2.038 W** | **0.025 W** |
| 16 | 2,873 (16.3 %) | 3,235 | 5 | 18 | +0.515 ns | +0.016 ns | 2.054 W | 0.040 W |

All three meet timing with 0 critical warnings in synthesis/implementation. Only the P = 8
bitstream was tested on the board. Even P = 16 uses only 16 % of the LUTs of the smallest Zybo.

- Every P is bit-exact against the golden model in simulation (all layers, 20 images).
- DSPs = P (MAC lanes) + 2 (requantization multiplier, confidence multiplier).
- From P = 8 to 16 the speed gain is only 1.36×: layer 1 has 8 output channels, so half of
  16 lanes are idle there, and every pooled position has a fixed overhead (pipeline drain +
  write-back) that does not shrink with P.
- P = 8 was chosen for the demo: 70× faster than one video frame needs (240 µs vs 16.7 ms),
  with half the DSPs of P = 16.
- "Fmax (est.)" = 1 / (10 ns − WNS). It is only an estimate: Vivado stops optimizing once
  the 100 MHz target is met.
- Note: Phase 5 notes said "1,211 LUT" for P = 8. That was the number of LUT *cells*; the
  standard "Slice LUTs" number from the utilization report is 888 (two small LUT functions can
  share one physical LUT6). This table uses Slice LUTs.

**Method.** Cycles per inference: simulation of `rtl/cnn_top.sv` (`scripts/sim_cnn.py`), every P
bit-exact against the golden model. Resources and timing: out-of-context synthesis + place +
route of the CNN alone at 100 MHz on the XC7Z010 (`scripts/synth_cnn.tcl`). Full-system numbers:
`scripts/build_hw.tcl all <P>`.

## 4. Video: frame rate, skipped frames, throughput, latency

_Pending: needs HDMI connected (`f` command in `sw/edge_ai_demo`)._

## 5. Accuracy on real handwritten digits (drawn in Paint, captured from the live video)

_Pending: needs HDMI connected + drawing session (`scripts/capture_roi.py`)._

## 6. Full design: resources, timing, power (P = 8, the demo build)

| Resource | Used | Available | % |
|---|---|---|---|
| Slice LUTs | 2,710 | 17,600 | 15.4 % |
| Flip-flops | 2,985 | 35,200 | 8.5 % |
| Block RAM tiles (36 Kb) | 5 | 60 | 8.3 % |
| DSP48E1 | 10 | 80 | 12.5 % |

- Timing: **WNS +0.302 ns, WHS +0.011 ns**, 0 failing endpoints, all clocks (74.25 MHz pixel,
  100 MHz accelerator, 125/200 MHz reference, HDMI serial clocks).
- Power: **2.04 W total on-chip (Vivado estimate**, default activity, confidence "Low", not
  measured). Breakdown: Zynq PS7 (ARM, DDR) 1.40 W, MMCM + PLL (HDMI and reference clocks)
  0.29 W, I/O 0.17 W, static 0.13 W. **The whole CNN accelerator: 0.023 W** (ai_core 0.025 W).
- Source: `build/reports/utilization.rpt`, `timing_summary.rpt`, `power.rpt` from `scripts/build_hw.tcl all`.
