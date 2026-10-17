"""Shared pieces of the eastsea-template/1 packager and validator.

A template project folder holds:
  eastsea.json   an eastsea-app/1 manifest (zero placeholders, as in examples/)
                 plus the `x-eastsea-template` extension (deploy spec + interface)
  contracts/     one self-contained (flattened) Solidity file per contract
  web/           the bundle: index.html, docs, icon and a runtime manifest.json
                 whose contract addresses are {{placeholders}}

Hashes reuse the publisher's canonical eastsea-bundle/1 index, so a resolved
template bundle hashes exactly like `scripts/publish.py` output.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from publish import bundle_index, canonical  # same bytes as the publisher

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_FORMAT = "eastsea-template/1"
TREE_FORMAT = "eastsea-template-tree/1"
INDEX_FORMAT = "eastsea-template-index/1"
COMPILE_GATE = Path.home() / ".claude/playbooks/aether-team/wait-compile.sh"
COMPILER = {"solc": "0.8.24", "evm_version": "paris", "optimizer_runs": 200}

# A placeholder is the whole JSON string value. Only the resolved JSON files
# (web/manifest.json for the page, web/agent.json for agents) contain any;
# the page reads its addresses from manifest.json.
RESOLVED_FILES = ("agent.json", "manifest.json")
PLACEHOLDER = re.compile(r"\{\{(publisher|app_id|chain_id|native_symbol|native_decimals|system:names|address:[A-Za-z][A-Za-z0-9_]{0,31})\}\}")
ANY_PLACEHOLDER = re.compile(r"\{\{[^{}]*\}\}")
ADDRESS_LITERAL = re.compile(r"(?<![0-9a-fA-Fx])0x[0-9a-fA-F]{40}(?![0-9a-fA-F])")
# Template listings stay neutral: no ranking, yield or price words.
BANNED_WORDS = re.compile(r"\b(best|top|popular|recommended|trending|featured|yield|apy|apr|profit|profits|earn|earning|earnings|returns?|invest|investment|price|prices|priced|pricing|cheap|guaranteed|passive)\b", re.I)


def sha256(data: bytes) -> str:
    return "0x" + hashlib.sha256(data).hexdigest()


def keccak_hex(text: str) -> str:
    """Deterministic test-only identifiers (sha256 is enough; never on chain)."""
    return hashlib.sha256(text.encode()).hexdigest()


def tree_index(directory: Path) -> bytes:
    """Canonical index of every file in a template folder (path-byte sorted).

    Hidden paths (any component starting with ".") are not part of the
    project: `.eastsea/` holds prepared plans and Finder writes `.DS_Store`.
    """
    entries = []
    for file in sorted(directory.rglob("*"), key=lambda p: p.relative_to(directory).as_posix().encode()):
        if any(part.startswith(".") for part in file.relative_to(directory).parts):
            continue
        if file.is_symlink():
            raise ValueError(f"symlink in template: {file}")
        if file.is_dir():
            continue
        data = file.read_bytes()
        entries.append({"path": file.relative_to(directory).as_posix(), "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
    return canonical({"format": TREE_FORMAT, "files": entries})


def tree_sha256(directory: Path) -> str:
    return sha256(tree_index(directory))


def web_sha256(directory: Path) -> str:
    """Hash of the unresolved web folder (placeholders in place)."""
    return sha256(bundle_index(directory / "web"))


class DeterministicValues:
    """Fixed test vector for resolving placeholders (no chain, no account)."""

    def __getitem__(self, key: str):
        if key == "native_decimals":
            return 18
        if key == "native_symbol":
            return "SEA"
        if key == "chain_id":
            return "0x4574"  # current public testnet 17780
        if key == "app_id":
            return "0x" + keccak_hex("eastsea-template-test:app")
        return "0x" + keccak_hex("eastsea-template-test:" + key)[:40]


TEST_VALUES = DeterministicValues()


def resolve(value, values):
    """Replace whole-string placeholders with typed values; partial use is an error."""
    if isinstance(value, dict):
        return {k: resolve(v, values) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v, values) for v in value]
    if isinstance(value, str):
        match = PLACEHOLDER.fullmatch(value)
        if match:
            return values[match.group(1)]
        if ANY_PLACEHOLDER.search(value):
            raise ValueError(f"placeholder must be a whole value: {value}")
    return value


def placeholders_in(value) -> set[str]:
    found = set()
    if isinstance(value, dict):
        for v in value.values():
            found |= placeholders_in(v)
    elif isinstance(value, list):
        for v in value:
            found |= placeholders_in(v)
    elif isinstance(value, str):
        found |= set(ANY_PLACEHOLDER.findall(value))
    return found


def resolved_bundle_index(project: Path, values=TEST_VALUES) -> bytes:
    """Build the bundle with placeholders resolved and return its index bytes."""
    with tempfile.TemporaryDirectory(dir=_tmp()) as temp:
        bundle = Path(temp) / "bundle"
        shutil.copytree(project / "web", bundle)
        for name in RESOLVED_FILES:
            if (project / "web" / name).is_file():
                document = json.loads((project / "web" / name).read_text())
                (bundle / name).write_bytes(canonical(resolve(document, values)) + b"\n")
        return bundle_index(bundle)


def agent_interface(manifest: dict) -> dict:
    """web/agent.json: the interface agents read from a published bundle."""
    t = manifest["x-eastsea-template"]
    return {"format": "eastsea-agent-interface/1", "app_id": "{{app_id}}", "name": manifest["name"],
            "category": manifest["category"], "summary": t["summary"],
            "contracts": [{"id": c["id"], "contract": c["contract"], "address": "{{address:" + c["id"] + "}}"} for c in t["contracts"]],
            "functions": [{"id": row["contract"], "address": "{{address:" + row["contract"] + "}}", "function": row["function"],
                           "mutability": row["mutability"], "description": row["description"],
                           "moves_funds": row["moves_funds"], "example": row["example"]} for row in t["interface"]]}


def abi_signature(item) -> str:
    def kind(i):
        if i["type"].startswith("tuple"):
            return "(" + ",".join(kind(c) for c in i["components"]) + ")" + i["type"][5:]
        return i["type"]
    return item["name"] + "(" + ",".join(kind(i) for i in item["inputs"]) + ")"


def abi_type(item) -> str:
    if item["type"].startswith("tuple"):
        return "(" + ",".join(abi_type(c) for c in item["components"]) + ")" + item["type"][5:]
    return item["type"]


def _tmp() -> Path:
    path = ROOT / "tmp"
    path.mkdir(exist_ok=True)
    return path


def acquire_compile_gate():
    """Take one shared compile slot for this process tree (team gate, if installed).

    Nested callers (gen --check under the tests) inherit AETHER_COMPILE_GATE_HELD
    and do not queue for a second slot behind their own parent.
    """
    import os
    if os.environ.get("AETHER_COMPILE_GATE_HELD") == "1" or not COMPILE_GATE.is_file():
        return
    subprocess.run(["bash", str(COMPILE_GATE)], cwd=ROOT, check=True)
    os.environ["AETHER_COMPILE_GATE_HELD"] = "1"


def foundry_toml(compiler) -> str:
    return ("[profile.default]\nsrc = \"src\"\nout = \"out\"\ncache_path = \"cache\"\n"
            f"solc_version = \"{compiler['solc']}\"\nevm_version = \"{compiler['evm_version']}\"\n"
            f"optimizer = true\noptimizer_runs = {int(compiler['optimizer_runs'])}\n")


def compile_project(project: Path, workdir: Path, gate=True) -> dict:
    """Compile a template's contracts/ like `aether-agent app check` does.

    Layout and settings are fixed (src/<File>.sol, foundry.toml from the
    template's compiler block), so the metadata and bytecode match the agent.
    Returns {contract name: {"abi": [...], "bytecode": "0x..."}}.
    """
    manifest = json.loads((project / "eastsea.json").read_text())
    compiler = manifest["x-eastsea-template"]["compiler"]
    if workdir.exists():
        for stale in (workdir / "src").glob("*.sol"):
            stale.unlink()
    (workdir / "src").mkdir(parents=True, exist_ok=True)
    (workdir / "foundry.toml").write_text(foundry_toml(compiler))
    for source in sorted((project / "contracts").glob("*.sol")):
        shutil.copyfile(source, workdir / "src" / source.name)
    if gate:
        acquire_compile_gate()
    result = subprocess.run(["forge", "build", "--root", str(workdir)], capture_output=True, text=True,
                            env={**__import__("os").environ, "TMPDIR": str(_tmp()), "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"})
    if result.returncode:
        raise RuntimeError(f"compile failed for {project.name}: {result.stderr.strip() or result.stdout.strip()}")
    artifacts = {}
    for source in sorted((project / "contracts").glob("*.sol")):
        for file in sorted((workdir / "out" / source.name).glob("*.json")):
            data = json.loads(file.read_text())
            code = data.get("bytecode", {}).get("object", "")
            artifacts[file.stem] = {"abi": data["abi"], "bytecode": code if code.startswith("0x") else "0x" + code}
    return artifacts
