# =============================================================================
# File   : check_golden.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Cross-check ml/golden_int.py against an INDEPENDENT implementation of
#          docs/QUANTIZATION.md written with PyTorch (F.conv2d / F.max_pool2d /
#          F.linear on float64 tensors that hold integers; exact because every
#          value stays far below 2^53). Every layer output must be bit-identical.
#
# Usage:  .venv\Scripts\python.exe ml/check_golden.py [--n 2000]
# =============================================================================
import argparse
import sys

import numpy as np
import torch
import torch.nn.functional as F

import golden_int
from data_utils import load_mnist


def torch_infer(x_q, q):
    t = lambda a: torch.from_numpy(np.asarray(a)).to(torch.float64)

    def rq(acc, M, S):      # same formula, done with torch integer ops
        a = acc.to(torch.int64)
        return torch.clamp(torch.bitwise_right_shift(a * int(M) + (1 << (int(S) - 1)), int(S)), 0, 255)

    x = t(x_q).unsqueeze(1)
    a1 = rq(F.conv2d(x, t(q["w1"]), t(q["b1"])), q["M1"], q["S1"])
    p1 = F.max_pool2d(a1.to(torch.float64), 2).to(torch.int64)
    a2 = rq(F.conv2d(p1.to(torch.float64), t(q["w2"]), t(q["b2"])), q["M2"], q["S2"])
    p2 = F.max_pool2d(a2.to(torch.float64), 2).to(torch.int64)
    acc = F.linear(p2.flatten(1).to(torch.float64), t(q["wf"]), t(q["bf"])).to(torch.int64)
    top2 = torch.topk(acc, 2, dim=1).values
    conf = torch.clamp(torch.bitwise_right_shift((top2[:, 0] - top2[:, 1]) * int(q["MC"])
                                                 + (1 << (int(q["SC"]) - 1)), int(q["SC"])), max=255)
    return {"l1": a1, "p1": p1, "l2": a2, "p2": p2, "acc": acc, "digit": acc.argmax(1), "conf": conf}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=2000)
    n = ap.parse_args().n
    q = golden_int.load_params()
    _, _, xte, _ = load_mnist()
    x = xte[:n]
    ref = golden_int.infer_batched(x, q)
    other = torch_infer(x, q)
    ok = True
    for key in ("l1", "p1", "l2", "p2", "acc", "digit", "conf"):
        same = np.array_equal(ref[key], other[key].numpy())
        ok &= same
        print(f"{key:5s} {'identical' if same else 'MISMATCH'}  shape {ref[key].shape}")
    print(f"golden_int vs independent PyTorch integer model on {n} MNIST test images: "
          f"{'ALL BIT-EXACT' if ok else 'FAILED'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
