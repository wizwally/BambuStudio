#!/usr/bin/env python3
"""Generate the binary STL test models used by ios/scripts/mac_03_test.sh.

  cube20.stl        20 mm cube (12 triangles): quick smoke test
  sphere_dense.stl  80 mm sphere (~200k triangles): time/memory stress test
Usage: make_test_models.py [output_dir]   (default: ios/test/models)
"""
import math
import os
import struct
import sys


def write_stl(path, tris):
    with open(path, "wb") as f:
        f.write(b"\0" * 80)
        f.write(struct.pack("<I", len(tris)))
        for a, b, c in tris:
            f.write(struct.pack("<3f", 0.0, 0.0, 0.0))  # normals are recomputed by the slicer
            for v in (a, b, c):
                f.write(struct.pack("<3f", *v))
            f.write(b"\0\0")


def box(sx, sy, sz):
    v = [(x, y, z) for x in (0, sx) for y in (0, sy) for z in (0, sz)]
    faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    tris = []
    for a, b, c, d in faces:
        tris += [(v[a], v[b], v[c]), (v[a], v[c], v[d])]
    return tris


def sphere(r, nu, nv):
    def p(i, j):
        th, ph = 2 * math.pi * i / nu, math.pi * j / nv
        return (r * math.sin(ph) * math.cos(th), r * math.sin(ph) * math.sin(th), r + r * math.cos(ph))

    tris = []
    for j in range(nv):
        for i in range(nu):
            a, b, c, d = p(i, j), p(i + 1, j), p(i + 1, j + 1), p(i, j + 1)
            if j > 0:
                tris.append((a, c, b))
            if j < nv - 1:
                tris.append((a, d, c))
    return tris


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "test", "models")
    os.makedirs(out, exist_ok=True)
    write_stl(os.path.join(out, "cube20.stl"), box(20, 20, 20))
    write_stl(os.path.join(out, "sphere_dense.stl"), sphere(40, 400, 250))
    print(f"modelli di test scritti in {os.path.abspath(out)}")


if __name__ == "__main__":
    main()
