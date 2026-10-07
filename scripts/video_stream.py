# =============================================================================
# File   : video_stream.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Helpers for simulating the pixel pipeline with real pictures.
#   - 720p60 (CEA-861) video timing
#   - picture (numpy RGB array) <-> video stream file for the SV testbench
#   - Python reference model of rtl/pixel_pipeline.sv (must match bit-exactly)
#
# Stream file format (one line per pixel clock, 7 hex digits):
#   bit 26 = DE, bit 25 = HSYNC, bit 24 = VSYNC, bits 23:0 = pixel (Digilent R-B-G order)
# =============================================================================
import os

import numpy as np

# ---- 720p60 timing (CEA-861, positive sync polarity) --------------------------
H_ACTIVE, H_FP, H_SYNC, H_BP = 1280, 110, 40, 220      # total 1650
V_ACTIVE, V_FP, V_SYNC, V_BP = 720, 5, 5, 20            # total 750
H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP
V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP

DE_BIT, HS_BIT, VS_BIT = 1 << 26, 1 << 25, 1 << 24

# ---- Pipeline settings (must match rtl/pixel_pipeline.sv defaults) -----------
ROI_SIZE = 224
ROI_BORDER = 3
DIGIT_X, DIGIT_Y, DIGIT_SCALE = 784, 248, 16
AIV_X, AIV_Y, AIV_SCALE = 256, 248, 8      # AI view: 28x28 shown 8x = 224x224
GRID = 28
GREEN = (0, 255, 0)
LATENCY = 6

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
FONT_FILE = os.path.join(ROOT_DIR, "rtl", "font_digits_8x8.mem")


# ---- Pixel packing (Digilent bus order: [23:16]=R, [15:8]=B, [7:0]=G) ---------
def pack_rbg(img):
    """HxWx3 uint8 RGB array -> HxW uint32 bus words."""
    r, g, b = (img[..., i].astype(np.uint32) for i in range(3))
    return (r << 16) | (b << 8) | g


def unpack_rbg(words):
    """HxW bus words -> HxWx3 uint8 RGB array."""
    words = np.asarray(words, dtype=np.uint32)
    r = (words >> 16) & 0xFF
    b = (words >> 8) & 0xFF
    g = words & 0xFF
    return np.stack([r, g, b], axis=-1).astype(np.uint8)


# ---- Picture -> stream --------------------------------------------------------
def frame_words(img):
    """One full 720p frame (with blanking) as a flat uint32 array of stream words.
    Frame order: 720 active lines, then vertical blanking (front porch, sync, back porch).
    Each line: active pixels, then horizontal blanking (front porch, sync, back porch)."""
    assert img.shape == (V_ACTIVE, H_ACTIVE, 3), img.shape
    frame = np.zeros((V_TOTAL, H_TOTAL), dtype=np.uint32)
    frame[:V_ACTIVE, :H_ACTIVE] = pack_rbg(img) | DE_BIT
    frame[:, H_ACTIVE + H_FP:H_ACTIVE + H_FP + H_SYNC] |= HS_BIT
    frame[V_ACTIVE + V_FP:V_ACTIVE + V_FP + V_SYNC, :] |= VS_BIT
    return frame.reshape(-1)


def write_stream(path, words):
    with open(path, "w") as f:
        f.write("\n".join(f"{w:07x}" for w in words))
        f.write("\n")


def read_stream(path):
    """Read the testbench output. Lines with x/z (unknown, before the pipeline
    is filled) become -1."""
    out = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            try:
                out.append(int(s, 16))
            except ValueError:
                out.append(-1)
    return np.array(out, dtype=np.int64)


def stream_to_frames(words):
    """Collect the visible pixels (DE = 1) of each frame into pictures."""
    words = words[words >= 0]
    de = (words & DE_BIT) != 0
    pixels = (words[de] & 0xFFFFFF).astype(np.uint32)
    n = len(pixels) // (V_ACTIVE * H_ACTIVE)
    return [unpack_rbg(pixels[i * V_ACTIVE * H_ACTIVE:(i + 1) * V_ACTIVE * H_ACTIVE]
                       .reshape(V_ACTIVE, H_ACTIVE)) for i in range(n)]


# ---- Reference model of rtl/pixel_pipeline.sv -----------------------------------
def load_font(path=FONT_FILE):
    rows = []
    with open(path) as f:
        for line in f:
            s = line.split("//")[0].strip()
            if s:
                rows.append(int(s, 2))
    assert len(rows) == 80, len(rows)
    return np.array(rows, dtype=np.uint8).reshape(10, 8)


def rgb2gray(img):
    """Same integer formula as rtl/rgb2gray.sv: (77R + 150G + 29B) >> 8."""
    r, g, b = (img[..., i].astype(np.uint32) for i in range(3))
    return ((77 * r + 150 * g + 29 * b) >> 8).astype(np.uint8)


def preprocess_roi(img, roi_x0, roi_y0, invert, thresh_en, thresh):
    """docs/QUANTIZATION.md section 8: 224x224 ROI -> 28x28 uint8 CNN input."""
    g = rgb2gray(img[roi_y0:roi_y0 + ROI_SIZE, roi_x0:roi_x0 + ROI_SIZE]).astype(np.int64)
    if invert:
        g = 255 - g
    sums = g.reshape(GRID, 8, GRID, 8).sum(axis=(1, 3))
    avg = (sums + 32) >> 6
    if thresh_en:
        avg = np.where(avg < thresh, 0, avg)
    return avg.astype(np.uint8)


def reference_pipeline(img, gray_en, overlay_en, roi_x0, roi_y0, digit, ai_view=None):
    """ai_view: the 28x28 image shown in the AI view (= previous frame's capture),
    None means all zeros (the preview RAM starts at 0)."""
    out = img.copy()
    if gray_en:
        g = rgb2gray(img)
        out = np.stack([g, g, g], axis=-1)
    if overlay_en:
        ys, xs = np.mgrid[0:V_ACTIVE, 0:H_ACTIVE]
        in_outer = ((xs + ROI_BORDER >= roi_x0) & (xs < roi_x0 + ROI_SIZE + ROI_BORDER) &
                    (ys + ROI_BORDER >= roi_y0) & (ys < roi_y0 + ROI_SIZE + ROI_BORDER))
        in_roi = ((xs >= roi_x0) & (xs < roi_x0 + ROI_SIZE) &
                  (ys >= roi_y0) & (ys < roi_y0 + ROI_SIZE))
        out[in_outer & ~in_roi] = GREEN
        # AI view (drawn after the box, before the digit, like the RTL stage order)
        av = np.zeros((GRID, GRID), np.uint8) if ai_view is None else ai_view
        big = np.kron(av, np.ones((AIV_SCALE, AIV_SCALE), np.uint8))
        size = GRID * AIV_SCALE
        out[AIV_Y:AIV_Y + size, AIV_X:AIV_X + size] = big[..., None]
        if 0 <= digit <= 9:
            glyph = load_font()[digit]
            for row in range(8):
                for col in range(8):
                    if (glyph[row] >> (7 - col)) & 1:
                        y0 = DIGIT_Y + row * DIGIT_SCALE
                        x0 = DIGIT_X + col * DIGIT_SCALE
                        out[y0:y0 + DIGIT_SCALE, x0:x0 + DIGIT_SCALE] = GREEN
    return out
