#!/usr/bin/env python3
"""Flatten BambuStudio system profiles into standalone JSON files.

The profiles in resources/profiles/<vendor>/ use "inherits" chains and
"include" templates. The BambuStudio CLI (--load-settings / --load-filaments)
and our iPad core expect fully resolved JSON. This tool resolves both.

Usage:
  flatten_profile.py --vendor-dir resources/profiles/BBL \
      --machine "Bambu Lab P1S 0.4 nozzle" \
      --process "0.20mm Standard @BBL X1C" \
      --filament "Bambu PLA Basic @BBL X1C" \
      --out ios/profiles/p1s

  flatten_profile.py --vendor-dir resources/profiles/BBL \
      --list-compatible "Bambu Lab P1S 0.4 nozzle"
"""
import argparse
import json
import os
import sys

# Keys that describe the preset itself and must not be copied from parents.
META_KEYS = {"inherits", "include", "instantiation", "setting_id", "base_id"}


def load_index(vendor_dir):
    index = {}
    for root, _dirs, files in os.walk(vendor_dir):
        for f in files:
            if not f.endswith(".json"):
                continue
            path = os.path.join(root, f)
            try:
                with open(path, encoding="utf-8") as fh:
                    data = json.load(fh)
            except (json.JSONDecodeError, UnicodeDecodeError) as e:
                print(f"warning: skip {path}: {e}", file=sys.stderr)
                continue
            name = data.get("name") if isinstance(data, dict) else None
            if name:
                if name in index:
                    print(f"warning: duplicate profile name '{name}'", file=sys.stderr)
                index[name] = (path, data)
    return index


def parse_list(value):
    """'include' may be a JSON list or a string holding a Python-style list."""
    if isinstance(value, list):
        return value
    if isinstance(value, str):
        s = value.strip()
        if s.startswith("["):
            try:
                return json.loads(s.replace("'", '"'))
            except json.JSONDecodeError:
                pass
        return [s] if s else []
    return []


def resolve(name, index, stack=()):
    if name in stack:
        raise ValueError(f"inheritance cycle: {' -> '.join(stack + (name,))}")
    if name not in index:
        raise KeyError(f"profile not found: '{name}'")
    _path, data = index[name]
    flat = {}
    parent = data.get("inherits")
    if parent:
        flat.update(resolve(parent, index, stack + (name,)))
    for inc in parse_list(data.get("include", [])):
        inc_flat = resolve(inc, index, stack + (name,))
        flat.update({k: v for k, v in inc_flat.items() if k not in ("name", "type", "from")})
    flat.update({k: v for k, v in data.items() if k not in META_KEYS})
    return flat


def finalize(flat, name, kind):
    flat = dict(flat)
    flat["name"] = name
    flat["type"] = kind
    flat["from"] = "system"
    return flat


def list_compatible(index, machine):
    out = {"process": [], "filament": []}
    for name, (_p, data) in index.items():
        kind = data.get("type")
        if kind not in out or str(data.get("instantiation", "true")).lower() != "true":
            continue
        try:
            flat = resolve(name, index)
        except (KeyError, ValueError):
            continue
        if machine in flat.get("compatible_printers", []):
            out[kind].append(name)
    return {k: sorted(v) for k, v in out.items()}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vendor-dir", required=True)
    ap.add_argument("--machine")
    ap.add_argument("--process")
    ap.add_argument("--filament", action="append", default=[])
    ap.add_argument("--out")
    ap.add_argument("--list-compatible", metavar="MACHINE")
    args = ap.parse_args()

    index = load_index(args.vendor_dir)

    if args.list_compatible:
        print(json.dumps(list_compatible(index, args.list_compatible), indent=2, ensure_ascii=False))
        return 0

    if not (args.machine and args.process and args.filament and args.out):
        ap.error("--machine, --process, --filament and --out are required unless --list-compatible is used")

    os.makedirs(args.out, exist_ok=True)
    jobs = [("machine", args.machine, "machine.json"), ("process", args.process, "process.json")]
    jobs += [("filament", f, f"filament_{i}.json") for i, f in enumerate(args.filament)]
    for kind, name, fname in jobs:
        flat = finalize(resolve(name, index), name, kind)
        if kind in ("process", "filament") and args.machine not in flat.get("compatible_printers", [args.machine]):
            print(f"warning: '{name}' does not list '{args.machine}' in compatible_printers", file=sys.stderr)
        dest = os.path.join(args.out, fname)
        with open(dest, "w", encoding="utf-8") as fh:
            json.dump(flat, fh, indent=4, ensure_ascii=False)
        print(f"{kind:8s} {name} -> {dest} ({len(flat)} keys)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
