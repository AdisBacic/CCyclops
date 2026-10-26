#!/usr/bin/env python3
"""Generate the Claude Workflows app icon (.iconset PNGs) — stdlib only.
Dark rounded square matching the dashboard palette, with a glowing phosphor dot."""
import math
import struct
import sys
import zlib
from pathlib import Path


def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))


def write_png(path, size, px):
    raw = b"".join(b"\x00" + bytes(row) for row in px)
    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b""))


def clamp(v, lo=0.0, hi=1.0):
    return max(lo, min(hi, v))


def draw(size):
    m = size * 0.09          # outer margin (macOS icon grid padding)
    r = size * 0.185         # corner radius
    c = size / 2.0
    half = c - m
    dot_r = size * 0.15
    border = max(size * 0.008, 0.75)
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            px, py = x + 0.5 - c, y + 0.5 - c
            # rounded-rect SDF
            dx, dy = abs(px) - (half - r), abs(py) - (half - r)
            dist = math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - r
            a = clamp(0.5 - dist)
            if a <= 0:
                row += b"\x00\x00\x00\x00"
                continue
            # panel fill with slight vertical gradient
            t = (y / size)
            cr, cg, cb = (16 - 5 * t), (23 - 7 * t), (17 - 4 * t)
            # hairline border
            edge = clamp(1.0 - abs(dist + border) / border)
            cr += (34 - cr) * edge * 0.9
            cg += (48 - cg) * edge * 0.9
            cb += (36 - cb) * edge * 0.9
            # glowing dot
            d = math.hypot(px, py)
            glow = math.exp(-(d / (size * 0.24)) ** 2) * 0.38
            core = clamp(0.5 - (d - dot_r))
            cr = cr + (127 - cr) * glow
            cg = cg + (217 - cg) * glow
            cb = cb + (122 - cb) * glow
            cr = cr + (127 - cr) * core
            cg = cg + (217 - cg) * core
            cb = cb + (122 - cb) * core
            row += bytes((int(clamp(cr, 0, 255)), int(clamp(cg, 0, 255)),
                          int(clamp(cb, 0, 255)), int(a * 255)))
        rows.append(row)
    return rows


out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
for name, s in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                ("icon_256x256", 256), ("icon_256x256@2x", 512),
                ("icon_512x512", 512), ("icon_512x512@2x", 1024)]:
    write_png(out / f"{name}.png", s, draw(s))
print(f"wrote {out}")
