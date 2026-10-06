#!/usr/bin/env python3
"""Fidelity check: rebuilt upstream runtime bytecode vs Ethereum mainnet.

For each item manifest under proof/fidelity/items/*.json this script:

  1. fetches the pinned upstream repo at the exact commit (shallow, cached
     under proof/.fidelity-work/, gitignored);
  2. collects the entry file and its imports, builds a solc standard-JSON
     input with the ORIGINAL compiler version, optimizer, runs, evmVersion
     and viaIR settings, and compiles with that solc (installed by Foundry's
     svm into ~/.svm when missing);
  3. loads the mainnet runtime code from proof/mainnet-code/<chain>-<addr>.hex
     (fetching it once with eth_getCode when --fetch is given);
  4. masks what legitimately differs (immutables, linked-library slots, the
     library self-address, and the hash inside every CBOR metadata blob,
     including metadata of creation code embedded in the runtime) and
     compares.

Verdicts (catalog §5):
  MATCH                      byte-identical
  MATCH (modulo metadata)    identical after masking metadata hashes
  MATCH (modulo immutables)  identical after masking immutables (+ metadata)
  MISMATCH (detail)          different code; first differing offset printed
  NOT_COMPARABLE (reason)    no mainnet instance, no compiler, fetch failed

Offline by default: CI never touches the network once the cache exists.
Exit status is 1 if any item is MISMATCH (NOT_COMPARABLE does not fail).

Usage:
  proof/fidelity.py                      # all items, offline
  proof/fidelity.py multicall3 weth9     # selected items (file stem)
  proof/fidelity.py --fetch              # allow git fetch + eth_getCode
  proof/fidelity.py --rpc URL            # RPC for --fetch (default publicnode)
  proof/fidelity.py --json               # machine-readable results
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

PROOF = Path(__file__).resolve().parent
ITEMS_DIR = PROOF / "fidelity" / "items"
CODE_DIR = PROOF / "mainnet-code"
WORK_DIR = PROOF / ".fidelity-work"
SVM_DIR = Path(os.environ.get("SVM_HOME", Path.home() / ".svm"))
DEFAULT_RPC = "https://ethereum-rpc.publicnode.com"

# CBOR metadata blobs solc appends: (prefix, hash length in bytes).
#   bzzr0 (0.4.7-0.5.8), bzzr1 (0.5.9-0.5.17), ipfs (0.6+).
METADATA_PREFIXES = [
    (bytes.fromhex("a165627a7a72305820"), 32),
    (bytes.fromhex("a265627a7a72305820"), 32),
    (bytes.fromhex("a265627a7a72315820"), 32),
    (bytes.fromhex("a264697066735822"), 34),
]

IMPORT_RE = re.compile(r"""^\s*import\s+(?:[^"';]*\bfrom\s+)?["']([^"']+)["']""", re.M)


@dataclass
class Result:
    item: str
    verdict: str
    detail: str = ""
    sizes: dict = field(default_factory=dict)


# --------------------------------------------------------------------------- #
#                                   helpers                                    #
# --------------------------------------------------------------------------- #


def run(cmd: list[str], cwd: Path | None = None, inp: str | None = None) -> str:
    proc = subprocess.run(cmd, cwd=cwd, input=inp, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:3])}... failed: {proc.stderr.strip()[:400]}")
    return proc.stdout


def fetch_repo(repo: str, commit: str, allow_fetch: bool, submodules: bool = False) -> Path:
    """Shallow checkout of repo@commit (plus its pinned submodules when the
    item imports from lib/), cached by commit hash."""
    dest = WORK_DIR / "src" / commit
    if (dest / ".fidelity-ok").exists():
        return dest
    if not allow_fetch:
        raise LookupError(f"source {repo}@{commit[:10]} not cached (run with --fetch)")
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    run(["git", "init", "-q"], cwd=dest)
    run(["git", "remote", "add", "origin", repo], cwd=dest)
    run(["git", "fetch", "-q", "--depth", "1", "origin", commit], cwd=dest)
    run(["git", "checkout", "-q", "FETCH_HEAD"], cwd=dest)
    if submodules:
        run(["git", "submodule", "update", "-q", "--init", "--recursive"], cwd=dest)
    head = run(["git", "rev-parse", "HEAD"], cwd=dest).strip()
    if head != commit:
        raise RuntimeError(f"checked out {head}, expected {commit}")
    (dest / ".fidelity-ok").write_text(commit)
    return dest


