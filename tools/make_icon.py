#!/usr/bin/env python3
"""Draws the NexPlay app icon as a 1024x1024 PNG using only the standard library."""
import math
import struct
import sys
import zlib

S = 1024
TOP, BOTTOM = (12, 22, 52), (0, 140, 170)
WHITE, AMBER = (255, 255, 255), (255, 184, 77)


def paint(row, a, b, color):
    a, b = max(0, int(a)), min(S, int(b))
    if b > a:
        row[3 * a:3 * b] = bytes(color) * (b - a)


rows = []
for y in range(S):
    t = y / (S - 1)
    base = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    row = bytearray(bytes(base) * S)

    if 270 <= y <= 754:
        k = (y - 270) / (754 - 270)
        paint(row, 290, 401, WHITE)                                       # left stem
        paint(row, 624, 735, WHITE)                                       # right stem
        paint(row, 290 + k * (624 - 290), 401 + k * (734 - 400), WHITE)   # diagonal

    if 810 <= y <= 852:
        dx = math.sqrt(max(0.0, 21 ** 2 - (y - 831) ** 2))
        paint(row, 311 - dx, 713 + dx + 1, AMBER)                         # rounded bar

    rows.append(b"\x00" + bytes(row))


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
    + chunk(b"IEND", b"")
)

with open(sys.argv[1], "wb") as f:
    f.write(png)
print("wrote", sys.argv[1])
