# =============================================================================
# File   : make_diagram.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Make the architecture diagram in the standard diagrams.net (draw.io) look:
#            docs/images/architecture.drawio   editable file (open it at app.diagrams.net)
#            docs/images/architecture-bw.png   picture for the README, drawn from the SAME shapes
#          Both come from one list of boxes and arrows below, so they always match.
#
# Usage  : .venv\Scripts\python.exe scripts/make_diagram.py
# Needs  : Pillow, Windows fonts Arial (arial.ttf, arialbd.ttf)
# =============================================================================
import html
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT_PNG = os.path.join(ROOT, "docs", "images", "architecture-bw.png")
OUT_XML = os.path.join(ROOT, "docs", "images", "architecture.drawio")
FONT = r"C:\Windows\Fonts\arial.ttf"
FONT_B = r"C:\Windows\Fonts\arialbd.ttf"

W, H = 960, 500

# black and white: white boxes, black outlines (the two clock sides are marked by a divider line, see DIVIDER_Y)
BLUE = GREEN = YELLOW = GRAY = ("#ffffff", "#000000")
DIVIDER_Y = 298

# id: (x, y, w, h, [(line, bold), ...], colors)
NODES = {
    "laptop": (20, 80, 110, 70, [("Laptop", True), ("HDMI 720p60", False)], YELLOW),
    "hdmiin": (170, 80, 120, 70, [("HDMI in", True), ("(Digilent IP)", False)], BLUE),
    "overlay": (330, 80, 190, 70, [("Overlay", True), ("green box, digit,", False), ("confidence bar", False)], BLUE),
    "hdmiout": (560, 80, 120, 70, [("HDMI out", True), ("(Digilent IP)", False)], BLUE),
    "tv": (740, 80, 110, 70, [("TV", True), ("picture + answer", False)], YELLOW),
    "roi": (330, 200, 190, 80, [("ROI capture", True), ("224x224 box: gray, invert,", False), ("8x8 average -> 28x28", False)], BLUE),
    "buf": (560, 200, 90, 80, [("ROI buffer", True), ("2 banks", False)], BLUE),
    "cnn": (330, 360, 380, 100, [("CNN accelerator (hand-written SystemVerilog)", True),
                                 ("conv 3x3 (8) + pool, conv 3x3 (16) + pool", False),
                                 ("fully connected 400 -> 10, pick the biggest", False),
                                 ("8 multiply-accumulate units: 240 microseconds", False)], GREEN),
    "arm": (760, 360, 160, 100, [("ARM CPU + registers", True), ("settings, tests,", False), ("UART text output", False)], GRAY),
}

# edges: id, source, target, exit (x, y), entry (x, y), waypoints, both_ends
EDGES = [
    ("e1", "laptop", "hdmiin", (1, 0.5), (0, 0.5), [], False),
    ("e2", "hdmiin", "overlay", (1, 0.5), (0, 0.5), [], False),
    ("e3", "overlay", "hdmiout", (1, 0.5), (0, 0.5), [], False),
    ("e4", "hdmiout", "tv", (1, 0.5), (0, 0.5), [], False),
    ("e5", "hdmiin", "roi", (0.5, 1), (0, 0.5), [(230, 240)], False),
    ("e6", "roi", "buf", (1, 0.5), (0, 0.5), [], False),
    ("e7", "buf", "cnn", (0.5, 1), (0.724, 0), [], False),
    ("e8", "cnn", "arm", (1, 0.5), (0, 0.5), [], True),
    ("e9", "cnn", "overlay", (0.987, 0), (0.5, 0), [(705, 50), (425, 50)], False),
]

