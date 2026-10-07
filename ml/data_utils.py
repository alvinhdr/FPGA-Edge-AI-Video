# =============================================================================
# File   : data_utils.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: MNIST loading and the training augmentation (shift, scale, rotation,
#          stroke thickness, background/contrast). Augmentation also imitates the
#          "domain gap": the live camera/screen picture is not a clean MNIST digit.
# =============================================================================
import math
import os

import numpy as np
import torch
import torch.nn.functional as F
from torchvision import datasets

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")


def load_mnist():
    """Returns (x_train, y_train, x_test, y_test): x as uint8 [N, 28, 28], y as int64 [N]."""
    tr = datasets.MNIST(DATA_DIR, train=True, download=False)
    te = datasets.MNIST(DATA_DIR, train=False, download=False)
    return (tr.data.numpy(), tr.targets.numpy().astype(np.int64),
            te.data.numpy(), te.targets.numpy().astype(np.int64))


def to_float(x_u8):
    """uint8 [N, 28, 28] -> float32 [N, 1, 28, 28] in [0, 1] (the x/255 of docs/QUANTIZATION.md)."""
    return torch.from_numpy(x_u8).float().div(255.0).unsqueeze(1)


def augment(x, gen=None, max_shift_px=3.0, max_rot_deg=10.0, scale_range=(0.85, 1.15)):
    """Random geometric + stroke-thickness + background change. x: float [B, 1, 28, 28] in [0, 1]."""
    b = x.shape[0]
    rnd = lambda *shape: torch.rand(*shape, generator=gen)
    ang = (rnd(b) * 2 - 1) * math.radians(max_rot_deg)
    sc = scale_range[0] + rnd(b) * (scale_range[1] - scale_range[0])
    tx = (rnd(b) * 2 - 1) * max_shift_px * 2 / 28      # affine_grid units: 2 per image width
    ty = (rnd(b) * 2 - 1) * max_shift_px * 2 / 28
    theta = torch.zeros(b, 2, 3)
    theta[:, 0, 0] = torch.cos(ang) / sc
    theta[:, 0, 1] = -torch.sin(ang) / sc
    theta[:, 1, 0] = torch.sin(ang) / sc
    theta[:, 1, 1] = torch.cos(ang) / sc
    theta[:, 0, 2] = tx
    theta[:, 1, 2] = ty
    grid = F.affine_grid(theta, x.shape, align_corners=False)
    x = F.grid_sample(x, grid, mode="bilinear", padding_mode="zeros", align_corners=False)

    # Stroke thickness: 20 % thinner (erode), 30 % thicker (dilate), 50 % unchanged
    dil = F.max_pool2d(x, 3, 1, 1)
    ero = -F.max_pool2d(-x, 3, 1, 1)
    r = rnd(b, 1, 1, 1)
    x = torch.where(r < 0.2, ero, torch.where(r > 0.7, dil, x))

    # Lower contrast, gray background, a little noise (live picture is not pure black/white)
    contrast = 0.6 + 0.4 * rnd(b, 1, 1, 1)
    bg = 0.15 * rnd(b, 1, 1, 1) * (rnd(b, 1, 1, 1) < 0.5).float()
    noise = 0.02 * torch.randn(x.shape, generator=gen)
    return (x * contrast + bg + noise).clamp(0, 1)
