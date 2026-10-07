# =============================================================================
# File   : quantize.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Float model -> integer parameters, exactly as in docs/QUANTIZATION.md section 4.
#          Result: ml/quant_params.npz (plain integers: the only numbers the hardware sees).
#
# Usage (repo root):  .venv\Scripts\python.exe ml/quantize.py
# =============================================================================
import os

import numpy as np
import torch

from data_utils import augment, load_mnist, to_float
from model import net_from_numpy

HERE = os.path.dirname(os.path.abspath(__file__))
FLOAT_NPZ = os.path.join(HERE, "model_float.npz")
QUANT_NPZ = os.path.join(HERE, "quant_params.npz")

S_IN = 1.0 / 255.0          # input scale: x_real = x_q / 255
CONF_FULL_MARGIN = 8.0      # a real logit margin of 8.0 maps to confidence 255


def round_half_away(x):
    """Round half away from zero (numpy.round is round-half-even and is NOT used)."""
    x = np.asarray(x, dtype=np.float64)
    return np.sign(x) * np.floor(np.abs(x) + 0.5)


def quantize_weights(w):
    s = float(np.max(np.abs(w))) / 127.0
    q = np.clip(round_half_away(w / s), -127, 127).astype(np.int64)
    return q, s


def mult_shift(m):
    """Real multiplier 0 < m < 1  ->  (M, S) with M in [16384, 32767], m ~= M / 2^S."""
    assert 0.0 < m < 1.0, f"requantization factor {m} not in (0, 1)"
    s = 14 - int(np.floor(np.log2(m)))
    mm = int(round_half_away(m * 2.0 ** s))
    if mm == 32768:
        mm, s = 16384, s - 1
    assert 16384 <= mm <= 32767 and 15 <= s <= 40, f"M={mm}, S={s} out of range"
    return mm, s


def calibrate(net):
    """Largest ReLU output of L1 and L2 over the training set (clean + one augmented pass)."""
    xtr_u8, _, _, _ = load_mnist()
    x = to_float(xtr_u8)
    gen = torch.Generator().manual_seed(123)
    max1 = max2 = 0.0
    with torch.no_grad():
        for i in range(0, len(x), 2000):
            xb = x[i:i + 2000]
            for batch in (xb, augment(xb, gen)):
                _, a1, a2 = net(batch, return_acts=True)
                max1, max2 = max(max1, a1.max().item()), max(max2, a2.max().item())
    return max1, max2


def quantize(float_params, max1, max2):
    p = float_params
    w1, s_w1 = quantize_weights(p["w1"])
    w2, s_w2 = quantize_weights(p["w2"])
    wf, s_wf = quantize_weights(p["wf"])
    s_y1, s_y2 = max1 / 255.0, max2 / 255.0

    q = {"w1": w1, "w2": w2, "wf": wf,
         "b1": round_half_away(p["b1"] / (S_IN * s_w1)).astype(np.int64),
         "b2": round_half_away(p["b2"] / (s_y1 * s_w2)).astype(np.int64),
         "bf": round_half_away(p["bf"] / (s_y2 * s_wf)).astype(np.int64)}
    q["M1"], q["S1"] = mult_shift(S_IN * s_w1 / s_y1)
    q["M2"], q["S2"] = mult_shift(s_y1 * s_w2 / s_y2)
    q["MC"], q["SC"] = mult_shift(s_y2 * s_wf * 255.0 / CONF_FULL_MARGIN)
    for k in ("M1", "S1", "M2", "S2", "MC", "SC"):
        q[k] = np.int64(q[k])
    for k in ("b1", "b2", "bf"):
        assert np.abs(q[k]).max() < 2 ** 24, f"bias {k} does not fit 25-bit signed"
    # Real-valued scales, only for reports (not used by the hardware)
    q["scales"] = np.array([S_IN, s_w1, s_y1, s_w2, s_y2, s_wf])
    return q


def main():
    fp = dict(np.load(FLOAT_NPZ))
    net = net_from_numpy(fp)
    max1, max2 = calibrate(net)
    q = quantize(fp, max1, max2)
    np.savez(QUANT_NPZ, **q)
    print(f"calibration max: L1 {max1:.3f}, L2 {max2:.3f}")
    for name in ("1", "2", "C"):
        print(f"requant {name}: M = {int(q['M' + name])}, S = {int(q['S' + name])}")
    print(f"weight ranges: w1 {q['w1'].min()}..{q['w1'].max()}, w2 {q['w2'].min()}..{q['w2'].max()}, "
          f"wf {q['wf'].min()}..{q['wf'].max()}; bias max |.|: {max(np.abs(q[k]).max() for k in ('b1', 'b2', 'bf'))}")
    print(f"saved {QUANT_NPZ}")


if __name__ == "__main__":
    main()
