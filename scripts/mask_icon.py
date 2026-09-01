#!/usr/bin/env python3
"""Place a square PNG onto a transparent canvas as a macOS-style rounded-square
icon (stdlib only). Usage: mask_icon.py <content.png> <canvas_size> <out.png>
The content image must already be resized to ~82% of canvas_size (sips does that)."""
import math
import struct
import sys
import zlib
from pathlib import Path


def read_png(path):
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, w, h, depth, ctype, idat = 8, 0, 0, 0, 0, b""
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and ctype in (2, 6) and interlace == 0, \
                f"unsupported PNG (depth={depth} ctype={ctype} interlace={interlace})"
        elif tag == b"IDAT":
            idat += body
        pos += 12 + ln
    ch = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * ch
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 1:    # Sub
            for i in range(ch, stride):
                line[i] = (line[i] + line[i - ch]) & 0xFF
        elif f == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:  # Average
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:  # Paeth
            for i in range(stride):
                a = line[i - ch] if i >= ch else 0
                b, c = prev[i], (prev[i - ch] if i >= ch else 0)
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, ch, out


def chunk(tag, body):
    return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))


def write_png(path, size, px):
    raw = b"".join(b"\x00" + bytes(px[y]) for y in range(size))
    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b""))


src, size, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
w, h, ch, img = read_png(src)
c = size / 2.0
m = size * 0.09
half = c - m
r = size * 0.185
off = (size - w) / 2.0  # content is centered on the canvas

canvas = [bytearray(size * 4) for _ in range(size)]
for y in range(size):
    row = canvas[y]
    sy = min(max(int(y - off), 0), h - 1)
    for x in range(size):
        px_, py_ = x + 0.5 - c, y + 0.5 - c
        dx, dy = abs(px_) - (half - r), abs(py_) - (half - r)
        dist = math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - r
        a = max(0.0, min(1.0, 0.5 - dist))
        if a <= 0:
            continue
        sx = min(max(int(x - off), 0), w - 1)
        i = (sy * w + sx) * ch
        row[x * 4:x * 4 + 4] = bytes((img[i], img[i + 1], img[i + 2], int(a * 255)))

write_png(out, size, canvas)
print(f"{out} ({size}px)")
