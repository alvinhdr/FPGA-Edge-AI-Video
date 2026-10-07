# =============================================================================
# File   : bench_mnist.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Phase 7 on-board benchmark. Sends MNIST test images to the ARM program
#          sw/benchmark over the UART. The board classifies each image with the
#          hardware CNN (inject RAM) AND with the C model on the ARM. This script
#          compares the board results with the Python integer golden model and the
#          true labels, and prints/saves accuracy, bit-exactness and timing.
#
# Usage (close PuTTY first; the board must run sw/benchmark):
#   .venv\Scripts\python.exe scripts/bench_mnist.py --port COM17 --n 10000
# Output: ml/reports/hw_benchmark.json (summary), build/bench_mnist.csv (every image)
# Time: about 70 ms per image (the UART at 115200 baud is the bottleneck).
# =============================================================================
import argparse
import csv
import json
import os
import sys
import time

import numpy as np
import serial

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(ROOT, "ml"))
import golden_int                      # noqa: E402
from data_utils import load_mnist      # noqa: E402


def read_result(ser, timeout=5.0):
    """Read lines until one starts with 'R '. Other lines (BENCH READY) are returned too."""
    end = time.time() + timeout
    others = []
    while time.time() < end:
        line = ser.readline().decode("ascii", errors="replace").strip()
        if not line:
            continue
        if line.startswith("R "):
            return line, others
        others.append(line)
    return None, others


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--n", type=int, default=10000)
    ap.add_argument("--baud", type=int, default=115200)
    args = ap.parse_args()

    _, _, xte, yte = load_mnist()
    n = min(args.n, len(xte))
    q = golden_int.load_params()
    gold = golden_int.infer_batched(xte[:n], q)

    ser = serial.Serial(args.port, args.baud, timeout=0.5)
    ser.reset_input_buffer()
    # Ask the board for its header: timer frequency and whether it was compiled optimized.
    ser.write(b"H")
    _, header = read_result(ser, timeout=2.0)
    freq = None
    optimized = None
    for o in header:
        print(o)
        if "freq=" in o:
            freq = int(o.split("freq=")[1].split()[0])
            optimized = int(o.split("optimized=")[1].split()[0])
    if freq is None:
        sys.exit("ERROR: no 'BENCH READY' answer. Is sw/benchmark running? Is PuTTY closed?")
    rows = []
    t_start = time.time()
    for i in range(n):
        ser.write(b"I" + bytes(xte[i].astype(np.uint8).reshape(-1)))
        line, others = read_result(ser)
        for o in others:
            print(o)
        if line is None:
            sys.exit(f"ERROR: no answer for image {i}. Is sw/benchmark running? Is PuTTY closed?")
        f = line.split()
        hw_d, hw_c, sw_d, sw_c, match, cyc, hw_t, sw_t = (int(v) for v in f[1:9])
        acc = [int(v) for v in f[9:19]]
        rows.append((i, int(yte[i]), hw_d, hw_c, sw_d, sw_c, match, cyc, hw_t, sw_t, acc))
        if (i + 1) % 250 == 0:
            el = time.time() - t_start
            print(f"{i + 1}/{n} images, {el:.0f} s elapsed, ~{el / (i + 1) * (n - i - 1):.0f} s left", flush=True)

    hw_d = np.array([r[2] for r in rows]); hw_c = np.array([r[3] for r in rows])
    sw_d = np.array([r[4] for r in rows]); sw_c = np.array([r[5] for r in rows])
    cyc = np.array([r[7] for r in rows]); hw_t = np.array([r[8] for r in rows]); sw_t = np.array([r[9] for r in rows])
    acc = np.array([r[10] for r in rows])
    labels = yte[:n]

    def us(t):
        return t / freq * 1e6                                        # ticks -> microseconds

    summary = {
        "images": n,
        "hw_accuracy_percent": float((hw_d == labels).mean() * 100),
        "hw_correct": int((hw_d == labels).sum()),
        "golden_accuracy_percent": float((gold["digit"] == labels).mean() * 100),
        "hw_vs_golden_accumulators_exact": int((acc == gold["acc"]).all(axis=1).sum()),
        "hw_vs_golden_digit_conf_exact": int(((hw_d == gold["digit"]) & (hw_c == gold["conf"])).sum()),
        "arm_c_vs_golden_digit_conf_exact": int(((sw_d == gold["digit"]) & (sw_c == gold["conf"])).sum()),
        "arm_c_vs_hw_accumulators_exact": int(sum(r[6] for r in rows)),
        "cnn_cycles_min": int(cyc.min()), "cnn_cycles_max": int(cyc.max()),
        "cnn_us_at_100mhz": float(cyc.mean() / 100.0),
        "arm_timer_hz": freq,
        "arm_c_compiled_optimized": optimized,
        "arm_c_us_mean": float(us(sw_t).mean()), "arm_c_us_min": float(us(sw_t).min()),
        "arm_c_us_max": float(us(sw_t).max()),
        "arm_driving_hw_us_mean": float(us(hw_t).mean()),
        "speedup_cnn_only": float(us(sw_t).mean() / (cyc.mean() / 100.0)),
        "speedup_arm_driven": float(us(sw_t).mean() / us(hw_t).mean()),
    }
    print(json.dumps(summary, indent=2))
    os.makedirs(os.path.join(ROOT, "ml", "reports"), exist_ok=True)
    with open(os.path.join(ROOT, "ml", "reports", "hw_benchmark.json"), "w") as fh:
        json.dump(summary, fh, indent=2)
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    with open(os.path.join(ROOT, "build", "bench_mnist.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["i", "label", "hw_digit", "hw_conf", "sw_digit", "sw_conf", "arm_acc_match", "cycles",
                    "hw_ticks", "sw_ticks"] + [f"acc{k}" for k in range(10)])
        for r in rows:
            w.writerow(list(r[:10]) + r[10])


if __name__ == "__main__":
    main()
