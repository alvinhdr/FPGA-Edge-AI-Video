# RESULTS — measured numbers and how each one was measured

Board: Digilent Zybo Z7-10 (XC7Z010-1CLG400C, speed grade -1). Tools: Vivado / Vitis 2025.1.
Rule of this project: **every number here was measured** (on the board, in simulation, or from a
Vivado report). The method is written next to each number. "Estimate" is said where it is one.

## 1. Accuracy and bit-exactness on the board (full MNIST test set)

Measured 2026-10-08, demo bitstream (P = 8) with the **deployed (fine-tuned, section 5.1) model**,
all 10,000 MNIST test images:

| Check | Result |
|---|---|
| **Hardware accuracy vs. true labels** | **97.96 %** (9,796 / 10,000) |
| Python integer golden model accuracy (same images) | 97.96 % |
| Hardware vs. golden model: 10 FC accumulators of every image | **10,000 / 10,000 bit-exact** |
| Hardware vs. golden model: digit + confidence | 10,000 / 10,000 identical |
| ARM C model vs. golden model: digit + confidence | 10,000 / 10,000 identical |
| ARM C model vs. hardware: 10 FC accumulators | 10,000 / 10,000 identical |
| Float (PyTorch) model accuracy, for reference | 97.94 % |

The first model (MNIST only, before fine-tuning) gave the same kind of result on the board:
98.25 % (9,825 / 10,000), 10,000 / 10,000 bit-exact, ARM C 2,236 µs, speedup 9.3x.

So int8 quantization costs no accuracy here, and the hardware is an exact implementation of the
integer model on every test image (not only "the same digit": the same 32-bit accumulators).

**Method.** `scripts/bench_mnist.py` sends every MNIST test image (10,000) over the UART to the
ARM program `sw/benchmark`. The ARM writes the image into the FPGA's inject RAM, starts the
hardware CNN, and reads back the digit, confidence and the 10 FC accumulators. The same image is
also classified by the C model on the ARM (`sw/common/cnn_ref.h`). The PC compares both with the
Python integer golden model (`ml/golden_int.py`) and with the true labels.
Raw data: `build/bench_mnist.csv` (git-ignored), summary: `ml/reports/hw_benchmark.json`.

## 2. Inference latency and speedup vs. the ARM Cortex-A9

Per image, mean over the same 10,000 images (min-max in brackets). The ARM time changed from
2,236 µs (first model) to 2,293 µs with the new weights (+2.5 %; the cause was not investigated,
it is probably data-dependent behaviour in the CPU such as branches and caches); the FPGA time is the same for every image and every set of weights.

| | Time per image | Images / s | Speedup |
|---|---|---|---|
| ARM Cortex-A9 @ 666.67 MHz, C model, `-O2` | **2,293 µs** (2,285-2,298) | 436 | 1× |
| FPGA CNN, P = 8 @ 100 MHz (hardware cycle counter: 23,965 cycles for every image) | **239.65 µs** | 4,173 | **9.6×** |
| FPGA CNN as seen by the ARM (784 AXI writes + start + wait + read) | 381 µs | 2,622 | 6.0× |

