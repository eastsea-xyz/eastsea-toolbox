#!/usr/bin/env python3
"""Render every template front-end in every style (offline, static fixtures).

    python3 scripts/render-styles.py prepare   # build tmp/style-renders/_site
    python3 scripts/render-styles.py chain STYLE [SLUG...]  # print a gstack `browse chain` script
    python3 scripts/render-styles.py sheets    # contact sheet per style (needs Pillow)

`prepare` copies templates/projects/<slug>/web into
tmp/style-renders/_site/<style>/<slug>/ with the style block swapped, the
manifest resolved with the validator's deterministic test values and a
fixture wallet (a fake EIP-1193 provider that answers reads with fixed words
and never signs) injected before the page script. Nothing here reaches a
network, wallet or key; the copies live only under tmp/.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import template_lib as lib  # noqa: E402
import template_screen as screens  # noqa: E402
import template_styles as styles  # noqa: E402

ROOT = lib.ROOT
OUT = ROOT / "tmp" / "style-renders"
SITE = OUT / "_site"
PORT = 8791
SHOTS = (("desktop", 1280, 800), ("mobile", 390, 844))
THEMES = ("light", "dark")

FIXTURE_WALLET = """<script>
(() => {
  const chain = %s, account = '0x' + 'a1'.repeat(20), answers = %s;
  const word = (n) => '0x' + BigInt(n).toString(16).padStart(64, '0');
  window.aether = { isAether: true, async request({ method, params }) {
    if (method === 'eth_chainId') return chain;
    if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [account];
    if (method === 'eth_call') return answers[params[0].data.slice(0, 10)] || word(0);
    if (method === 'eth_blockNumber') return '0x2a';
    if (method === 'eth_getLogs') return [];
    throw Object.assign(new Error('fixture wallet: ' + method + ' is not available in renders'), { code: 4200 });
  }, on() {}, removeListener() {} };
})();
</script>
"""

NOW = 1792195200  # fixed render clock (2026-10-17), so renders are reproducible


def fixture_answers(screen: dict, decimals: int, name: str = "Island Folk · Tide") -> dict:
    """Plausible eth_call answers per selector for the screen's reads (render only)."""
    words: dict[str, dict[int, bytes]] = {}
    texts: dict[str, tuple[int, str]] = {}
    progress = screen.get("progress", {})
    for read in screen.get("reads", []):
        sel, w, show = screens.selector(read["call"]), read.get("word", 0), read["show"]
        value = {"native": 125 * 10 ** decimals // 100, "token": 1250 * 10 ** 18, "count": 42, "bps": 100,
                 "time": NOW + 9 * 86400, "duration": 7 * 86400, "per-day": 10 ** decimals // 86400 // 10,
                 "bool": 0, "state": 0, "address": int("a1" * 20, 16), "hash": int("5e" * 32, 16)}.get(show, 0)
        if read.get("id") and read.get("id") == progress.get("max"):
            value = {"native": 10 * 10 ** decimals, "token": 10000 * 10 ** 18}.get(show, 100)
        if read.get("id") and read.get("id") == progress.get("value"):
            value = {"native": 62 * 10 ** decimals // 10, "token": 6200 * 10 ** 18}.get(show, 62)
        if show == "text":
            texts[sel] = (w, read["label"] == "기호" and "ISLE" or name)
            continue
        words.setdefault(sel, {})[w] = value.to_bytes(32, "big")
    answers = {}
    for sel in set(words) | set(texts):
        cells = dict(words.get(sel, {}))
        size = max(list(cells) + [texts[sel][0] if sel in texts else 0]) + 1
        tail = b""
        if sel in texts:
            w, text = texts[sel]
            cells[w] = (size * 32).to_bytes(32, "big")
            data = text.encode()
            tail = len(data).to_bytes(32, "big") + data.ljust((len(data) + 31) // 32 * 32, b"\0")
        answers[sel] = "0x" + b"".join(cells.get(i, bytes(32)) for i in range(size)).hex() + tail.hex()
    return answers


def prepare():
    if SITE.exists():
        shutil.rmtree(SITE)
    projects = sorted(p.parent for p in (ROOT / "templates" / "projects").glob("*/eastsea.json"))
    for name in ([os.environ["RENDER_STYLE"]] if os.environ.get("RENDER_STYLE") else styles.names()):
        for project in projects:
            dest = SITE / name / project.name
            shutil.copytree(project / "web", dest)
            runtime = lib.resolve(json.loads((project / "web" / "manifest.json").read_text()), lib.TEST_VALUES)
            runtime["x-toolbox-native-currency"]["symbol"] = "DBLN"  # what people will see on EastSea
            (dest / "manifest.json").write_text(json.dumps(runtime, indent=2))
            chain = json.dumps(hex(int(str(runtime["x-toolbox-chain-id"]), 0)))
            page = (dest / "index.html").read_text(encoding="utf-8")
            if styles.current(page) is None:  # template not regenerated yet: preview the apps/ page
                page = (ROOT / "apps" / project.name / "index.html").read_text(encoding="utf-8")
            html = styles.apply(page, name)
            screen = json.loads((ROOT / "templates" / "template-specs.json").read_text())["templates"][project.name]["screen"]
            answers = json.dumps(fixture_answers(screen, runtime["x-toolbox-native-currency"]["decimals"],
                                                      json.loads((project / "eastsea.json").read_text())["name"]))
            html = html.replace("<script>\nconst APP", FIXTURE_WALLET % (chain, answers) + "<script>\nconst APP", 1)
            (dest / "index.html").write_text(html, encoding="utf-8")
    print(f"prepared {len(projects)} templates x {len(styles.names())} styles under {SITE.relative_to(ROOT)}")


def chain(name: str, only=None):
    steps = []
    slugs = sorted(p.name for p in (SITE / name).iterdir() if p.is_dir() and (not only or p.name in only))
    for kind, width, height in SHOTS:
        steps.append(["viewport", f"{width}x{height}"])
        for slug in slugs:
            steps.append(["goto", f"http://127.0.0.1:{PORT}/{name}/{slug}/"])
            steps.append(["wait", "#wallets button"])
            steps.append(["js", "connect(discovered[0]).then(() => document.getElementById('load-logs').click()).then(() => true)"])
            for theme in THEMES:
                steps.append(["js", f"document.documentElement.dataset.theme='{theme}'"])
                steps.append(["js", "new Promise((done) => setTimeout(() => done(true), 450))"])  # let color transitions settle
                steps.append(["screenshot", str(OUT / name / f"{slug}-{kind}-{theme}.png")])
    (OUT / name).mkdir(parents=True, exist_ok=True)
    print(json.dumps(steps))


def sheets():
    from PIL import Image, ImageDraw
    for name in ([os.environ["RENDER_STYLE"]] if os.environ.get("RENDER_STYLE") else styles.names()):
        files = sorted((OUT / name).glob("*-desktop-light.png"))
        cell_w, cell_h, label = 640, 400, 22
        cols = 4
        rows = (len(files) + cols - 1) // cols
        for theme in THEMES:
            sheet = Image.new("RGB", (cell_w * cols, (cell_h + label) * rows), "white")
            draw = ImageDraw.Draw(sheet)
            for i, light in enumerate(files):
                path = light.with_name(light.name.replace("-light", f"-{theme}"))
                image = Image.open(path).convert("RGB")
                image = image.crop((0, 0, image.width, min(image.height, int(image.width * cell_h / cell_w))))
                image.thumbnail((cell_w, cell_h))
                x, y = (i % cols) * cell_w, (i // cols) * (cell_h + label)
                sheet.paste(image, (x, y + label))
                draw.text((x + 6, y + 5), light.name.split("-desktop")[0], fill="black")
            target = OUT / f"sheet-{name}-desktop-{theme}.jpg"
            sheet.save(target, quality=82)
            print(target.relative_to(ROOT))
        mobile = sorted((OUT / name).glob("*-mobile-light.png"))
        cell_w, cell_h = 260, 560
        cols = 9
        rows = (len(mobile) * 2 + cols - 1) // cols
        sheet = Image.new("RGB", (cell_w * cols, (cell_h + label) * rows), "white")
        draw = ImageDraw.Draw(sheet)
        i = 0
        for light in mobile:
            for theme in THEMES:
                image = Image.open(light.with_name(light.name.replace("-light", f"-{theme}"))).convert("RGB")
                image = image.crop((0, 0, image.width, min(image.height, int(image.width * cell_h / cell_w))))
                image.thumbnail((cell_w, cell_h))
                x, y = (i % cols) * cell_w, (i // cols) * (cell_h + label)
                sheet.paste(image, (x, y + label))
                draw.text((x + 4, y + 5), light.name.split("-mobile")[0] + " " + theme, fill="black")
                i += 1
        target = OUT / f"sheet-{name}-mobile.jpg"
        sheet.save(target, quality=82)
        print(target.relative_to(ROOT))



if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "prepare":
        prepare()
    elif command == "chain" and len(sys.argv) >= 3:
        chain(sys.argv[2], set(sys.argv[3:]))
    elif command == "sheets":
        sheets()
    else:
        sys.exit(__doc__)
