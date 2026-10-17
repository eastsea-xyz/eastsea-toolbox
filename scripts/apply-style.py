#!/usr/bin/env python3
"""Swap the visual style of a template project folder.

    python3 scripts/apply-style.py PROJECT_DIR STYLE
    python3 scripts/apply-style.py --list

Replaces the <style id="eastsea-style"> token block in PROJECT_DIR/web/index.html
with templates/styles/STYLE.css, sets x-eastsea-template.style in
PROJECT_DIR/eastsea.json and refreshes web_sha256. Contracts, addresses,
notices and scripts are untouched. Use it on your own copy (for example one
made with `aether-agent template new`); the toolbox's own templates take their
style from templates/styles/styles.json via scripts/gen-templates.py.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import template_lib as lib  # noqa: E402
import template_styles  # noqa: E402


def apply_style(project: Path, name: str) -> str:
    page = project / "web" / "index.html"
    manifest_path = project / "eastsea.json"
    if not page.is_file() or not manifest_path.is_file():
        raise SystemExit(f"{project} is not a template project (needs eastsea.json and web/index.html)")
    page.write_text(template_styles.apply(page.read_text(encoding="utf-8"), name), encoding="utf-8")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    template = manifest["x-eastsea-template"]
    if "style" in template:
        template["style"] = name
    else:  # keep the generator's field order: style follows web
        manifest["x-eastsea-template"] = template = {
            **{k: v for k, v in template.items() if k in ("format", "slug", "summary", "web")},
            "style": name,
            **{k: v for k, v in template.items() if k not in ("format", "slug", "summary", "web")},
        }
    template["web_sha256"] = lib.web_sha256(project)
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return template["web_sha256"]


def main(argv):
    if argv == ["--list"]:
        data = template_styles.registry()
        for name in template_styles.names():
            mark = " (default)" if name == data["default"] else ""
            print(f"{name}\t{data['styles'][name]['name']}{mark}")
        return 0
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    project, name = Path(argv[0]), argv[1]
    try:
        digest = apply_style(project, name)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"{project}: style {name}, web_sha256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
