# =============================================================================
# File   : golden_int.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: The INTEGER-ONLY golden model. It implements docs/QUANTIZATION.md section 5
#          literally. The SystemVerilog accelerator (Phase 5) must match it bit-exactly.
#          No floating point is used in inference (int64 numpy everywhere).
#
# infer(x_q, q) takes x_q: uint8 [N, 28, 28] and returns a dict of integer arrays:
#   l1 [N,8,26,26], p1 [N,8,13,13], l2 [N,16,11,11], p2 [N,16,5,5]  (uint8 values)
#   acc [N,10] (int32 values), digit [N], conf [N]
# =============================================================================
import os

import numpy as np

QUANT_NPZ = os.path.join(os.path.dirname(os.path.abspath(__file__)), "quant_params.npz")
ACC_LIMIT = 2 ** 24      # accumulators must fit 25-bit signed: |acc| < 2^24


def load_params(path=QUANT_NPZ):
    return {k: v for k, v in np.load(path).items()}


def requant(acc, M, S):
    """clamp((acc * M + 2^(S-1)) >> S, 0, 255). >> on int64 is an arithmetic shift (floor)."""
    return np.clip((acc * int(M) + (1 << (int(S) - 1))) >> int(S), 0, 255)


def conv3x3(x, w, b, M, S):
    """x [N,C,H,W] int64, w [O,C,3,3] int64, b [O] int64 -> uint8-range [N,O,H-2,W-2]."""
    n, c, h, wd = x.shape
    o = w.shape[0]
    win = np.lib.stride_tricks.sliding_window_view(x, (3, 3), axis=(2, 3))      # [N,C,H-2,W-2,3,3]
    cols = win.transpose(0, 2, 3, 1, 4, 5).reshape(n, h - 2, wd - 2, c * 9)     # [N,H',W',C*9]
    acc = cols @ w.reshape(o, c * 9).T + b                                      # [N,H',W',O] int64
    assert np.abs(acc).max() < ACC_LIMIT, "conv accumulator exceeds 25 bits"
    return requant(acc, M, S).transpose(0, 3, 1, 2), acc.transpose(0, 3, 1, 2)


def maxpool2(a):
    """2x2 max-pool, stride 2, floor: odd last row/column is dropped (11 -> 5)."""
    n, c, h, w = a.shape
    h2, w2 = h // 2, w // 2
    a = a[:, :, :2 * h2, :2 * w2].reshape(n, c, h2, 2, w2, 2)
    return a.max(axis=(3, 5))


def infer(x_q, q):
    x = np.asarray(x_q).astype(np.int64)[:, None, :, :]                    # [N,1,28,28]
    l1, _ = conv3x3(x, q["w1"], q["b1"], q["M1"], q["S1"])
    p1 = maxpool2(l1)
    l2, _ = conv3x3(p1, q["w2"], q["b2"], q["M2"], q["S2"])
    p2 = maxpool2(l2)
    flat = p2.reshape(len(x), -1)                                           # index c*25 + y*5 + x
    acc = flat @ q["wf"].T + q["bf"]                                        # [N,10]
    assert np.abs(acc).max() < ACC_LIMIT, "FC accumulator exceeds 25 bits"

    digit = np.argmax(acc, axis=1)                                          # ties -> smallest index
    top1 = acc[np.arange(len(acc)), digit]
    masked = acc.copy()
    masked[np.arange(len(acc)), digit] = np.iinfo(np.int64).min
    top2 = masked.max(axis=1)
    diff = top1 - top2                                                      # >= 0
    conf = np.minimum(255, (diff * int(q["MC"]) + (1 << (int(q["SC"]) - 1))) >> int(q["SC"]))
    return {"l1": l1, "p1": p1, "l2": l2, "p2": p2, "acc": acc, "digit": digit, "conf": conf}


def infer_batched(x_q, q, chunk=1000):
    parts = [infer(x_q[i:i + chunk], q) for i in range(0, len(x_q), chunk)]
    return {k: np.concatenate([p[k] for p in parts]) for k in parts[0]}
