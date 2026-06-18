#!/usr/bin/env python
"""
Export Ombre Brain's pinned core principles to an offline fallback file.

Reads the live surfaced memory from Ombre Brain's /breath-hook endpoint, keeps
only the pinned "核心准则" sections, and writes them to
<IMPRINT_DATA_DIR>/ombre-core.md. The heartbeat uses this file when Ombre Brain
is unreachable, so messages keep 逸晨's core identity/relationship/voice even
when the memory server is down.

    python scripts/export_ombre_core.py

The heartbeat also refreshes this file automatically on every successful read,
so running this by hand is only needed for the initial export or a manual sync.
"""

import os
import sys
import urllib.request
from pathlib import Path

OMBRE_BREATH_URL = os.environ.get("OMBRE_BREATH_URL", "http://localhost:8000/breath-hook")
DATA_DIR = Path(os.environ.get("IMPRINT_DATA_DIR", str(Path.home() / ".imprint")))
OUT_FILE = DATA_DIR / "ombre-core.md"

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


def main():
    try:
        # Direct connection (Ombre is local, never via a proxy).
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(OMBRE_BREATH_URL, timeout=15) as resp:
            text = resp.read().decode("utf-8", errors="replace").strip()
    except Exception as e:
        print(f"Could not reach Ombre Brain at {OMBRE_BREATH_URL}: {e}", file=sys.stderr)
        sys.exit(1)

    parts = text.split("\n---\n")
    core = [p for p in parts if "核心准则" in p]
    if not core:
        print("No pinned core principles found in breath-hook output.", file=sys.stderr)
        sys.exit(1)

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    OUT_FILE.write_text("\n---\n".join(core).strip() + "\n", encoding="utf-8")
    print(f"Exported {len(core)} core principle section(s) to {OUT_FILE}")


if __name__ == "__main__":
    main()
