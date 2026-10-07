# =============================================================================
# File   : train.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Train the float CNN on MNIST with augmentation and save the weights
#          to ml/model_float.npz (small, committed, so results are reproducible).
#
# Usage (repo root, PowerShell):  .venv\Scripts\python.exe ml/train.py [--epochs 12]
# =============================================================================
import argparse
import os
import time

import numpy as np
import torch
import torch.nn.functional as F

from data_utils import augment, load_mnist, to_float
from model import Net, params_to_numpy

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "model_float.npz")
AUG_PROB = 0.7          # fraction of training samples that get augmented


def evaluate(net, x, y):
    net.eval()
    with torch.no_grad():
        pred = torch.cat([net(x[i:i + 2000]).argmax(1) for i in range(0, len(x), 2000)])
    return (pred == y).float().mean().item()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=12)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    gen = torch.Generator().manual_seed(args.seed)
    xtr_u8, ytr, xte_u8, yte = load_mnist()
    xtr, xte = to_float(xtr_u8), to_float(xte_u8)
    ytr, yte = torch.from_numpy(ytr), torch.from_numpy(yte)

    net = Net()
    opt = torch.optim.Adam(net.parameters(), lr=args.lr)
    steps = args.epochs * ((len(xtr) + args.batch - 1) // args.batch)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=args.lr, total_steps=steps)

    for ep in range(args.epochs):
        net.train()
        t0 = time.time()
        perm = torch.randperm(len(xtr), generator=gen)
        total = 0.0
        for i in range(0, len(xtr), args.batch):
            idx = perm[i:i + args.batch]
            xb, yb = xtr[idx], ytr[idx]
            use_aug = (torch.rand(len(idx), 1, 1, 1, generator=gen) < AUG_PROB)
            xb = torch.where(use_aug, augment(xb, gen), xb)
            loss = F.cross_entropy(net(xb), yb)
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            total += loss.item() * len(idx)
        acc = evaluate(net, xte, yte)
        print(f"epoch {ep + 1:2d}/{args.epochs}  loss {total / len(xtr):.4f}  "
              f"clean test acc {acc * 100:.2f}%  ({time.time() - t0:.0f} s)", flush=True)

    np.savez(OUT, **params_to_numpy(net))
    print(f"saved {OUT}")


if __name__ == "__main__":
    main()
