# =============================================================================
# File   : finetune.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Fix the domain gap (CLAUDE.md section 3, point 8): fine-tune the MNIST model with
#          the real ROI captures from the board (ml/captures/captures.csv), optionally
#          with USPS digits for extra handwriting variety.
#
# Honest evaluation: "cv" mode = 2-fold cross-validation over the captures. The k-th drawing of
# each digit goes to fold k % 2. A model is trained on one fold (+ MNIST [+ USPS]) and tested on
# the OTHER fold, which it never saw; then the folds are swapped. All accuracies are measured on
# the INTEGER model (quantize.py + golden_int.py), which the hardware matches bit-exactly.
# "final" mode trains on ALL captures and saves the model for the demo (no unseen data is left
# for it, so its number comes from "cv").
#
# Usage (repo root):
#   .venv\Scripts\python.exe ml/finetune.py cv   [--steps 1200] [--seeds 1]
#   .venv\Scripts\python.exe ml/finetune.py final [--usps] [--steps 1200]
#     -> ml/model_float_ft.npz, ml/quant_params_ft.npz (the originals are NOT touched)
# =============================================================================
import argparse
import csv
import os
import time
from collections import Counter

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image
from torchvision.datasets import USPS

import golden_int
import quantize
from data_utils import DATA_DIR, augment, load_mnist, to_float
from model import net_from_numpy, params_to_numpy

HERE = os.path.dirname(os.path.abspath(__file__))
CAP_DIR = os.path.join(HERE, "captures")
FLOAT_NPZ = os.path.join(HERE, "model_float.npz")
QUANT_NPZ = os.path.join(HERE, "quant_params.npz")
OUT_FLOAT = os.path.join(HERE, "model_float_ft.npz")
OUT_QUANT = os.path.join(HERE, "quant_params_ft.npz")
AUG_PROB = 0.7          # MNIST / USPS samples that get augmented (same as train.py)
CAP_AUG_PROB = 0.5      # captured samples that get augmented (they are already "real")


def load_captures():
    """Returns x uint8 [N,28,28], y int64 [N], fold int [N] (k-th drawing of a digit -> k % 2)."""
    xs, ys, folds, seen = [], [], [], Counter()
    with open(os.path.join(CAP_DIR, "captures.csv")) as fh:
        for r in csv.DictReader(fh):
            label = int(r["label"])
            xs.append(np.array(Image.open(os.path.join(CAP_DIR, r["file"])).convert("L"), dtype=np.uint8))
            ys.append(label)
            folds.append(seen[label] % 2)
            seen[label] += 1
    return np.stack(xs), np.array(ys, dtype=np.int64), np.array(folds)


def load_usps_train():
    """USPS train split (16x16) -> 28x28 like MNIST: scaled to 20x20, centered with a 4 px border."""
    ds = USPS(DATA_DIR, train=True, download=False)
    x = torch.from_numpy(np.asarray(ds.data)).float().unsqueeze(1)             # [N,1,16,16]
    x = F.interpolate(x, size=20, mode="bilinear", align_corners=False)
    x = F.pad(x, (4, 4, 4, 4)).clamp(0, 255)
    return x.squeeze(1).round().to(torch.uint8).numpy(), np.asarray(ds.targets, dtype=np.int64)


def train(init_params, mnist, caps, usps, steps, seed, lr=5e-4):
    """Fine-tune from init_params. Every step: 64 MNIST + 32 captures (+ 32 USPS) samples."""
    torch.manual_seed(seed)
    gen = torch.Generator().manual_seed(seed)
    net = net_from_numpy(init_params)
    net.train()
    opt = torch.optim.Adam(net.parameters(), lr=lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=steps)
    sets = [(mnist, 64, AUG_PROB), (caps, 32, CAP_AUG_PROB)] + ([(usps, 32, AUG_PROB)] if usps is not None else [])
    for _ in range(steps):
        xb, yb = [], []
        for (x, y), n, p in sets:
            idx = torch.randint(0, len(x), (n,), generator=gen)
            xx, yy = x[idx], y[idx]
            use = torch.rand(n, 1, 1, 1, generator=gen) < p
            xb.append(torch.where(use, augment(xx, gen), xx))
            yb.append(yy)
        loss = F.cross_entropy(net(torch.cat(xb)), torch.cat(yb))
        opt.zero_grad()
        loss.backward()
        opt.step()
        sched.step()
    return net.eval()