- The ARM needs about 8.0 CPU clocks per multiply-accumulate (192,064 MACs in 2,293 µs at
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

CNN accelerator alone (`cnn_top`), out-of-context, XC7Z010-1, 100 MHz clock constraint (made with the
first model's weights; cycle counts are identical for any weights):

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
| **8** (deployed model + CONF_MIN filter) | **2,626 (14.9 %)** | **2,993** | **5** | **10** | **+0.645 ns** | **+0.033 ns** | **2.041 W** | **0.025 W** |
| 16 | 2,873 (16.3 %) | 3,235 | 5 | 18 | +0.515 ns | +0.016 ns | 2.054 W | 0.040 W |

All three meet timing with 0 critical warnings in synthesis/implementation. Only the P = 8
bitstream was tested on the board. The P = 8 row was rebuilt after fine-tuning (new weights);
the P = 1 and P = 16 rows were built with the first model's weights (resources and timing do
not depend on the weight values, but the P = 8 LUT count moved from 2,710 to 2,621 with the
new weights, so the LUT numbers of different builds differ by a few percent). Even P = 16 uses only 16 % of the LUTs of the smallest Zybo.

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

Measured 2026-10-08, demo bitstream (P = 8), laptop 1280x720 @ 60 Hz -> board -> TV, 60 s:

| Measurement | Result |
|---|---|
| Video frames seen by the ROI capture in 60 s | 3,601 |
| CNN inferences finished in the same window | 3,601 |
| Frames without an inference ("skipped") | **0** |
| Frame rate (ARM global timer) | **60.00 FPS** |

**Method.** `f` command of `sw/edge_ai_demo`: the ARM waits for an inference to finish, reads the
hardware counters FRAME_CNT (completed ROI frames) and CNN_COUNT and the global timer, sleeps
60 s, waits again for an inference to finish, and reads all three again. 3,601 = 3,600 frame
intervals + 1 because both ends are counted right after a frame. (The raw `time_us` printed by the
program is 0.1 % too long because it divides the timer by 333 instead of 333.33 MHz; the FPS
value uses the exact frequency.) The 60 s are inside one run with the live demo active: video
passes through to the TV, overlay and AI view are drawn, and the CNN runs on every frame.

Derived from the design, not separately measured:
- Pixel data rate: 1280 x 720 x 60 x 24 bit = **1.33 Gbit/s** of active pixels
  (74.25 MHz x 24 bit = 1.78 Gbit/s including blanking).
- Video path latency: 7 pixel clocks = **94 ns** (7 pipeline registers in `pixel_pipeline.sv`;
  the testbench compares the output with a Python model with exactly this delay, bit-exact).
  No frame buffer: a pixel leaves the board 94 ns after it enters.
- The prediction of frame N is drawn on frame N+1 (ROI is complete at the end of the box,
  the CNN needs 240 µs, the overlay is drawn at the next frame).

## 5. Accuracy on real handwritten digits (drawn in Paint, captured from the live video)

Measured 2026-10-08, demo bitstream (P = 8), the model trained on MNIST only (no fine-tuning).
One person (the project author) drew 140 digits (14 per digit) in Paint with a mouse/pen on a white
canvas, inside the green box; each drawing was captured from the live video (28x28 ROI buffer) and
classified by the **hardware CNN**. Every attempt was kept (no redrawing of wrong ones).
One label typed by mistake was corrected afterwards by looking at the image (8 typed as 6; the chip
had answered 8).

| Result | Value |
|---|---|
| **Hardware accuracy on real drawings** | **79.3 %** (111 / 140) |
| Hardware vs. golden model on the same 140 images (digit + confidence) | 140 / 140 identical |
| Same CNN on clean MNIST (section 1) | 98.25 % |
| Accuracy when the confidence is >= 50 / >= 100 (of 255) | 87.2 % (117 images kept) / 92.0 % (88 kept) |
| Mean confidence when right / when wrong | 170 / 61 |

Per digit (correct / drawn): 0: 13/14, 1: 12/14, 2: 13/14, **3: 14/14**, **4: 6/14**, 5: 12/14,
**6: 3/14**, **7: 14/14**, 8: 12/14, 9: 12/14.
Main confusions (true -> predicted): 4 -> 9 (8x), 6 -> 5 (7x), 6 -> 8 (3x), 8 -> 6 (2x), 9 -> 3 (2x).

**What this means.**
- The hardware is not the problem: it equals the golden model on all 140 images. The drop from
  98.25 % to 79.3 % is the **domain gap**: the model only saw MNIST handwriting (and
  synthetic augmentation), not mouse-drawn digits with thin strokes, small loops and other styles.
- The errors are concentrated: many drawn 4s have a closed top and look like a 9; many 6s have a
  small bottom loop and are read as 5 or 8.
- The confidence is useful: wrong answers have a much lower confidence (mean 61 vs 170).
- Limits of this number: one person, one drawing tool, 140 images; it is a measurement of this
  setup, not a general handwriting accuracy.

### 5.1 Fine-tuning on the captured drawings

79.3 % was below the 90 % line set for this phase, so the model was fine-tuned
(`ml/finetune.py`, same architecture, same quantization scheme; only the weights change).

**Honest test: 2-fold cross-validation.** The k-th drawing of each digit goes to fold k mod 2
(70 + 70 images). Train on one fold + MNIST, test on the other fold (never seen), swap, 3 random
seeds, 1,200 fine-tuning steps (Adam, lr 5e-4, cosine). Accuracy is measured on the **integer**
model (the one the hardware matches bit-exactly).

| Model | Accuracy on unseen real drawings | Accuracy on MNIST test (10,000) |
|---|---|---|
| Original (MNIST only) | 79.3 % (all 140; 75.7 % / 82.9 % on the two folds) | 98.25 % |
| **Fine-tuned on MNIST + real drawings** | **94.0 %** (fold 0: 90.0-91.4 %, fold 1: 97.1 %) | 97.95 % |
| Fine-tuned on MNIST + real drawings + USPS digits | 93.3 % | 97.97 % |

- Fine-tuning gives **+14.7 points on real drawings** for a cost of 0.3 points on MNIST.
- Adding the USPS handwritten-digit set (7,291 images, downloaded from the LIBSVM collection)
  did **not** help (93.3 % vs 94.0 %, within noise), so it is not used.
- The deployed model is trained on **all 140** drawings (final MNIST test accuracy 97.96 %,
  integer model). Its accuracy on new drawings is therefore estimated by the cross-validation
  above (about 94 %), not measured on a separate fresh set.
- The live TV overlay hides results with a confidence below `CONF_MIN` (default 35 of 255; adjustable from the
  terminal). It is only a display filter: all accuracy numbers in this document are measured on the raw hardware
  result and are not affected. Measured with the golden model: an empty box gives confidence 30, faint noise
  up to 33.
- Optimistic bias: the folds come from the same person in the same session (neighbouring
  drawings of the same digit can look alike), so the true accuracy on a new writer is likely lower.

## 6. Full design: resources, timing, power (P = 8, the demo build)

| Resource | Used | Available | % |
|---|---|---|---|
| Slice LUTs | 2,626 | 17,600 | 14.9 % |
| Flip-flops | 2,993 | 35,200 | 8.5 % |
| Block RAM tiles (36 Kb) | 5 | 60 | 8.3 % |
| DSP48E1 | 10 | 80 | 12.5 % |

- Timing: **WNS +0.645 ns, WHS +0.033 ns**, 0 failing endpoints, all clocks (74.25 MHz pixel,
  100 MHz accelerator, 125/200 MHz reference, HDMI serial clocks).
- Power: **2.04 W total on-chip (Vivado estimate**, default activity, confidence "Low", not
  measured). Breakdown: Zynq PS7 (ARM, DDR) 1.40 W, MMCM + PLL (HDMI and reference clocks)
  0.29 W, I/O 0.17 W, static 0.13 W. **The whole CNN accelerator: 0.023 W** (ai_core 0.025 W).
- Source: `build/reports/utilization.rpt`, `timing_summary.rpt`, `power.rpt` from `scripts/build_hw.tcl all`.