def solc_path(version: str) -> Path:
    """Path to solc <version>; installs it through Foundry's svm if missing."""
    path = SVM_DIR / version / f"solc-{version}"
    if path.exists():
        return path
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "src"
        src.mkdir()
        (src / "A.sol").write_text(f"pragma solidity {version};\ncontract A {{}}\n")
        run(["forge", "build", "--use", version, "--root", tmp], cwd=Path(tmp))
    if not path.exists():
        raise LookupError(f"solc {version} not available after forge install")
    return path


def resolve_import(importer: str, target: str, remappings: list[str]) -> str:
    for rm in remappings:
        prefix, _, repl = rm.partition("=")
        if target.startswith(prefix):
            return os.path.normpath(repl + target[len(prefix):])
    if target.startswith("."):
        return os.path.normpath(os.path.join(os.path.dirname(importer), target))
    return os.path.normpath(target)


def collect_sources(root: Path, entry: str, remappings: list[str]) -> dict[str, dict]:
    """Entry file plus its transitive imports, keyed by repo-relative path.

    Source unit names are the import strings as solc would see them, so the
    remapped/relative resolution is mirrored in the standard-JSON input.
    """
    sources: dict[str, dict] = {}
    todo = [entry]
    while todo:
        unit = todo.pop()
        if unit in sources:
            continue
        text = (root / unit).read_text()
        sources[unit] = {"content": text}
        for imp in IMPORT_RE.findall(text):
            todo.append(resolve_import(unit, imp, remappings))
    return sources


def compile_solc(item: dict, root: Path) -> tuple[bytes, list[tuple[int, int]], bool]:
    """Returns (runtime, masked ranges [(start, len)], is_library)."""
    c = item["compiler"]
    remappings = item.get("remappings", [])
    sources = collect_sources(root, item["entry"], remappings)
    settings: dict = {
        "optimizer": {"enabled": bool(c.get("optimizer")), "runs": int(c.get("runs", 200))},
        "outputSelection": {
            item["entry"]: {
                item["contract"]: [
                    "evm.deployedBytecode.object",
                    "evm.deployedBytecode.linkReferences",
                    "evm.deployedBytecode.immutableReferences",
                ]
            }
        },
    }
    if c.get("evmVersion"):
        settings["evmVersion"] = c["evmVersion"]
    if c.get("viaIR"):
        settings["viaIR"] = True
    if c.get("bytecodeHash"):
        settings["metadata"] = {"bytecodeHash": c["bytecodeHash"]}
    if remappings:
        settings["remappings"] = remappings
    std_in = json.dumps({"language": "Solidity", "sources": sources, "settings": settings})
    out = json.loads(run([str(solc_path(c["solc"])), "--standard-json"], inp=std_in))
    errors = [e for e in out.get("errors", []) if e.get("severity") == "error"]
    if errors:
        raise RuntimeError("solc: " + errors[0].get("formattedMessage", "")[:400])
    dep = out["contracts"][item["entry"]][item["contract"]]["evm"]["deployedBytecode"]
    obj = dep["object"]
    masks: list[tuple[int, int]] = []
    # Unlinked libraries appear as __$...$__ (or __Name___ in 0.4) placeholders.
    for refs in (dep.get("linkReferences") or {}).values():
        for lst in refs.values():
            masks += [(r["start"], r["length"]) for r in lst]
    # Placeholders are exactly 40 chars starting and ending with "__"; hex
    # never contains "_", so this cannot touch real code.
    obj = re.sub(r"__.{36}__", "0" * 40, obj)
    for lst in (dep.get("immutableReferences") or {}).values():
        masks += [(r["start"], r["length"]) for r in lst]
    runtime = bytes.fromhex(obj)
    # A library's runtime starts with PUSH20 <self address> (zero at compile).
    is_library = runtime[:21] == b"\x73" + b"\x00" * 20
    return runtime, masks, is_library


def compile_vyper(item: dict, root: Path) -> tuple[bytes, list[tuple[int, int]], bool]:
    version = item["compiler"]["vyper"]
    exe = shutil.which("vyper")
    if not exe:
        raise LookupError(f"vyper {version} not installed (pip install vyper=={version})")
    got = run([exe, "--version"]).strip()
    if not got.startswith(version):
        raise LookupError(f"vyper {got} on PATH, item needs {version}")
    out = run([exe, "-f", "bytecode_runtime", item["entry"]], cwd=root).strip()
    return bytes.fromhex(out.removeprefix("0x")), [], False


