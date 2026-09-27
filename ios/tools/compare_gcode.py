#!/usr/bin/env python3
"""Compare two G-code files by content that matters for printing.

Reports layer count, total extrusion (E), move count and the header's estimated
time, then the first differing motion line after stripping comments.
Usage: compare_gcode.py reference.gcode candidate.gcode
"""
import re
import sys

E_RE = re.compile(r"\bE(-?\d*\.?\d+)")


def stats(path):
    layers = moves = 0
    extruded = 0.0
    relative_e = True
    motion = []
    est = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith("; CHANGE_LAYER") or line.startswith(";LAYER_CHANGE"):
                layers += 1
            if est is None and "total estimated time" in line.lower():
                est = line.lstrip("; ")
            code = line.split(";", 1)[0].strip()
            if not code:
                continue
            if code.startswith("M82"):
                relative_e = False
            elif code.startswith("M83"):
                relative_e = True
            if code.startswith(("G0", "G1", "G2", "G3")):
                moves += 1
                motion.append(code)
                m = E_RE.search(code)
                if m and relative_e:
                    v = float(m.group(1))
                    if v > 0:
                        extruded += v
    return {"layers": layers, "moves": moves, "extruded_mm": round(extruded, 1), "estimate": est, "motion": motion}


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    a, b = stats(sys.argv[1]), stats(sys.argv[2])
    print(f"{'':14s}{'riferimento':>18s}{'core':>18s}")
    for k in ("layers", "moves", "extruded_mm"):
        diff = "" if a[k] == b[k] else "  <-- diverso"
        print(f"{k:14s}{a[k]!s:>18s}{b[k]!s:>18s}{diff}")
    print(f"stima rif.:  {a['estimate']}")
    print(f"stima core:  {b['estimate']}")
    for i, (x, y) in enumerate(zip(a["motion"], b["motion"])):
        if x != y:
            print(f"prima differenza al movimento #{i}:\n  rif:  {x}\n  core: {y}")
            break
    else:
        if len(a["motion"]) == len(b["motion"]):
            print("movimenti identici")
    return 0


if __name__ == "__main__":
    sys.exit(main())
