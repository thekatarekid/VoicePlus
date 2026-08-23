#!/usr/bin/env python3
"""Generate AppIcon.icns: a rounded-square gradient tile with a white microphone pill.
Pure Python (no Pillow) -> writes a 1024x1024 PNG, then sips/iconutil build the .icns.
Usage: make_icon.py <out.icns>
"""
import math, os, struct, subprocess, sys, tempfile, zlib

N = 1024

def lerp(a, b, t): return a + (b - a) * t

def sdf_round_rect(px, py, cx, cy, hw, hh, r):
    dx = abs(px - cx) - (hw - r); dy = abs(py - cy) - (hh - r)
    ox, oy = max(dx, 0), max(dy, 0)
    return math.hypot(ox, oy) + min(max(dx, dy), 0) - r

def coverage(d, aa=1.5):  # 1 inside, 0 outside, smooth edge
    return min(1.0, max(0.0, 0.5 - d / aa))

def render():
    rows = []
    cx = cy = N / 2
    for y in range(N):
        row = bytearray()
        for x in range(N):
            px, py = x + 0.5, y + 0.5
            # background: macOS-style rounded square, ~ 80% of canvas, violet->teal gradient
            d_bg = sdf_round_rect(px, py, cx, cy, N * 0.41, N * 0.41, N * 0.19)
            a_bg = coverage(d_bg)
            t = (px + py) / (2 * N)
            r, g, b = lerp(96, 34, t), lerp(72, 197, t), lerp(255, 176, t)
            # mic capsule
            d_cap = sdf_round_rect(px, py, cx, cy - N * 0.08, N * 0.085, N * 0.19, N * 0.085)
            a_cap = coverage(d_cap)
            # mic cradle: arc (ring segment) below the capsule
            rad = math.hypot(px - cx, py - (cy - N * 0.02))
            ring = abs(rad - N * 0.165) - N * 0.028
            lower_half = (py - (cy - N * 0.02)) >= -N * 0.03  # cradle = bottom half ring
            a_ring = coverage(ring) if lower_half else 0.0
            # stem + base
            a_stem = coverage(sdf_round_rect(px, py, cx, cy + N * 0.215, N * 0.028, N * 0.07, N * 0.02))
            a_base = coverage(sdf_round_rect(px, py, cx, cy + N * 0.29, N * 0.11, N * 0.028, N * 0.028))
            a_fg = max(a_cap, a_ring, a_stem, a_base)
            # subtle shadow of foreground
            a_sh = max(coverage(d_cap - 6), coverage(ring - 6) if lower_half else 0.0) * 0.25
            r = lerp(r, 20, a_sh); g = lerp(g, 20, a_sh); b = lerp(b, 40, a_sh)
            r = lerp(r, 255, a_fg); g = lerp(g, 255, a_fg); b = lerp(b, 255, a_fg)
            a = a_bg
            row += bytes((int(r), int(g), int(b), int(a * 255)))
        rows.append(b"\x00" + bytes(row))
    raw = b"".join(rows)
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    return png

def main():
    out = sys.argv[1]
    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, "AppIcon.iconset"); os.makedirs(iconset)
    master = os.path.join(tmp, "icon_1024.png")
    with open(master, "wb") as f: f.write(render())
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            subprocess.run(["sips", "-z", str(px), str(px), master, "--out", os.path.join(iconset, name)],
                           check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    print(f"icon: {out}")

if __name__ == "__main__":
    main()
