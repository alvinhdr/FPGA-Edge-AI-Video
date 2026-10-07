# QUANTIZATION — the exact integer math

This file is the **specification**. The Python integer golden model (`ml/golden_int.py`) and the
SystemVerilog accelerator (Phase 5) both implement exactly these formulas. If they disagree with
this file, they are wrong.

## 1. Network

| Layer | Input | Operation | Output |
|---|---|---|---|
| L1 | 28×28×1 uint8 | conv 3×3, 8 filters, stride 1, no padding, + bias, ReLU | 26×26×8 uint8 |
| P1 | 26×26×8 | max-pool 2×2, stride 2 | 13×13×8 uint8 |
| L2 | 13×13×8 | conv 3×3, 16 filters, stride 1, no padding, + bias, ReLU | 11×11×16 uint8 |
| P2 | 11×11×16 | max-pool 2×2, stride 2 (last row/column dropped: floor(11/2) = 5) | 5×5×16 uint8 |
| F1 | 400 (flatten) | fully connected 400 → 10, + bias, no ReLU | 10 × int32 |
| Out | 10 × int32 | argmax → digit, top-1/top-2 margin → confidence | digit (4 bit), confidence (8 bit) |

Parameter count: L1 72 + 8, L2 1152 + 16, F1 4000 + 10 → **5,224 int8 weights**, 34 int32 biases.
MACs per image: L1 26·26·8·9 = 48,672; L2 11·11·16·72 = 139,392; F1 4,000 → **192,064 MACs**.

## 2. Number formats

| Thing | Type | Range | Zero point |
|---|---|---|---|
| Input pixels / all activations | **uint8** | 0..255 | 0 |
| Weights | **int8**, symmetric | −127..127 (−128 never used) | 0 |
| Biases | **int32** | | 0 |
| Accumulators | **int32** (must fit in 25-bit signed, see §6) | | |
| Requantization multiplier `M` | **uint15** | 16384..32767 | |
| Requantization shift `S` | integer | 15..40 (export fails otherwise) | |

Every tensor has one real-valued **scale** `s` (per-tensor quantization):
`real_value = s × integer_value`. All zero points are 0, which removes every zero-point
correction term from the hardware. This is possible because:
- weights are symmetric around 0;
- all activations are ≥ 0 (input pixels, and outputs of ReLU), so uint8 with zero point 0 loses nothing.

