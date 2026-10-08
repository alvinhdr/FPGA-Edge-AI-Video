# =============================================================================
# File   : make_diagram.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Draw docs/images/architecture.png in a hand-drawn pen style: slightly wobbly
#          lines, retraced boxes, handwriting font, margin notes. Black ink on white.
#          (A PNG, so it looks the same everywhere; an SVG would depend on the viewer's fonts.)
#
# Usage  : .venv\Scripts\python.exe scripts/make_diagram.py
# Needs  : Pillow, and the Windows font "Ink Free" (C:\Windows\Fonts\Inkfree.ttf)
# =============================================================================
import math
import os
import random

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.join(ROOT, "docs", "images", "architecture.png")
FONT = r"C:\Windows\Fonts\Inkfree.ttf"

W, H = 900, 540          # logical size
S = 4                    # drawing scale (supersampling); final image is W*2 x H*2
INK = (28, 28, 34, 255)
random.seed(7)           # same drawing every run

img = Image.new("RGBA", (W * S, H * S), (255, 255, 255, 255))
d = ImageDraw.Draw(img)


def font(size):
    return ImageFont.truetype(FONT, int(size * S))


def wobble_path(pts, amp=1.3, step=22):
    """Subdivide a polyline and push the points sideways a little, like a hand-drawn line."""
    out = []
    for (x0, y0), (x1, y1) in zip(pts[:-1], pts[1:]):
        length = math.hypot(x1 - x0, y1 - y0)
        n = max(2, int(length / step))
        nx, ny = (-(y1 - y0) / (length or 1), (x1 - x0) / (length or 1))
        drift = random.uniform(-amp, amp)
        for i in range(n):
            t = i / n
            drift += random.uniform(-amp, amp) * 0.55
            drift = max(-2.2 * amp, min(2.2 * amp, drift))
            out.append((x0 + (x1 - x0) * t + nx * drift, y0 + (y1 - y0) * t + ny * drift))
    out.append(pts[-1])
    return out


def stroke(pts, width=1.7, amp=1.3, retrace=True):
    for k in range(2 if retrace else 1):
        path = wobble_path(pts, amp=amp * (1 if k == 0 else 0.8))
        d.line([(x * S, y * S) for x, y in path], fill=INK, width=int(width * S * (1 if k == 0 else 0.7)), joint="curve")


def rrect_points(x, y, w, h, r):
    """Corner points of a rounded rectangle as a closed path (arcs as short segments)."""
    pts = []
    for cx, cy, a0 in ((x + w - r, y + r, -90), (x + w - r, y + h - r, 0), (x + r, y + h - r, 90), (x + r, y + r, 180)):
        for i in range(0, 91, 18):
            a = math.radians(a0 + i)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    pts.append(pts[0])
    return pts


def box(x, y, w, h, r=10, width=1.8, dashed=False):
    pts = rrect_points(x, y, w, h, r)
    if dashed:
        # walk along the outline: draw 11 px, skip 7 px; each dash is a short wobbly stroke
        dash, gap = 11.0, 7.0
        pos, drawing = 0.0, True
        for (x0, y0), (x1, y1) in zip(pts[:-1], pts[1:]):
            seg = math.hypot(x1 - x0, y1 - y0)
            if seg == 0:
                continue
            done = 0.0
            while done < seg:
                limit = dash if drawing else gap
                take = min(limit - pos, seg - done)
                a = (x0 + (x1 - x0) * done / seg, y0 + (y1 - y0) * done / seg)
                b = (x0 + (x1 - x0) * (done + take) / seg, y0 + (y1 - y0) * (done + take) / seg)
                if drawing:
                    stroke([a, b], width=width * 0.8, amp=0.5, retrace=False)
                done += take
                pos += take
                if pos >= limit - 1e-9:
                    drawing, pos = (not drawing), 0.0
    else:
        stroke(pts, width=width, amp=1.0)
        # pen overshoot at the first corner, like a box closed by hand
        stroke([(x + r + 3, y + 1.2), (x + r + 10, y - 0.8)], width=width * 0.8, amp=0.3, retrace=False)


def arrow(pts, width=1.8, head=11):
    stroke(pts, width=width, amp=1.1)
    (x0, y0), (x1, y1) = pts[-2], pts[-1]
    a = math.atan2(y1 - y0, x1 - x0)
    for sgn in (-1, 1):
        ang = a + math.pi + sgn * math.radians(26 + random.uniform(-4, 4))
        ln = head + random.uniform(-1.2, 1.2)
        stroke([(x1, y1), (x1 + ln * math.cos(ang), y1 + ln * math.sin(ang))], width=width, amp=0.25, retrace=False)