def mainnet_code(chain: int, address: str, rpc: str, allow_fetch: bool) -> bytes:
    path = CODE_DIR / f"{chain}-{address.lower()}.hex"
    if not path.exists():
        if not allow_fetch:
            raise LookupError(f"{path.name} not cached (run with --fetch)")
        body = json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [address, "latest"]}
        ).encode()
        req = urllib.request.Request(
            rpc, body, {"content-type": "application/json", "user-agent": "eastsea-fidelity/1"}
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            code = json.load(resp)["result"]
        CODE_DIR.mkdir(parents=True, exist_ok=True)
        path.write_text(code.removeprefix("0x") + "\n")
    return bytes.fromhex(path.read_text().strip())


def metadata_ranges(code: bytes) -> list[tuple[int, int]]:
    """Hash ranges of every CBOR metadata blob, embedded ones included."""
    ranges = []
    for prefix, hash_len in METADATA_PREFIXES:
        start = 0
        while (i := code.find(prefix, start)) != -1:
            ranges.append((i + len(prefix), hash_len))
            start = i + 1
    return ranges


def masked(code: bytes, ranges: list[tuple[int, int]]) -> bytes:
    buf = bytearray(code)
    for start, length in ranges:
        buf[start:start + length] = b"\x00" * min(length, max(0, len(buf) - start))
    return bytes(buf)


def first_diff(a: bytes, b: bytes) -> int:
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return i
    return min(len(a), len(b))


# --------------------------------------------------------------------------- #
#                                    check                                     #
# --------------------------------------------------------------------------- #


def check(path: Path, rpc: str, allow_fetch: bool) -> Result:
    item = json.loads(path.read_text())
    name = path.stem
    mainnet = item.get("mainnet")
    if not mainnet:
        return Result(name, "NOT_COMPARABLE", "no mainnet instance")
    try:
        root = fetch_repo(item["repo"], item["commit"], allow_fetch, bool(item.get("submodules")))
        if "vyper" in item["compiler"]:
            built, masks, is_lib = compile_vyper(item, root)
        else:
            built, masks, is_lib = compile_solc(item, root)
        live = mainnet_code(int(mainnet.get("chainId", 1)), mainnet["address"], rpc, allow_fetch)
    except (LookupError, RuntimeError, OSError, KeyError, ValueError) as err:
        return Result(name, "NOT_COMPARABLE", str(err))

    sizes = {"built": len(built), "mainnet": len(live)}
    if not live:
        return Result(name, "NOT_COMPARABLE", "no code at the mainnet address", sizes)
    if built == live:
        return Result(name, "MATCH", "byte-identical", sizes)
    if len(built) != len(live):
        off = first_diff(built, live)
        return Result(
            name, "MISMATCH", f"length {len(built)} vs mainnet {len(live)}; first diff at byte {off}", sizes
        )
    if is_lib:
        masks = masks + [(1, 20)]
    meta = metadata_ranges(built) + metadata_ranges(live)
    if masked(built, meta) == masked(live, meta):
        return Result(name, "MATCH (modulo metadata)", f"{len(metadata_ranges(built))} metadata hash(es) masked", sizes)
    if masks and masked(built, masks + meta) == masked(live, masks + meta):
        return Result(
            name, "MATCH (modulo immutables)", f"{len(masks)} immutable/link range(s) masked", sizes
        )
    off = first_diff(masked(built, masks + meta), masked(live, masks + meta))
    return Result(name, "MISMATCH", f"same length; first diff at byte {off} after masking", sizes)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("items", nargs="*", help="item file stems (default: all)")
    ap.add_argument("--fetch", action="store_true", help="allow git fetch and eth_getCode")
    ap.add_argument("--rpc", default=os.environ.get("ETH_RPC_URL", DEFAULT_RPC))
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    paths = sorted(ITEMS_DIR.glob("*.json"))
    if args.items:
        paths = [p for p in paths if p.stem in set(args.items)]
        missing = set(args.items) - {p.stem for p in paths}
        if missing:
            print(f"unknown item(s): {', '.join(sorted(missing))}", file=sys.stderr)
            return 2
    results = [check(p, args.rpc, args.fetch) for p in paths]

    if args.json:
        print(json.dumps([r.__dict__ for r in results], indent=2))
    else:
        width = max((len(r.item) for r in results), default=4)
        for r in results:
            print(f"{r.item:<{width}}  {r.verdict:<26}  {r.detail}")
    return 1 if any(r.verdict == "MISMATCH" for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