**Data layout** (same in Python, `.mem` files and hardware):
- feature maps: `[channel][y][x]`
- conv weights: `[out_ch][in_ch][ky][kx]`
- FC weights: `[out][in]`, where the FC input index is `in = c·25 + y·5 + x` (PyTorch flatten order of P2's `[c][y][x]`).

## 3. Input

The network input is a 28×28 uint8 image `x_q`, **white digit on black background** (MNIST style),
with real value `x = x_q / 255`, so **`s_in = 1/255`**. Training uses exactly this scaling
(`x/255`, no mean/std normalization), so no zero point is needed.

(Live video is dark pen on white, so the hardware preprocessing inverts it; see §8.)

## 4. Quantizing the trained float model (done once, in Python)

1. **Weights** of layer `l`: `s_w = max|W| / 127`, `w_q = clamp(round(W / s_w), −127, 127)`.
2. **Activation scales**: run the float model on calibration images (the MNIST training set) and
   record the largest output of each ReLU layer. `s_L1 = max_L1 / 255`, `s_L2 = max_L2 / 255`.
   (Max-pool does not change the scale, so `s_P1 = s_L1`, `s_P2 = s_L2`.)
3. **Biases**: `b_q = round(B / (s_x · s_w))`, where `s_x` is the scale of that layer's input.
4. **Requantization constants** of layers L1 and L2 (input scale `s_x`, output scale `s_y`):
   `m = s_x · s_w / s_y` (a real number, always < 1 in practice).
   Choose the shift `S` so that `M = round(m · 2^S)` lies in **[16384, 32767]** (15-bit, top bit set):
   `S = 14 − floor(log2(m))`, then `M = round(m · 2^S)`; if rounding gives 32768, use `M = 16384`, `S = S − 1`.
   `S` must be in 15..40, which means `2^−26 < m < 1`. The export checks this and stops with an
   error otherwise (S ≥ 15 keeps the hardware shift simple; S ≤ 40 keeps `acc·M + 2^(S−1)` inside 48 bits).

`round()` here is "round half away from zero" (`numpy.round` is NOT used; see `ml/quantize.py`).
These steps run in floating point once; the results (`w_q`, `b_q`, `M`, `S`) are plain integers
and are the only numbers the hardware ever sees.

## 5. Integer inference (what the hardware does)

### Convolution layer (L1, L2), for every output channel `o`, row `y`, column `x`:

```
acc = b_q[o] + Σ_{i, ky, kx}  x_q[i][y+ky][x+kx] · w_q[o][i][ky][kx]        (int32)
y_q[o][y][x] = clamp( (acc · M + 2^(S−1)) >> S , 0, 255 )                   (uint8)
```

- `>>` is an **arithmetic shift right** on a signed number (= floor division by 2^S).
  Adding `2^(S−1)` first makes it **round half up**.
- The lower clamp at 0 **is** the ReLU (no separate ReLU step). The upper clamp at 255 saturates.
- `acc · M` needs 25 + 16 = 41 bits signed; compute it in 48 bits (one DSP48E1 multiply: 25 × 18).

### Max-pool (P1, P2)

```
p[c][y][x] = max( a[c][2y][2x], a[c][2y][2x+1], a[c][2y+1][2x], a[c][2y+1][2x+1] )
```
Done on the uint8 values. Because requantization is monotonic and all four values share one scale,
"pool the integers" is exactly "pool the real values".

### Fully connected (F1)

```
acc[k] = b_q[k] + Σ_{n=0}^{399} p2[n] · w_q[k][n]          for k = 0..9    (int32, no requantization)
```
All 10 outputs share the same scale `s_P2 · s_w_F1`, so the **largest `acc` is the largest real logit**.
No requantization is needed for the prediction.

### Prediction and confidence

```
digit = index of the largest acc[k]          (ties → the smallest index)
top1  = acc[digit],  top2 = largest acc[k] for k ≠ digit
diff  = top1 − top2                          (≥ 0)
conf  = min( 255, (diff · M_c + 2^(S_c−1)) >> S_c )         (uint8)
```

`M_c`, `S_c` are chosen like §4.4 so that a **real logit margin of 8.0 maps to 255**:
`m_c = s_P2 · s_w_F1 · 255 / 8.0`. A margin of 8 means the top class is about e^8 ≈ 3000×
more likely than the second, which is "fully confident" for the on-screen bar.

## 6. Bit-width checks (asserted by `ml/golden_int.py` on every image)

| Accumulator | Worst case from sizes | Limit used in hardware |
|---|---|---|
| L1 | 9 · 255 · 127 = 291,465 (+ bias) | 25-bit signed (±16,777,215) |
| L2 | 72 · 255 · 127 = 2,331,720 (+ bias) | 25-bit signed |
| F1 | 400 · 255 · 127 = 12,954,000 (+ bias) | 25-bit signed |

The golden model checks `|acc| < 2^24` and `|b_q| < 2^24` for every layer and every image.
If a trained model ever breaks this, the export fails (instead of silently overflowing).

## 7. What "bit-exact" means in this project

For every test image, the RTL must produce the same `L1`, `P1`, `L2`, `P2` uint8 feature maps,
the same 10 F1 accumulators, the same `digit`, and the same `conf` as `ml/golden_int.py`.
`ml/export.py` writes all of these intermediate results as test vectors.

## 8. Input preprocessing in hardware (Phase 4, defined here so training can match it)

From the 224×224 ROI of the live video to the 28×28 network input:

```
g        = (77·R + 150·G + 29·B) >> 8          (same as rtl/rgb2gray.sv)
g_inv    = invert ? 255 − g : g                (live video: dark pen on white → invert = 1)
avg      = (Σ of the 8×8 block of g_inv + 32) >> 6      (8×8 average, round half up)
x_q      = (threshold_en && avg < T) ? 0 : avg  (optional: remove the gray background)
```

`invert`, `threshold_en` and `T` are AXI-Lite registers. Real ROI captures from the board (Phase 4)
go through exactly this path, so fine-tuning on them sees the same input the CNN gets live.
