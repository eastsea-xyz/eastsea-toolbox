#!/usr/bin/env python3
"""Package every example as an eastsea-template/1 project under templates/projects/.

Sources: examples/<slug>/manifest.json and docs, apps/<slug>/index.html
(styled per templates/styles/styles.json), contracts/src (flattened with
`forge flatten`) and templates/template-specs.json (deploy recipe,
constructor labels, agent-readable interface text).

    python3 scripts/gen-templates.py           # (re)write templates/projects
    python3 scripts/gen-templates.py --check   # exit 1 if the tree differs from sources

Compiles each template's flattened contracts (shared compile gate, ./tmp/) to
read the ABI. Writes nothing outside templates/projects and ./tmp.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import template_lib as lib  # noqa: E402
import template_styles  # noqa: E402
from publish import PRIMARY, icon_png  # noqa: E402

ROOT = lib.ROOT
SPECS = ROOT / "templates" / "template-specs.json"
PROJECTS = ROOT / "templates" / "projects"
DOCS = ("README", "GAS", "SECURITY")


def pretty(value) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def flatten(source: str) -> bytes:
    result = subprocess.run(["forge", "flatten", source], cwd=ROOT / "contracts", capture_output=True, text=True,
                            env={**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"})
    if result.returncode or not result.stdout.strip():
        raise SystemExit(f"forge flatten {source} failed: {result.stderr.strip()}")
    return result.stdout.encode()


def runtime_manifest(slug, manifest, label_ids):
    contracts = []
    for entry in manifest["contracts"]:
        entry = dict(entry)
        target = label_ids.get(entry["label"])
        if target is None:
            raise SystemExit(f"{slug}: manifest contract {entry['label']!r} has no deployment or system placeholder")
        entry["address"] = target
        if entry.get("brake") != "none" and "brake" in entry:
            entry["brake"] = "none" if slug in {"airdrop", "names"} else target
        if slug == "amm" and entry["label"] == "AmmRouter":
            entry["brake"] = label_ids["AmmFactory"]
        contracts.append(entry)
    return {"schema": "toolbox-runtime/1", "app_id": "{{app_id}}", "contracts": contracts, "noindex": True,
            "x-toolbox-chain-id": "{{chain_id}}",
            "x-toolbox-native-currency": {"symbol": "{{native_symbol}}", "decimals": "{{native_decimals}}"},
            "x-toolbox-primary-contract": PRIMARY.get(slug, manifest["contracts"][0]["label"]),
            "x-toolbox-test-only": True}


def write_web(slug, project, runtime):
    web = project / "web"
    web.mkdir(parents=True)
    frontend = (ROOT / "apps" / slug / "index.html").read_bytes()
    for doc in DOCS:
        frontend = frontend.replace(f"../../examples/{slug}/{doc}.md".encode(), f"{doc}.txt".encode())
        (web / f"{doc}.txt").write_bytes((ROOT / "examples" / slug / f"{doc}.md").read_bytes())
    (web / "index.html").write_bytes(frontend)
    (web / "icon.png").write_bytes(icon_png())
    (web / "manifest.json").write_bytes(pretty(runtime))


def interface_for(spec, cid, contract, abi):
    texts = spec["contracts"][contract]["functions"]
    rows = []
    for item in sorted((i for i in abi if i["type"] == "function"), key=lib.abi_signature):
        signature = lib.abi_signature(item)
        text = texts.get(signature) or spec["common_functions"].get(signature)
        if text is None:
            raise SystemExit(f"{contract}.{signature}: no interface text in template-specs.json")
        example = {"args": text["example"]["args"]}
        if item["stateMutability"] == "payable":
            example["value_wei"] = text["example"].get("value_wei", "0")
        rows.append({"contract": cid, "function": signature, "mutability": item["stateMutability"],
                     "description": text["description"], "moves_funds": bool(text["moves_funds"]), "example": example})
    return rows


def build(slug, spec, out: Path, workdir: Path):
    recipe = spec["templates"][slug]
    manifest = json.loads((ROOT / "examples" / slug / "manifest.json").read_text())
    project = out / slug
    (project / "contracts").mkdir(parents=True)
    deploys = [s for s in recipe["steps"] if "id" in s]
    for contract in sorted({s["contract"] for s in deploys}):
        (project / "contracts" / f"{contract}.sol").write_bytes(flatten(spec["contracts"][contract]["source"]))
    label_ids = {s.get("manifest_label"): "{{address:" + s["id"] + "}}" for s in deploys if s.get("manifest_label")}
    label_ids["EastSeaNames (system)"] = "{{system:names}}"
    label_ids["AmmFactory"] = label_ids.get("AmmFactory", "{{address:AmmFactory}}")
    runtime = runtime_manifest(slug, manifest, label_ids)
    write_web(slug, project, runtime)
    template = {"format": lib.TEMPLATE_FORMAT, "slug": slug, "summary": recipe["summary"], "web": "web",
                "style": template_styles.style_for(slug), "screen": recipe["screen"], "compiler": dict(lib.COMPILER), "contracts": [], "steps": [], "placeholders": [], "interface": [],
                "check_call": recipe["check_call"], "web_sha256": lib.web_sha256(project)}
    (project / "eastsea.json").write_bytes(pretty({**manifest, "x-eastsea-template": template}))
    artifacts = lib.compile_project(project, workdir / slug, gate=False)
    used = lib.placeholders_in(runtime)
    for step in recipe["steps"]:
        if "id" not in step:
            template["steps"].append({"call": step["call"], "function": step["function"], "args": step["args"]})
            used |= lib.placeholders_in(step["args"])
            continue
        abi = artifacts[step["contract"]]["abi"]
        inputs = next((i for i in abi if i["type"] == "constructor"), {"inputs": []})["inputs"]
        docs = spec["contracts"][step["contract"]]["constructor"]
        if len(inputs) != len(step["args"]):
            raise SystemExit(f"{slug}.{step['id']}: {len(step['args'])} args for {len(inputs)} constructor inputs")
        entry = {"id": step["id"], "contract": step["contract"], "source": f"contracts/{step['contract']}.sol"}
        if step.get("manifest_label"):
            entry["manifest_label"] = step["manifest_label"]
        entry["constructor"] = [{"name": i["name"], "type": lib.abi_type(i), "label": docs[i["name"]]["label"],
                                 "description": docs[i["name"]]["description"], "value": value}
                                for i, value in zip(inputs, step["args"])]
        template["contracts"].append(entry)
        template["steps"].append({"deploy": step["id"]})
        template["interface"] += interface_for(spec, step["id"], step["contract"], abi)
        used |= lib.placeholders_in(step["args"])
    agent = lib.agent_interface({**manifest, "x-eastsea-template": template})
    (project / "web" / "agent.json").write_bytes(pretty(agent))
    used |= lib.placeholders_in(agent)
    template["placeholders"] = sorted(used)
    template["web_sha256"] = lib.web_sha256(project)
    (project / "eastsea.json").write_bytes(pretty({**manifest, "x-eastsea-template": template}))
    return {"slug": slug, "name": manifest["name"], "summary": recipe["summary"], "category": manifest["category"],
            "tree_sha256": lib.tree_sha256(project)}


def generate(out: Path):
    spec = json.loads(SPECS.read_text())
    slugs = sorted(p.parent.name for p in (ROOT / "examples").glob("*/manifest.json"))
    if sorted(spec["templates"]) != slugs:
        raise SystemExit("template-specs.json must cover exactly the examples/ slugs")
    workdir = ROOT / "tmp" / "template-build" / "gen"
    lib.acquire_compile_gate()
    entries = [build(slug, spec, out, workdir) for slug in slugs]
    index = {"format": lib.INDEX_FORMAT, "source_repo": "https://github.com/eastsea-xyz/eastsea-toolbox",
             "notice": "Published AS IS for testing. Not audited. Not ranked or endorsed.",
             "templates": entries}
    (out / "index.json").write_bytes(pretty(index))


def same_tree(a: Path, b: Path) -> list[str]:
    files = lambda d: {p.relative_to(d).as_posix() for p in d.rglob("*") if p.is_file()}
    left, right = files(a), files(b)
    diff = sorted(left ^ right)
    diff += sorted(p for p in left & right if (a / p).read_bytes() != (b / p).read_bytes())
    return diff


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    (ROOT / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=ROOT / "tmp", prefix="gen-templates-") as temp:
        staged = Path(temp) / "projects"
        staged.mkdir()
        generate(staged)
        if args.check:
            diff = same_tree(staged, PROJECTS) if PROJECTS.is_dir() else ["templates/projects missing"]
            for path in diff:
                print(f"DIFF {path}")
            print("templates/projects matches its sources" if not diff else f"{len(diff)} files differ; run scripts/gen-templates.py")
            return 1 if diff else 0
        if PROJECTS.exists():
            shutil.rmtree(PROJECTS)
        shutil.copytree(staged, PROJECTS)
    print(f"wrote {PROJECTS.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