def to_tensors(x_u8, y):
    return to_float(x_u8), torch.from_numpy(y)


def quantized(net):
    fp = params_to_numpy(net)
    max1, max2 = quantize.calibrate(net)
    return quantize.quantize(fp, max1, max2), fp


def int_acc(q, x_u8, y):
    return float((golden_int.infer_batched(x_u8, q)["digit"] == y).mean() * 100)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["cv", "final"])
    ap.add_argument("--steps", type=int, default=1200)
    ap.add_argument("--seeds", type=int, default=1)
    ap.add_argument("--usps", action="store_true", help="final mode: also train with USPS")
    args = ap.parse_args()

    xtr_u8, ytr, xte_u8, yte = load_mnist()
    mnist = to_tensors(xtr_u8, ytr)
    cap_x, cap_y, cap_fold = load_captures()
    print(f"{len(cap_x)} captures, folds: {np.bincount(cap_fold).tolist()}")
    usps = to_tensors(*load_usps_train())
    print(f"USPS train: {len(usps[0])} images")
    init = dict(np.load(FLOAT_NPZ))
    base_q = {k: v for k, v in np.load(QUANT_NPZ).items()}

    if args.mode == "cv":
        print(f"baseline (original MNIST-only int model): captures {int_acc(base_q, cap_x, cap_y):.1f} %, "
              f"MNIST test {int_acc(base_q, xte_u8, yte):.2f} %")
        results = {}
        for name, use_usps in (("captures", False), ("captures + USPS", True)):
            correct = total = 0
            mn = []
            for seed in range(args.seeds):
                for held in (0, 1):
                    t0 = time.time()
                    tr = cap_fold != held
                    net = train(init, mnist, to_tensors(cap_x[tr], cap_y[tr]), usps if use_usps else None,
                                args.steps, seed)
                    q, _ = quantized(net)
                    te = cap_fold == held
                    c = int_acc(q, cap_x[te], cap_y[te]) * te.sum() / 100
                    m = int_acc(q, xte_u8, yte)
                    correct += c
                    total += te.sum()
                    mn.append(m)
                    base_c = int_acc(base_q, cap_x[te], cap_y[te])
                    print(f"  [{name}] seed {seed} held-out fold {held}: {c:.0f}/{te.sum()} correct "
                          f"({c / te.sum() * 100:.1f} %, baseline {base_c:.1f} %), MNIST test {m:.2f} %  "
                          f"({time.time() - t0:.0f} s)", flush=True)
            results[name] = (correct / total * 100, float(np.mean(mn)))
        print("\n=== 2-fold cross-validation on the real drawings (integer model) ===")
        print(f"baseline MNIST-only model : {int_acc(base_q, cap_x, cap_y):.1f} %   (MNIST test 98.25 %)")
        for name, (a, m) in results.items():
            print(f"fine-tuned, {name:16s}: {a:.1f} %   (MNIST test {m:.2f} %)")
    else:
        net = train(init, mnist, to_tensors(cap_x, cap_y), usps if args.usps else None, args.steps, 0)
        q, fp = quantized(net)
        np.savez(OUT_FLOAT, **fp)
        np.savez(OUT_QUANT, **q)
        print(f"final model (all {len(cap_x)} captures{' + USPS' if args.usps else ''}): "
              f"MNIST test {int_acc(q, xte_u8, yte):.2f} %, captures (TRAINED on, not a test!) "
              f"{int_acc(q, cap_x, cap_y):.1f} %")
        print(f"saved {OUT_FLOAT} and {OUT_QUANT}")


if __name__ == "__main__":
    main()
