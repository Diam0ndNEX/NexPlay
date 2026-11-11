#!/usr/bin/env python3
"""Draws the NexPlay app icon (1024x1024 PNG) with the standard library only.

A deep-space violet background with a soft nebula glow and stars, and a glossy rounded "play" triangle whose
inner corner is cut by a small four-button cluster: NexPlay plays games. Shapes are signed distance fields,
so the edges are anti-aliased without any image library.
"""
import math
import struct
import sys
import zlib

S = 1024


def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x


def mix(c1, c2, t):
    return tuple(c1[i] + (c2[i] - c1[i]) * t for i in range(3))


def smooth(edge, d):
    """Coverage from a signed distance (negative inside), about one pixel wide."""
    return clamp(0.5 - d / edge)


# Rounded triangle pointing right, slightly left of center so it looks optically centred.
CX, CY = 478, 512
R_TRI = 300
TRI = [
    (CX + R_TRI, CY),
    (CX - R_TRI * 0.5, CY - R_TRI * 0.866),
    (CX - R_TRI * 0.5, CY + R_TRI * 0.866),
]
CORNER = 70  # rounding radius


def sd_triangle(px, py):
    # Inigo Quilez's exact triangle distance.
    (x0, y0), (x1, y1), (x2, y2) = TRI
    e0 = (x1 - x0, y1 - y0)
    e1 = (x2 - x1, y2 - y1)
    e2 = (x0 - x2, y0 - y2)
    v0 = (px - x0, py - y0)
    v1 = (px - x1, py - y1)
    v2 = (px - x2, py - y2)

    def proj(v, e):
        t = clamp((v[0] * e[0] + v[1] * e[1]) / (e[0] * e[0] + e[1] * e[1]))
        return (v[0] - e[0] * t, v[1] - e[1] * t)

    pq0, pq1, pq2 = proj(v0, e0), proj(v1, e1), proj(v2, e2)
    s = 1 if e0[0] * e2[1] - e0[1] * e2[0] > 0 else -1
    d0 = (pq0[0] ** 2 + pq0[1] ** 2, s * (v0[0] * e0[1] - v0[1] * e0[0]))
    d1 = (pq1[0] ** 2 + pq1[1] ** 2, s * (v1[0] * e1[1] - v1[1] * e1[0]))
    d2 = (pq2[0] ** 2 + pq2[1] ** 2, s * (v2[0] * e2[1] - v2[1] * e2[0]))
    dist = min(d0[0], d1[0], d2[0])
    sign = min(d0[1], d1[1], d2[1])
    return -math.sqrt(dist) * (1 if sign > 0 else -1)


# Four "face buttons" in the hollow of the triangle.
BTN_R = 30
BTN_GAP = 54
BCX, BCY = CX - 10, CY
BUTTONS = [
    ((BCX, BCY - BTN_GAP), (255, 120, 150)),
    ((BCX + BTN_GAP, BCY), (120, 220, 255)),
    ((BCX, BCY + BTN_GAP), (140, 240, 170)),
    ((BCX - BTN_GAP, BCY), (255, 214, 110)),
]

BG_TOP = (30, 14, 66)
BG_BOTTOM = (10, 8, 30)
GLOW = (150, 90, 255)
GLOW2 = (255, 120, 90)
TRI_TOP = (255, 255, 255)
TRI_BOTTOM = (200, 176, 255)
STARS = [(150, 170, 3), (880, 140, 2.5), (820, 860, 3), (190, 840, 2), (930, 520, 2), (110, 470, 2.5),
         (330, 110, 2), (700, 940, 2), (620, 90, 1.8), (60, 640, 1.6), (960, 760, 1.8)]

rows = []
for y in range(S):
    row = bytearray(3 * S)
    for x in range(S):
        # Background: vertical gradient, two nebula glows, faint vignette.
        col = mix(BG_TOP, BG_BOTTOM, y / (S - 1))
        g1 = math.exp(-(((x - 300) ** 2 + (y - 300) ** 2) / (2 * 260.0 ** 2)))
        g2 = math.exp(-(((x - 780) ** 2 + (y - 780) ** 2) / (2 * 220.0 ** 2)))
        col = mix(col, GLOW, 0.55 * g1)
        col = mix(col, GLOW2, 0.28 * g2)
        for sx, sy, sr in STARS:
            d = math.hypot(x - sx, y - sy)
            if d < sr * 4:
                col = mix(col, (255, 255, 255), clamp(1.2 - d / sr) * 0.9)

        # Glow behind the triangle.
        d = sd_triangle(x, y) - CORNER
        if d < 120:
            halo = math.exp(-max(d, 0) / 38.0) * 0.45
            col = mix(col, GLOW, halo)

        # The triangle.
        cover = smooth(1.2, d)
        if cover > 0:
            t = clamp((y - (CY - R_TRI)) / (2 * R_TRI))
            fill = mix(TRI_TOP, TRI_BOTTOM, t)
            # Glossy top highlight.
            fill = mix(fill, (255, 255, 255), 0.25 * clamp(1 - t * 2.2))
            col = mix(col, fill, cover)

            # Buttons cut into the triangle: dark well, then a coloured dot.
            for (bx, by), bcol in BUTTONS:
                bd = math.hypot(x - bx, y - by)
                well = smooth(1.2, bd - (BTN_R + 7))
                if well > 0:
                    col = mix(col, (46, 26, 96), well * cover)
                    dot = smooth(1.2, bd - BTN_R)
                    if dot > 0:
                        shade = mix(bcol, (255, 255, 255), 0.35 * clamp(1 - (y - (by - BTN_R)) / (BTN_R * 1.2)))
                        col = mix(col, shade, dot * cover)

        i = 3 * x
        row[i] = int(clamp(col[0], 0, 255))
        row[i + 1] = int(clamp(col[1], 0, 255))
        row[i + 2] = int(clamp(col[2], 0, 255))
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
