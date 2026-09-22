#!/usr/bin/env python3
"""Render the Audioble app icon.

A pixel loop with signed-distance shapes rather than a drawing library, so the
icon can be regenerated on a runner with nothing installed. Used for both the
app icon in the asset catalog and the icon the SideStore source feed points at.

usage: make_icon.py <output.png> [size]
"""
import struct
import sys
import zlib

NAVY_TOP = (0x0D, 0x26, 0x3A)
NAVY_BOTTOM = (0x01, 0x0E, 0x19)
ORANGE = (0xFF, 0xA0, 0x00)
WHITE = (0xFF, 0xFF, 0xFF)


def coverage(distance):
    """Signed distance to alpha, with one pixel of antialiasing."""
    return min(max(0.5 - distance, 0.0), 1.0)


def blend(base, top, alpha):
    return tuple(round(b + (t - b) * alpha) for b, t in zip(base, top))


def rounded_rect(x, y, cx, cy, half_w, half_h, radius):
    dx = abs(x - cx) - (half_w - radius)
    dy = abs(y - cy) - (half_h - radius)
    outside = (max(dx, 0.0) ** 2 + max(dy, 0.0) ** 2) ** 0.5
    return outside + min(max(dx, dy), 0.0) - radius


def arc(x, y, cx, cy, radius, thickness):
    """A headphone band: the upper half of an annulus."""
    d = abs(((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 - radius) - thickness / 2
    if y > cy:
        # Square off the ends rather than letting the ring close.
        d = max(d, y - cy)
    return d


def triangle(x, y, cx, cy, size):
    """A play glyph pointing right, with softened corners."""
    px, py = x - cx, y - cy
    # Three half-planes of an equilateral-ish triangle, apex to the right.
    d = max(
        -px - size * 0.62,
        0.5 * px - 0.866 * py - size * 0.32,
        0.5 * px + 0.866 * py - size * 0.32,
    )
    return d - size * 0.06


def render(size):
    s = size / 1024.0
    cx = size / 2
    rows = []
    for py in range(size):
        y = py + 0.5
        t = y / size
        base = tuple(
            round(a + (b - a) * t) for a, b in zip(NAVY_TOP, NAVY_BOTTOM)
        )
        row = bytearray()
        for px in range(size):
            x = px + 0.5
            color = base
            # Headphone band.
            color = blend(color, ORANGE, coverage(
                arc(x, y, cx, 560 * s, 300 * s, 74 * s)))
            # Ear cups.
            for side in (-1, 1):
                color = blend(color, ORANGE, coverage(rounded_rect(
                    x, y, cx + side * 300 * s, 620 * s, 78 * s, 132 * s, 62 * s)))
            # Play glyph between them.
            color = blend(color, WHITE, coverage(
                triangle(x, y, cx + 30 * s, 566 * s, 150 * s)))
            row += bytes(color)
        rows.append(bytes(row))
    return rows


def write_png(path, size, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)
    print(f"wrote {path} ({size}x{size}, {len(png)} bytes)")


if __name__ == "__main__":
    out = sys.argv[1]
    dimension = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
    write_png(out, dimension, render(dimension))