# free text: id, x, y, text lines, anchor ("l" left, "c" centre, "r" right of x)
LABELS = [
    ("t1", 240, 214, ["same pixels"], "l"),
    ("t2", 595, 320, ["crosses to the 100 MHz side", "(synchronized)"], "r"),
    ("t3", 565, 34, ["answer (digit + confidence) is drawn on the next frame"], "c"),
    ("t4", 425, 176, ["no frame buffer: a pixel leaves 94 ns after it came in, 60 frames/s"], "c"),
    ("t5", 20, 482, ["Digilent Zybo Z7-10 (FPGA + ARM). Every clock crossing is synchronized, see docs/CDC.md"], "l"),
    ("t6", 20, DIVIDER_Y - 11, ["video side: 74.25 MHz"], "l"),
    ("t7", 20, DIVIDER_Y + 12, ["network side: 100 MHz"], "l"),
]

LEGEND = []          # no colour legend in the black-and-white version
LEG_X = ()
LEG_Y = 0


def edge_points(src, dst, ex, en, via):
    sx, sy, sw, sh = NODES[src][:4]
    dx, dy, dw, dh = NODES[dst][:4]
    p0 = (sx + sw * ex[0], sy + sh * ex[1])
    p1 = (dx + dw * en[0], dy + dh * en[1])
    return [p0, *via, p1]


# ----------------------------------------------------------------------------- PNG
def make_png():
    S = 3
    img = Image.new("RGB", (W * S, H * S), "white")
    d = ImageDraw.Draw(img)

    def f(size, bold=False):
        return ImageFont.truetype(FONT_B if bold else FONT, int(size * S))

    def put(x, y, s, size, bold, anchor):
        d.text((x * S, y * S), s, font=f(size, bold), fill="black", anchor=anchor)

    for _, (x, y, w, h, lines, (fill, stroke)) in NODES.items():
        d.rounded_rectangle([x * S, y * S, (x + w) * S, (y + h) * S], radius=9 * S, fill=fill, outline=stroke, width=int(1.6 * S))
        lh = 16
        y0 = y + h / 2 - (len(lines) - 1) * lh / 2
        for i, (line, bold) in enumerate(lines):
            put(x + w / 2, y0 + i * lh, line, 12.5, bold, "mm")

    def arrowhead(p, q):
        import math
        a = math.atan2(q[1] - p[1], q[0] - p[0])
        L, Wd = 11, 5.5
        base = (q[0] - L * math.cos(a), q[1] - L * math.sin(a))
        pts = [q, (base[0] + Wd * math.sin(a), base[1] - Wd * math.cos(a)), (base[0] - Wd * math.sin(a), base[1] + Wd * math.cos(a))]
        d.polygon([(px * S, py * S) for px, py in pts], fill="black")
        return base

    d.line([(20 * S, DIVIDER_Y * S), ((W - 20) * S, DIVIDER_Y * S)], fill="black", width=int(1.6 * S))

    for _, src, dst, ex, en, via, both in EDGES:
        pts = edge_points(src, dst, ex, en, via)
        line = list(pts)
        line[-1] = arrowhead(pts[-2], pts[-1])
        if both:
            line[0] = arrowhead(pts[1], pts[0])
        d.line([(px * S, py * S) for px, py in line], fill="black", width=int(1.6 * S), joint="curve")

    for _, x, y, lines, anchor in LABELS:
        a = {"l": "lm", "c": "mm", "r": "rm"}[anchor]
        small = y > 470
        for i, line in enumerate(lines):
            put(x, y + i * 15 - (len(lines) - 1) * 7.5, line, 11 if not small else 10.5, False, a)

    for (fill, stroke), x, (_, label) in zip([c for c, _ in LEGEND], LEG_X, LEGEND):
        d.rounded_rectangle([x * S, LEG_Y * S, (x + 22) * S, (LEG_Y + 16) * S], radius=4 * S, fill=fill, outline=stroke, width=int(1.4 * S))
        put(x + 30, LEG_Y + 8, label, 11.5, False, "lm")

    img = img.resize((W * 2, H * 2), Image.LANCZOS)
    img.save(OUT_PNG, optimize=True)
    print("saved", OUT_PNG, img.size)