def text(x, y, s, size=15, anchor="mm", bold=False):
    f = font(size)
    lines = s.split("\n")
    lh = size * 1.12
    y0 = y - (len(lines) - 1) * lh / 2 if anchor == "mm" else y
    for i, line in enumerate(lines):
        d.text((x * S, (y0 + i * lh) * S), line, font=f, fill=INK, anchor=anchor if anchor != "mm" else "mm")
        if bold:   # fake a heavier pen by drawing the line a second time, shifted a little
            d.text((x * S + 0.9 * S, (y0 + i * lh) * S), line, font=f, fill=INK, anchor=anchor if anchor != "mm" else "mm")


# ------------------------------------------------------------------ video side (top)
box(258, 30, 340, 218, r=14, dashed=True)
text(462, 50, "video side: 74.25 MHz", size=13, anchor="lm")

box(10, 74, 104, 58)
text(62, 103, "Laptop\nHDMI 720p60", size=14, bold=True)
box(140, 74, 100, 58)
text(190, 103, "HDMI in\n(Digilent IP)", size=14, bold=True)
box(272, 68, 170, 70)
text(357, 103, "Overlay\ngreen box, digit,\nconfidence bar", size=14, bold=True)
box(486, 74, 100, 58)
text(536, 103, "HDMI out\n(Digilent IP)", size=14, bold=True)
box(680, 74, 100, 58)
text(730, 103, "TV", size=16, bold=True)

arrow([(114, 103), (138, 103)])
arrow([(240, 103), (270, 103)])
arrow([(442, 103), (484, 103)])
arrow([(586, 103), (678, 103)])

# ROI capture and buffer
box(272, 158, 205, 78)
text(374, 197, "ROI capture (224x224 box)\ngray, invert, 8x8 average\nthen 28 x 28 pixels", size=13.5, bold=False)
box(506, 158, 82, 78)
text(547, 197, "ROI\nbuffer\n2 banks", size=13.5)
arrow([(190, 132), (190, 197), (270, 197)])
text(205, 168, "same\npixels", size=12.5, anchor="lm")
arrow([(477, 197), (504, 197)])

# ------------------------------------------------------------------ network side (bottom)
box(258, 296, 632, 200, r=14, dashed=True)
text(270, 312, "network side: 100 MHz", size=13, anchor="lm")

box(276, 338, 366, 126)
text(459, 358, "CNN accelerator (hand-written SystemVerilog)", size=14, bold=True)
# the layers as small boxes
for i, (lx, label) in enumerate(((288, "conv 3x3\n8 maps\n+ pool"), (368, "conv 3x3\n16 maps\n+ pool"), (448, "fully\nconnected\n400 to 10"), (528, "pick\nbiggest\n= digit"))):
    box(lx, 376, 72, 52, r=7, width=1.4)
    text(lx + 36, 402, label, size=11.5)
    if i < 3:
        arrow([(lx + 72, 402), (lx + 80, 402)], width=1.3, head=6)
text(459, 450, "8 multiply-accumulate units, int8 numbers: 240 microseconds", size=12.5)

box(676, 338, 200, 126)
text(776, 366, "ARM CPU + registers", size=14, bold=True)
text(776, 410, "set options, run tests,\nread the answer,\nprint over UART", size=12.5)
arrow([(642, 401), (676, 401)], width=1.4, head=8)
arrow([(676, 411), (642, 411)], width=1.4, head=8)

# ------------------------------------------------------------------ crossing arrows
arrow([(547, 236), (547, 337)])
text(536, 266,"image crosses to the\n100 MHz side (synchronized)", size=12, anchor="rm")

# answer returns to the overlay: up on the right, along the top, down into the overlay
arrow([(626, 338), (626, 22), (357, 22), (357, 66)])
text(492, 9,"answer: digit + confidence, drawn on the next frame", size=12.5)

# ------------------------------------------------------------------ margin notes
text(682, 150, "no frame buffer:\npixel leaves 94 ns\nafter it came in,\n60 frames/s", size=12.5, anchor="lm")
text(10, 526, "Board: Digilent Zybo Z7-10 (FPGA + ARM).  Every clock crossing is synchronized, see docs/CDC.md", size=12, anchor="lm")

final = img.convert("RGB").resize((W * 2, H * 2), Image.LANCZOS)
final.save(OUT, optimize=True)
print("saved", OUT, final.size)
