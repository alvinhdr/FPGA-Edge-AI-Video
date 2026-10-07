# =============================================================================
# File   : download_mnist.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Download the MNIST dataset (60,000 training + 10,000 test images of
#          handwritten digits, 28x28 grayscale) into ml/data/ (git-ignored).
#
# Usage (from the repo root):
#   .venv\Scripts\python.exe ml/download_mnist.py
# =============================================================================
import os

from torchvision import datasets

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")

train = datasets.MNIST(DATA_DIR, train=True, download=True)
test = datasets.MNIST(DATA_DIR, train=False, download=True)

print(f"MNIST ready in {DATA_DIR}: {len(train)} training images, {len(test)} test images")
