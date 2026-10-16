#!/usr/bin/env python3
"""Check every eastsea-template/1 project under templates/projects.

    python3 scripts/validate-templates.py [--projects DIR] [--no-compile]

Per template: eastsea.json against eastsea-template-1.json (which extends
eastsea-app-1.json); deploy steps and placeholders are consistent; the web
folder reads contract addresses only through declared placeholders in
web/manifest.json; web_sha256 matches; the resolved bundle hash is
reproducible; the contracts compile and the interface covers exactly their
public functions; the listing summary is neutral; index.json tree hashes match.
Exit 0 only when every template passes. No network, wallet or deployment.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import template_lib as lib  # noqa: E402

ROOT = lib.ROOT
SCHEMAS = ROOT / "templates" / "publish" / "schema"


@dataclass
class Report:
    errors: list = field(default_factory=list)
    checked: list = field(default_factory=list)


def schema_validator():
    import jsonschema
    from referencing import Registry, Resource
    registry = Registry()
    for path in SCHEMAS.glob("*.json"):
        document = json.loads(path.read_text())
        registry = registry.with_resource(document["$id"], Resource.from_contents(document))
    template = json.loads((SCHEMAS / "eastsea-template-1.json").read_text())
    return jsonschema.Draft202012Validator(template, registry=registry)


def arity(signature: str) -> int:
    inner = signature[signature.index("(") + 1:-1]
    if not inner:
        return 0
    depth, count = 0, 1
    for ch in inner:
        depth += ch == "("
        depth -= ch == ")"
        count += ch == "," and depth == 0
    return count


def check_static(project: Path, manifest: dict, fail):
    t = manifest["x-eastsea-template"]
    if t["slug"] != project.name:
        fail(f"slug {t['slug']!r} differs from folder name")
    if manifest.get("x-toolbox-example") not in (None, f"examples/{project.name}"):
        fail("x-toolbox-example points at another example")
    if lib.BANNED_WORDS.search(t["summary"]):
        fail(f"summary uses ranking/yield/price wording: {t['summary']!r}")
    ids = [c["id"] for c in t["contracts"]]
    if len(set(ids)) != len(ids):
        fail("duplicate contract ids")
    for c in t["contracts"]:
        if c["source"] != f"contracts/{c['contract']}.sol" or not (project / c["source"]).is_file():
            fail(f"{c['id']}: source {c['source']} missing")
    sources = {p.name for p in (project / "contracts").glob("*")}
    if sources != {Path(c["source"]).name for c in t["contracts"]}:
        fail(f"contracts/ holds undeclared files: {sorted(sources)}")
    deployed = [s["deploy"] for s in t["steps"] if "deploy" in s]
    if sorted(deployed) != sorted(ids):
        fail("steps must deploy every declared contract exactly once")
    so_far = set()
    for step in t["steps"]:
        if "deploy" in step:
            so_far.add(step["deploy"])
        else:
            if step["call"] not in so_far:
                fail(f"call step targets {step['call']} before it is deployed")
            if arity(step["function"]) != len(step["args"]):
                fail(f"call {step['function']}: wrong argument count")
    labels = {c.get("manifest_label") for c in t["contracts"]}
    for c in manifest["contracts"]:
        if c["label"] not in labels and c["label"] != "EastSeaNames (system)":
            fail(f"manifest contract {c['label']!r} has no deployment")
    if t["check_call"]["contract"] not in ids:
        fail("check_call targets an undeployed contract")
    used = set()
    for c in t["contracts"]:
        for p in c["constructor"]:
            used |= lib.placeholders_in(p["value"])
    for s in t["steps"]:
        used |= lib.placeholders_in(s.get("args", []))
    return ids, used


def check_web(project: Path, manifest: dict, ids, used, fail):
    t = manifest["x-eastsea-template"]
    web = project / "web"
    if not (web / "manifest.json").is_file() or not (web / "index.html").is_file():
        fail("web/ needs index.html and manifest.json")
        return
    for file in sorted(web.rglob("*")):
        if not file.is_file() or file.suffix in {".png"}:
            continue
        text = file.read_text(encoding="utf-8")
        # agent.json is checked below to equal eastsea.json's interface (its
        # example calls may use sample addresses); everything else is scanned.
        for literal in ([] if file.name == "agent.json" else lib.ADDRESS_LITERAL.findall(text)):
            if int(literal, 16):
                fail(f"web/{file.name}: address literal {literal}; read it from manifest.json through a placeholder")
        if file.relative_to(web).as_posix() not in lib.RESOLVED_FILES and lib.ANY_PLACEHOLDER.search(text):
            fail(f"web/{file.name}: placeholders are only allowed in web/manifest.json and web/agent.json")
    runtime = json.loads((web / "manifest.json").read_text())
    web_used = lib.placeholders_in(runtime)
    agent_file = web / "agent.json"
    if not agent_file.is_file():
        fail("web/agent.json missing (the interface agents read from the bundle)")
    else:
        agent = json.loads(agent_file.read_text())
        if agent != lib.agent_interface(manifest):
            fail("web/agent.json differs from eastsea.json's interface")
        web_used |= lib.placeholders_in(agent)
    used = used | web_used
    declared = set(t["placeholders"])
    for p in sorted(used - declared):
        fail(f"undeclared placeholder {p}")
    for p in sorted(declared - used):
        fail(f"declared placeholder {p} is never used")
    for p in sorted(used):
        if not lib.PLACEHOLDER.fullmatch(p):
            fail(f"unknown placeholder {p}")
        elif p.startswith("{{address:") and p[10:-2] not in ids:
            fail(f"placeholder {p} names no deployed contract")
    for c in runtime.get("contracts", []):
        if not lib.PLACEHOLDER.fullmatch(str(c.get("address"))):
            fail(f"web/manifest.json contract {c.get('label')!r} address is not a placeholder")
    if lib.web_sha256(project) != t["web_sha256"]:
        fail("web_sha256 does not match web/ (rebuild the template)")
    try:
        first = lib.resolved_bundle_index(project)
        second = lib.resolved_bundle_index(project)
        if first != second:
            fail("resolved bundle hash is not reproducible")
        resolved = lib.resolve(runtime, lib.TEST_VALUES)
        if lib.placeholders_in(resolved):
            fail("placeholders remain after resolution")
    except (ValueError, KeyError) as error:
        fail(f"bundle does not resolve: {error}")


def check_compiled(project: Path, t: dict, workdir: Path, fail):
    try:
        artifacts = lib.compile_project(project, workdir, gate=False)
    except RuntimeError as error:
        fail(str(error))
        return
    rows = {}
    for row in t["interface"]:
        key = (row["contract"], row["function"])
        if key in rows:
            fail(f"duplicate interface entry {key}")
        rows[key] = row
    expected = set()
    for c in t["contracts"]:
        art = artifacts.get(c["contract"])
        if not art or art["bytecode"] in {"0x", ""}:
            fail(f"{c['contract']}: no deployable bytecode")
            continue
        ctor = next((i for i in art["abi"] if i["type"] == "constructor"), {"inputs": []})["inputs"]
        if [(i["name"], lib.abi_type(i)) for i in ctor] != [(p["name"], p["type"]) for p in c["constructor"]]:
            fail(f"{c['id']}: constructor params differ from the compiled ABI")
        for item in art["abi"]:
            if item["type"] != "function":
                continue
            key = (c["id"], lib.abi_signature(item))
            expected.add(key)
            row = rows.get(key)
            if row is None:
                fail(f"interface lacks {key[0]}.{key[1]}")
                continue
            if row["mutability"] != item["stateMutability"]:
                fail(f"{key[0]}.{key[1]}: mutability {row['mutability']} != {item['stateMutability']}")
            if item["stateMutability"] in {"view", "pure"} and row["moves_funds"]:
                fail(f"{key[0]}.{key[1]}: a read cannot move funds")
            if len(row["example"]["args"]) != len(item["inputs"]):
                fail(f"{key[0]}.{key[1]}: example has {len(row['example']['args'])} args for {len(item['inputs'])} inputs")
            if (item["stateMutability"] == "payable") != ("value_wei" in row["example"]):
                fail(f"{key[0]}.{key[1]}: value_wei only (and always) for payable functions")
    for key in sorted(set(rows) - expected):
        fail(f"interface lists {key[0]}.{key[1]} which the contract does not have")
    check = (t["check_call"]["contract"], t["check_call"]["function"])
    if check not in rows or rows[check]["mutability"] not in {"view", "pure"}:
        fail(f"check_call {check[0]}.{check[1]} is not a zero-argument read in the interface")


def validate(projects: Path, compile_contracts=True) -> Report:
    report = Report()
    validator = schema_validator()
    workroot = ROOT / "tmp" / "template-build" / "validate"
    if compile_contracts:
        lib.acquire_compile_gate()
    folders = sorted(p.parent for p in projects.glob("*/eastsea.json"))
    for project in folders:
        def fail(message, slug=project.name):
            report.errors.append(f"{slug}: {message}")
        try:
            manifest = json.loads((project / "eastsea.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            fail(f"eastsea.json unreadable: {error}")
            continue
        errors = sorted(validator.iter_errors(manifest), key=lambda e: list(e.absolute_path))
        for err in errors:
            fail("schema: " + (".".join(str(p) for p in err.absolute_path) or "<root>") + ": " + err.message)
        if errors:
            continue
        before = len(report.errors)
        ids, used = check_static(project, manifest, fail)
        check_web(project, manifest, ids, used, fail)
        if compile_contracts:
            check_compiled(project, manifest["x-eastsea-template"], workroot / project.name, fail)
        if len(report.errors) == before:
            report.checked.append(project.name)
    check_index(projects, folders, report)
    return report


def check_index(projects: Path, folders, report):
    path = projects / "index.json"
    if not path.is_file():
        report.errors.append("index.json missing")
        return
    index = json.loads(path.read_text())
    entries = index.get("templates", [])
    if index.get("format") != lib.INDEX_FORMAT:
        report.errors.append("index.json: wrong format")
    if [e.get("slug") for e in entries] != sorted(p.name for p in folders):
        report.errors.append("index.json: must list every template once, sorted by slug (no ranking)")
    for entry in entries:
        project = projects / str(entry.get("slug"))
        if not (project / "eastsea.json").is_file():
            continue
        manifest = json.loads((project / "eastsea.json").read_text())
        t = manifest.get("x-eastsea-template", {})
        expected = {"slug": project.name, "name": manifest.get("name"), "summary": t.get("summary"),
                    "category": manifest.get("category"), "tree_sha256": lib.tree_sha256(project)}
        for key, value in expected.items():
            if entry.get(key) != value:
                report.errors.append(f"index.json: {project.name}.{key} differs from the template (tree_sha256/summary must be rebuilt)")
        if set(entry) != set(expected):
            report.errors.append(f"index.json: {project.name} has unexpected fields")
        if lib.BANNED_WORDS.search(str(entry.get("summary", ""))):
            report.errors.append(f"index.json: {project.name} summary uses ranking/yield/price wording")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--projects", type=Path, default=ROOT / "templates" / "projects")
    parser.add_argument("--no-compile", action="store_true")
    args = parser.parse_args(argv)
    report = validate(args.projects, compile_contracts=not args.no_compile)
    for slug in report.checked:
        print(f"OK   {slug}")
    for error in report.errors:
        print(f"FAIL {error}")
    index = args.projects / "index.json"
    if index.is_file():
        print(f"index.json sha256 {lib.sha256(index.read_bytes())}")
    print(f"\n{len(report.checked)}/{len(list(args.projects.glob('*/eastsea.json')))} templates valid")
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())
