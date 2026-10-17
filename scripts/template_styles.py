"""Swappable visual styles for the template front-ends.

templates/styles/<name>.css holds one style's design tokens (CSS custom
properties, light and dark). The shared front-end in scripts/gen-apps.py
uses only those tokens, so a style is changed by swapping one block:

    <style id="eastsea-style" data-style="<name>">...tokens...</style>

The block is inlined so every bundle stays a single self-contained file set
(no external fonts, CDNs or extra files). templates/styles/styles.json names
the styles, the default, and the style each template ships with.
"""

from __future__ import annotations

import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
STYLES_DIR = ROOT / "templates" / "styles"
REGISTRY_FORMAT = "eastsea-template-styles/1"
NAME = re.compile(r"^[a-z][a-z0-9-]{1,23}$")
BLOCK = re.compile(r'<style id="eastsea-style" data-style="([a-z][a-z0-9-]{1,23})">\n(.*?)</style>', re.S)
CUSTOM_PROPERTY = re.compile(r"(--[a-z0-9-]+)\s*:")
# A token file may not reach outside the bundle or run anything.
FORBIDDEN = re.compile(r"url\(|@import|@font-face|https?:|//[a-z]|expression\(|javascript:|<", re.I)


def registry() -> dict:
    data = json.loads((STYLES_DIR / "styles.json").read_text(encoding="utf-8"))
    if data.get("format") != REGISTRY_FORMAT:
        raise ValueError("templates/styles/styles.json: wrong format")
    if data.get("default") not in data.get("styles", {}):
        raise ValueError("templates/styles/styles.json: default style is not defined")
    for slug, name in data.get("templates", {}).items():
        if name not in data["styles"]:
            raise ValueError(f"templates/styles/styles.json: {slug} uses unknown style {name!r}")
    return data


def names() -> list[str]:
    return sorted(registry()["styles"])


def default() -> str:
    return registry()["default"]


def style_for(slug: str) -> str:
    data = registry()
    return data["templates"].get(slug, data["default"])


def tokens(name: str) -> str:
    data = registry()
    if not NAME.fullmatch(name) or name not in data["styles"]:
        raise ValueError(f"unknown style {name!r} (known: {', '.join(sorted(data['styles']))})")
    return (STYLES_DIR / data["styles"][name]["file"]).read_text(encoding="utf-8")


def block(name: str) -> str:
    return f'<style id="eastsea-style" data-style="{name}">\n{tokens(name)}</style>'


def current(html: str) -> tuple[str, str] | None:
    """(style name, token text) of the page's style block, or None."""
    found = BLOCK.findall(html)
    if len(found) != 1:
        return None
    return found[0]


def apply(html: str, name: str) -> str:
    if len(BLOCK.findall(html)) != 1:
        raise ValueError("page has no single eastsea-style block")
    replacement = block(name)
    return BLOCK.sub(lambda _: replacement, html)


def properties(css: str, scope: str) -> set[str]:
    """Custom properties declared in the light (:root{...}) or dark scope."""
    if scope == "light":
        body = css[css.index(":root{"):css.index("}", css.index(":root{"))]
    else:
        start = css.index(':root[data-theme="dark"]{')
        body = css[start:css.index("}", start)]
    return set(CUSTOM_PROPERTY.findall(body))


def media_dark(css: str) -> set[str]:
    start = css.index("@media (prefers-color-scheme:dark){")
    return set(CUSTOM_PROPERTY.findall(css[start:css.index("}}", start)]))


def check_style_files() -> list[str]:
    """Every style defines the same tokens; dark overrides match; nothing external."""
    errors = []
    data = registry()
    light_sets, dark_sets = {}, {}
    for name, entry in sorted(data["styles"].items()):
        if not NAME.fullmatch(name) or entry.get("file") != f"{name}.css":
            errors.append(f"style {name!r}: file must be {name}.css")
            continue
        css = tokens(name)
        if FORBIDDEN.search(css):
            errors.append(f"style {name}: external reference or markup in token file")
        try:
            light_sets[name] = properties(css, "light")
            dark_sets[name] = properties(css, "dark")
            if media_dark(css) != dark_sets[name]:
                errors.append(f"style {name}: prefers-color-scheme and data-theme dark tokens differ")
            if not dark_sets[name] <= light_sets[name]:
                errors.append(f"style {name}: dark tokens not declared for light: {sorted(dark_sets[name] - light_sets[name])}")
        except ValueError:
            errors.append(f"style {name}: needs :root{{}}, @media dark and :root[data-theme=\"dark\"] blocks")
    if light_sets:
        reference = set.union(*light_sets.values())
        for name, found in light_sets.items():
            if found != reference:
                errors.append(f"style {name}: missing tokens {sorted(reference - found)}")
    return errors