# ----------------------------------------------------------------------------- draw.io XML
def make_xml():
    cells = ['<mxCell id="0"/>', '<mxCell id="1" parent="0"/>']

    def label_html(lines):
        parts = [f"<b>{html.escape(t)}</b>" if bold else html.escape(t) for t, bold in lines]
        return html.escape("<br>".join(parts), quote=True)

    for nid, (x, y, w, h, lines, (fill, stroke)) in NODES.items():
        style = f"rounded=1;whiteSpace=wrap;html=1;arcSize=12;fillColor={fill};strokeColor={stroke};fontSize=12;"
        cells.append(f'<mxCell id="{nid}" value="{label_html(lines)}" style="{style}" vertex="1" parent="1">'
                     f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')

    for eid, src, dst, ex, en, via, both in EDGES:
        style = (f"edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;endArrow=classic;startArrow={'classic' if both else 'none'};"
                 f"exitX={ex[0]};exitY={ex[1]};entryX={en[0]};entryY={en[1]};strokeColor=#000000;")
        pts = "".join(f'<mxPoint x="{px}" y="{py}"/>' for px, py in via)
        arr = f'<Array as="points">{pts}</Array>' if via else ""
        cells.append(f'<mxCell id="{eid}" style="{style}" edge="1" parent="1" source="{src}" target="{dst}">'
                     f'<mxGeometry relative="1" as="geometry">{arr}</mxGeometry></mxCell>')

    cells.append('<mxCell id="divider" style="endArrow=none;html=1;strokeColor=#000000;strokeWidth=1.5;" edge="1" parent="1">'
                 f'<mxGeometry relative="1" as="geometry"><mxPoint x="20" y="{DIVIDER_Y}" as="sourcePoint"/>'
                 f'<mxPoint x="{W - 20}" y="{DIVIDER_Y}" as="targetPoint"/></mxGeometry></mxCell>')

    for tid, x, y, lines, anchor in LABELS:
        align = {"l": "left", "c": "center", "r": "right"}[anchor]
        w = 330
        x0 = {"l": x, "c": x - w / 2, "r": x - w}[anchor]
        h = 15 * len(lines) + 6
        txt = html.escape("<br>".join(html.escape(t) for t in lines), quote=True)
        cells.append(f'<mxCell id="{tid}" value="{txt}" style="text;html=1;align={align};verticalAlign=middle;fontSize=11;" vertex="1" parent="1">'
                     f'<mxGeometry x="{x0}" y="{y - h / 2}" width="{w}" height="{h}" as="geometry"/></mxCell>')

    for i, ((fill, stroke), x, (_, label)) in enumerate(zip([c for c, _ in LEGEND], LEG_X, LEGEND)):
        cells.append(f'<mxCell id="lg{i}" value="" style="rounded=1;whiteSpace=wrap;html=1;fillColor={fill};strokeColor={stroke};" vertex="1" parent="1">'
                     f'<mxGeometry x="{x}" y="{LEG_Y}" width="22" height="16" as="geometry"/></mxCell>')
        cells.append(f'<mxCell id="lt{i}" value="{html.escape(label)}" style="text;html=1;align=left;verticalAlign=middle;fontSize=11;" vertex="1" parent="1">'
                     f'<mxGeometry x="{x + 30}" y="{LEG_Y - 2}" width="180" height="20" as="geometry"/></mxCell>')

    xml = ('<mxfile host="app.diagrams.net"><diagram name="Architecture" id="arch">'
           f'<mxGraphModel dx="{W}" dy="{H}" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" '
           f'pageScale="1" pageWidth="{W}" pageHeight="{H}" math="0" shadow="0"><root>' + "".join(cells) + "</root></mxGraphModel></diagram></mxfile>")
    with open(OUT_XML, "w", encoding="utf-8") as fh:
        fh.write(xml)
    print("saved", OUT_XML)


if __name__ == "__main__":
    make_png()
    make_xml()
