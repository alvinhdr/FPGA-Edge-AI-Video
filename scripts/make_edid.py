#!/usr/bin/env python3
# =============================================================================
# File   : make_edid.py
# Project: Real-Time Edge AI Video Processor on FPGA
# Purpose: Make an EDID that offers ONLY 1280x720 @ 60 Hz (CEA VIC 4).
#
# Why: Digilent's dgl_720p_cea.data also lists 1080p60 and 1280x1024, so Windows
#      can pick 1080p (148.5 MHz). That is outside the -1 speed grade of the
#      Zybo Z7-10, and our ROI/overlay positions are made for 1280x720.
#      The EDID is only what the Zybo HDMI input tells the laptop. A monitor
#      connected directly to the laptop keeps its own EDID (not affected).
#
# Method: start from Digilent's file (same vendor ID, same 720p detailed timing),
#         remove every other mode, fix the checksums, and verify the result.
#
# Usage : python scripts/make_edid.py        (writes rtl/edid_720p_only.data)
# Format: 256 lines, one byte per line as 8 binary digits, CRLF (like Digilent).
# =============================================================================
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "third_party/vivado-library/ip/dvi2rgb/src/dgl_720p_cea.data"
DST = ROOT / "rtl/edid_720p_only.data"


def load(path):
    return bytearray(int(line, 2) for line in path.read_text().split() if line)


def fix_checksum(block):
    block[127] = (-sum(block[:127])) & 0xFF


def build():
    src = load(SRC)
    assert len(src) == 256
    b0 = bytearray(src[:128])
    b1 = bytearray(src[128:])

    # --- Block 0 ------------------------------------------------------------
    b0[0x0A] = 0x02                       # product code 2: Windows sees a NEW monitor (no cached 1080p)
    b0[0x23:0x26] = b"\x00\x00\x00"       # no established timings (640x480, 800x600, 1024x768, 1280x1024)
    # Descriptor 1 (0x36) = 1280x720@60 detailed timing: keep.
    assert b0[0x36:0x38] == bytes([0x01, 0x1D]), "descriptor 1 should be 74.25 MHz"
    b0[0x48:0x5A] = bytes([0, 0, 0, 0x10, 0]) + bytes(13)   # descriptor 2 (was 1080p) -> dummy
    # Descriptor 4 (0x6C) = monitor range limits: 50-60 Hz, 30-50 kHz, max 80 MHz.
    assert b0[0x6C:0x71] == bytes([0, 0, 0, 0xFD, 0])
    b0[0x71:0x76] = bytes([50, 60, 30, 50, 8])
    # Descriptor 3 (0x5A) = monitor name: "ZYBO 720P" + newline + spaces.
    name = b"ZYBO 720P\n" + b"   "
    assert len(name) == 13
    b0[0x5A:0x5F] = bytes([0, 0, 0, 0xFC, 0])
    b0[0x5F:0x6C] = name
    assert b0[0x7E] == 1                  # one extension block (CEA)
    fix_checksum(b0)

    # --- Block 1: CEA-861 extension -------------------------------------------
    dtd_720p = bytes(b1[0x09:0x09 + 18])  # the 720p detailed timing of Digilent's file
    assert dtd_720p[:2] == bytes([0x01, 0x1D])
    cea = bytearray(128)
    cea[0] = 0x02                         # CEA extension tag
    cea[1] = 0x03                         # revision 3
    cea[2] = 0x06                         # detailed timings start at byte 6
    cea[3] = 0x01                         # 1 native DTD, no audio, DVI-style (no HDMI VSDB, like Digilent)
    cea[4] = 0x41                         # video data block, length 1
    cea[5] = 0x84                         # VIC 4 = 1280x720p60, native
    cea[6:6 + 18] = dtd_720p
    fix_checksum(cea)
    return bytes(b0 + cea)


def decode_dtd(d):
    clk = (d[0] | d[1] << 8) * 10_000
    hact = d[2] | (d[4] & 0xF0) << 4
    hblk = d[3] | (d[4] & 0x0F) << 8
    vact = d[5] | (d[7] & 0xF0) << 4
    vblk = d[6] | (d[7] & 0x0F) << 8
    return clk, hact, hblk, vact, vblk


def verify(e):
    assert len(e) == 256
    assert e[:8] == bytes([0, 255, 255, 255, 255, 255, 255, 0]), "bad header"
    assert sum(e[:128]) % 256 == 0 and sum(e[128:]) % 256 == 0, "bad checksum"
    clk, ha, hb, va, vb = decode_dtd(e[0x36:0x48])
    assert (ha, va) == (1280, 720) and clk == 74_250_000, (clk, ha, va)
    assert (ha + hb) * (va + vb) == 1650 * 750
    assert e[0x48:0x4D] == bytes([0, 0, 0, 0x10, 0]), "descriptor 2 must be dummy"
    assert e[0x23:0x26] == b"\x00\x00\x00", "established timings must be empty"
    # No other detailed timing (pixel clock != 0) anywhere in either block.
    for off in (0x36, 0x48, 0x5A, 0x6C, 0x80 + 6, 0x80 + 24, 0x80 + 42):
        if off in (0x36, 0x80 + 6):
            continue
        assert e[off] == 0 and e[off + 1] == 0, f"extra timing at 0x{off:02x}"
    # Standard timings (0x26..0x35) must all be the unused code 01 01.
    assert all(e[0x26 + i] == (1 if i % 2 == 0 else 1) for i in range(16)), "standard timings"
    assert list(e[0x80 + 4:0x80 + 6]) == [0x41, 0x84], "CEA video block"
    assert decode_dtd(e[0x80 + 6:0x80 + 24]) == (clk, ha, hb, va, vb)
    return clk, ha, va


def main():
    e = build()
    clk, ha, va = verify(e)
    DST.write_bytes("".join(f"{b:08b}\r\n" for b in e).encode("ascii"))
    print(f"wrote {DST.relative_to(ROOT)}: {ha}x{va} @ {clk / 1e6:.2f} MHz only, 256 bytes, checksums OK")
    for i in range(0, 256, 16):
        print(f"{i:03x}", e[i:i + 16].hex(" "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
