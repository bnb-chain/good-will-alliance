#!/usr/bin/env python3
"""Convert mev-info/<network>/builder-list.toml into the JSON consumed by script/Deploy.s.sol.

Usage:
    python3 script/gen-builders.py mev-info/bsc-mainnet/builder-list.toml > script/input/bsc-mainnet/builders.json

The `name` field (operator) is derived from the TOML section header: the part before the first '-'.
    [blockrazor-dublin]  -> name = "blockrazor"
    [48club-puissant-builder-ap] -> name = "48club"
The `[example]` section is skipped.

Only the subset of TOML used by builder-list.toml is parsed ([section] headers and Key = "value"
lines), so this script has no third-party dependencies and runs on Python 3.8+.
"""

import json
import re
import sys

SECTION_RE = re.compile(r"^\[([^\]]+)\]\s*$")
KV_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]*)"\s*$')
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")


def parse(path):
    sections = []
    current = None
    with open(path, encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            m = SECTION_RE.match(line)
            if m:
                current = {"_section": m.group(1)}
                sections.append(current)
                continue
            m = KV_RE.match(line)
            if m and current is not None:
                current[m.group(1)] = m.group(2)
                continue
            sys.exit(f"{path}:{lineno}: cannot parse line: {raw.rstrip()}")
    return sections


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sections = parse(sys.argv[1])

    entries = []
    seen = set()
    for s in sections:
        section = s["_section"]
        if section == "example":
            continue
        addr = s.get("Address", "")
        url = s.get("RPC", "")
        if not ADDRESS_RE.match(addr):
            sys.exit(f"[{section}]: invalid or missing Address: {addr!r}")
        if not url:
            sys.exit(f"[{section}]: missing RPC")
        if addr.lower() in seen:
            sys.exit(f"[{section}]: duplicate Address {addr}")
        seen.add(addr.lower())
        name = section.split("-", 1)[0]
        # Keys must stay alphabetical (addr, name, url) for vm.parseJson struct decoding.
        entries.append({"addr": addr, "name": name, "url": url})

    json.dump(entries, sys.stdout, indent=2)
    sys.stdout.write("\n")

    counts = {}
    for e in entries:
        counts[e["name"]] = counts.get(e["name"], 0) + 1
    print(f"# {len(entries)} keys: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())), file=sys.stderr)


if __name__ == "__main__":
    main()
