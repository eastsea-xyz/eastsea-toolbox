#!/usr/bin/env python3
"""Sanity-check the static front-ends under apps/.

For every examples/<slug>/ directory there must be an apps/<slug>/index.html
whose inline <script> blocks are syntactically valid JavaScript (node --check)
and which references the EastSea chain id. Exits non-zero on any failure.
Used by CI (.github/workflows/ci.yml) and safe to run locally.
"""

import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> int:
    slugs = sorted(p.name for p in (ROOT / "examples").iterdir() if p.is_dir())
    if not slugs:
        print("error: no examples/ directories found", file=sys.stderr)
        return 2

    failures = 0
    for slug in slugs:
        app = ROOT / "apps" / slug / "index.html"
        if not app.exists():
            print(f"FAIL {slug}: missing apps/{slug}/index.html")
            failures += 1
            continue
        html = app.read_text(encoding="utf-8")
        scripts = re.findall(r"<script>(.*?)</script>", html, re.S)
        if not scripts:
            print(f"FAIL {slug}: no <script> block")
            failures += 1
            continue
        ok = True
        for js in scripts:
            with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as t:
                t.write(js)
                path = t.name
            r = subprocess.run(["node", "--check", path], capture_output=True, text=True)
            if r.returncode != 0:
                print(f"FAIL {slug}: JS syntax error:\n{r.stderr[:500]}")
                ok = False
        if "0x1e64" not in html:
            print(f"FAIL {slug}: chain id 0x1e64 not referenced")
            ok = False
        if "eip6963" not in html.lower():
            print(f"FAIL {slug}: EIP-6963 discovery not referenced")
            ok = False
        if ok:
            print(f"ok   {slug}")
        else:
            failures += 1

    total = len(slugs)
    print(f"\n{total - failures}/{total} front-ends valid")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
