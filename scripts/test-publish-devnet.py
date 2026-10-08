#!/usr/bin/env python3
"""Deploy all toolbox apps and smoke their bundles on an isolated owned devnet.

Uses an existing Aether binary and public P-256 development accounts. Four node
processes communicate only over loopback and write only to workspace tmp/. The
registry and names contracts are explicitly pending-interface test fixtures;
aether_appBundle is explicitly stubbed until its upstream protocol exists.
Neither these fixtures nor a passing test prove native registry/content rollout.

Examples:
  python3 scripts/test-publish-devnet.py --build-fixtures
  python3 scripts/test-publish-devnet.py --fixture-artifacts ./tmp/fixture-project/out

Fixture compilation is opt-in and always goes through the shared compile gate.
No toolbox/node build is started: source-verified cached artifacts are reused.
"""

import argparse
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_AETHER = "/Volumes/workspace/aether-node/.claude/worktrees/lead/target/release/aether"
COMPILE_GATE = pathlib.Path.home() / ".claude/playbooks/aether-team/wait-compile.sh"
CONTRACTS = (
    "FixedSupplyToken", "OnchainNFT", "Editions1155", "FixedPriceMarket", "AmmFactory", "AmmRouter",
    "BondingLaunchpad", "RewardDistributor", "TokenTimeLock", "LinearVesting", "SimpleMultisig",
    "MilestoneEscrow", "SubscriptionManager", "SimpleDAO", "AllOrNothingCrowdfund", "MerkleAirdrop",
    "CommitRevealRaffle", "NameGatedDrop", "InvoiceBook", "AgentVending",
)


def run(command, **kwargs):
    result = subprocess.run([str(value) for value in command], cwd=ROOT, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{shlex.join(str(value) for value in command[:3])}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def rpc(url, method, params=None):
    req = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as response:
        reply = json.load(response)
    if reply.get("error"):
        raise RuntimeError(f"{method}: {reply['error']}")
    return reply.get("result")


def json_write(file, value):
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def canonical(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()


def sha256(value):
    return "0x" + hashlib.sha256(value).hexdigest()


def verify_artifacts(directory, cast):
    """Every reused artifact's source must match its Solidity metadata exactly."""
    sources, dependency_roots = {}, {}
    for contract in CONTRACTS:
        artifact = directory / f"{contract}.sol" / f"{contract}.json"
        data = json.loads(artifact.read_text())
        metadata = data.get("metadata") or json.loads(data.get("rawMetadata", "{}"))
        if not metadata.get("sources"):
            raise RuntimeError(f"cached artifact has no source provenance: {artifact}")
        if not re.fullmatch(r"(?:0x)?[0-9a-fA-F]+", data.get("bytecode", {}).get("object", "")):
            raise RuntimeError(f"cached artifact has empty/unlinked bytecode: {artifact}")
        for relative, info in metadata["sources"].items():
            if relative in sources and sources[relative] != info["keccak256"]:
                raise RuntimeError(f"cached artifacts disagree on source content: {relative}")
            sources[relative] = info["keccak256"]
    for relative, expected in sorted(sources.items()):
        source = ROOT / "contracts" / relative
        # Git worktrees do not populate submodules automatically. Reuse the
        # original checkout's already-installed dependency only when its clean
        # HEAD exactly matches this worktree's pinned gitlink; never download it.
        parts = pathlib.PurePosixPath(relative).parts
        if not source.is_file() and len(parts) > 2 and parts[0] == "lib":
            dependency = pathlib.Path(*parts[:2])
            if dependency not in dependency_roots:
                pinned = run(["git", "-C", ROOT, "ls-tree", "HEAD", pathlib.Path("contracts") / dependency])
                match = re.fullmatch(r"160000 commit ([0-9a-f]{40})\t.+", pinned)
                checkout = directory.parent / dependency
                if not match or not checkout.is_dir() or run(["git", "-C", checkout, "rev-parse", "HEAD"]) != match.group(1):
                    raise RuntimeError(f"cached artifact dependency does not match the worktree gitlink: {dependency}")
                if run(["git", "-C", checkout, "status", "--porcelain", "--untracked-files=no", "--", parts[2]]):
                    raise RuntimeError(f"cached artifact dependency source has uncommitted edits: {checkout}")
                dependency_roots[dependency] = checkout
            source = dependency_roots[dependency] / pathlib.Path(*parts[2:])
        if not source.is_file():
            raise RuntimeError(f"cached artifact dependency is unavailable in worktree: {source}")
        actual = run([cast, "keccak"], input="0x" + source.read_bytes().hex())
        if actual.lower() != expected.lower():
            raise RuntimeError(f"cached artifact differs from current source: {source}")
    print(f"Verified {len(CONTRACTS)} cached creation artifacts against {len(sources)} exact source hashes", flush=True)
    return len(sources)


def fixture_artifacts(args, run_dir):
    source = ROOT / "tests/fixtures/PublishSystemFixtures.sol"
    if args.fixture_artifacts:
        directory = pathlib.Path(args.fixture_artifacts).resolve()
    elif args.build_fixtures:
        project = run_dir / "fixture-project"
        (project / "src").mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, project / "src/PublishSystemFixtures.sol")
        (project / "foundry.toml").write_text('[profile.default]\nsrc="src"\nout="out"\ncache_path="cache"\n'
                                           'solc_version="0.8.24"\nevm_version="paris"\noptimizer=true\noptimizer_runs=200\n')
        if not COMPILE_GATE.is_file():
            raise RuntimeError(f"shared compile gate is missing: {COMPILE_GATE}")
        print("Waiting for the shared compile gate before compiling the two interface fixtures", flush=True)
        subprocess.run(["bash", str(COMPILE_GATE)], cwd=ROOT, check=True)
        print(run([args.forge, "build", "--root", project, "--offline"]), flush=True)
        directory = project / "out"
    else:
        raise RuntimeError("use --fixture-artifacts DIR or explicitly opt into --build-fixtures")
    fixture_hash = run([args.cast, "keccak"], input="0x" + source.read_bytes().hex())
    for contract in ("PublishRegistryFixture", "PublishNamesFixture"):
        artifact = directory / "PublishSystemFixtures.sol" / f"{contract}.json"
        metadata = json.loads(artifact.read_text()).get("metadata", {})
        hashes = {info["keccak256"] for info in metadata.get("sources", {}).values()}
        if hashes != {fixture_hash}:
            raise RuntimeError(f"fixture artifact does not match the reviewed fixture source: {artifact}")
    return directory


def choose_ports():
    sockets = []
    try:
        for _ in range(8):
            item = socket.socket()
            item.bind(("127.0.0.1", 0))
            sockets.append(item)
        ports = [item.getsockname()[1] for item in sockets]
    finally:
        for item in sockets:
            item.close()
    return ports[:4], ports[4:]


def start_devnet(args, run_dir):
    p2p, ports = choose_ports()
    processes, logs = [], []
    try:
        for index in range(4):
            data = run_dir / "nodes" / str(index + 1)
            data.mkdir(parents=True, exist_ok=True)
            stream = (data / "node.log").open("a")
            logs.append(stream)
            peers = ",".join(f"{other + 1}@127.0.0.1:{p2p[other]}" for other in range(4) if other != index)
            command = [args.aether, "node", "--index", str(index + 1), "--validators", "4",
                       "--port", str(p2p[index]), "--rpc-port", str(ports[index]), "--data", str(data),
                       "--peers", peers, "--offline", "--block-time-ms", "500",
                       "--prover-max-memory", "0", "--prover-threads", "1", "--max-memory", "128M",
                       "--min-free-disk", "0"]
            processes.append(subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=stream))
        url = f"http://127.0.0.1:{ports[0]}"
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if any(process.poll() is not None for process in processes):
                raise RuntimeError("owned devnet process exited during startup; inspect nodes/*/node.log")
            try:
                if int(rpc(url, "eth_chainId"), 16) != 7777:
                    raise RuntimeError("owned devnet unexpectedly uses another chain")
                if int(rpc(url, "eth_blockNumber"), 16) > 0:
                    print(f"Owned offline devnet ready at {url}; data: {run_dir / 'nodes'}", flush=True)
                    return url, processes, logs
            except OSError:
                pass
            time.sleep(0.5)
        raise RuntimeError("owned devnet did not finalize a block; inspect nodes/*/node.log")
    except BaseException:
        stop_devnet(processes, logs)
        raise


def stop_devnet(processes, logs):
    for process in processes:
        if process.poll() is None:
            process.terminate()
    for process in processes:
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
    for stream in logs:
        stream.close()


def wallet_request(wallet_command, method, params=None):
    return json.loads(run(wallet_command, input=json.dumps({"method": method, "params": params or []}), timeout=120))


def deploy_fixture(wallet_command, rpc_url, artifact_dir, contract, args, cast):
    artifact = json.loads((artifact_dir / "PublishSystemFixtures.sol" / f"{contract}.json").read_text())
    code = artifact["bytecode"]["object"]
    if not code.startswith("0x"):
        code = "0x" + code
    if args:
        code += run([cast, "abi-encode", "f(string,address)", *args])[2:]
    hash_ = wallet_request(wallet_command, "eth_sendTransaction", [{"from": wallet_request(wallet_command, "eth_accounts")[0], "data": code}])
    receipt = rpc(rpc_url, "aether_getReceipt", [hash_])["receipt"]
    if not receipt["success"] or not receipt.get("contract_address"):
        raise RuntimeError(f"fixture deployment failed: {contract}")
    return receipt["contract_address"]


def decode_string(data):
    raw = bytes.fromhex(data[2:])
    offset = int.from_bytes(raw[:32], "big")
    length = int.from_bytes(raw[offset:offset + 32], "big")
    return raw[offset + 32:offset + 32 + length].decode()


def verify_published(args, url, output, sender, registry, names):
    state = json.loads((output / "state.json").read_text())
    expected_slugs = sorted(path.parent.name for path in (ROOT / "examples").glob("*/manifest.json"))
    if set(state["apps"]) != set(expected_slugs) or len(expected_slugs) != 17:
        raise RuntimeError("publisher did not deploy/register exactly all 17 examples")
    manifests, summaries = {}, []

    def call(target, signature, *values):
        data = run([args.cast, "calldata", signature, *map(str, values)])
        return rpc(url, "eth_call", [{"from": sender, "to": target, "data": data}, "latest"])

    for slug in expected_slugs:
        manifest_file = output / "examples" / slug / "manifest.json"
        encoded = manifest_file.read_bytes()
        manifest = json.loads(encoded)
        manifests[slug] = manifest
        app = state["apps"][slug]
        if not app.get("registered") or app.get("bundle_status") != "stub-content-pending":
            raise RuntimeError(f"registration or explicit content-pending status missing: {slug}")
        for contract in manifest["contracts"]:
            if not re.fullmatch(r"0x[0-9a-fA-F]{40}", contract["address"]) or int(contract["address"], 16) == 0:
                raise RuntimeError(f"unfilled contract placeholder: {slug} {contract['label']}")
            if rpc(url, "eth_getCode", [contract["address"], "latest"]) == "0x":
                raise RuntimeError(f"deployed contract has no code: {slug} {contract['label']}")
        bundle = output / "bundles" / slug
        files = []
        for file in sorted((file for file in bundle.rglob("*") if file.is_file()), key=lambda item: item.relative_to(bundle).as_posix().encode()):
            if file.is_symlink():
                raise RuntimeError("published bundle contains a symlink")
            contents = file.read_bytes()
            files.append({"path": file.relative_to(bundle).as_posix(), "sha256": hashlib.sha256(contents).hexdigest(), "size": len(contents)})
        index = canonical({"format": "eastsea-bundle/1", "files": files})
        if (output / "bundles" / f"{slug}.index.json").read_bytes() != index:
            raise RuntimeError(f"bundle index is not the canonical deterministic index: {slug}")
        if manifest["bundle"] != {"format": "eastsea-bundle/1", "sha256": sha256(index), "size": sum(file["size"] for file in files), "files": len(files)}:
            raise RuntimeError(f"bundle hashes/count/size did not verify: {slug}")
        runtime = json.loads((bundle / "manifest.json").read_bytes())
        if runtime["contracts"] != manifest["contracts"] or runtime["x-toolbox-chain-id"] != "0x1e61":
            raise RuntimeError(f"runtime address/chain manifest differs: {slug}")
        encoded_id = run([args.cast, "abi-encode", "f(address,string)", sender, slug])
        expected_id = run([args.cast, "keccak", encoded_id])
        if manifest["app_id"] != expected_id:
            raise RuntimeError(f"app id is not scoped to the selected publisher: {slug}")
        record = call(registry, "appOf(bytes32)", expected_id)[2:]
        words = [record[index:index + 64] for index in range(0, len(record), 64)]
        if len(words) != 14 or "0x" + words[0][-40:] != sender.lower() or int(words[3], 16) != 1:
            raise RuntimeError(f"onchain registry owner/sequence does not verify: {slug}")
        if "0x" + words[4] != sha256(encoded) or "0x" + words[5] != sha256(index):
            raise RuntimeError(f"onchain registration did not bind exact manifest/bundle hashes: {slug}")
        host = f"{slug}.smokepublisher.sea"
        node = call(names, "nodeFor(string)", host)
        owner = "0x" + call(names, "ownerOf(bytes32)", node)[-40:]
        binding = decode_string(call(names, "textOf(bytes32,string)", node, "app"))
        if owner.lower() != sender.lower() or binding != expected_id or app["sea_url"] != f"sea://{host}/":
            raise RuntimeError(f"owned subdomain or app binding did not verify: {slug}")
        summaries.append({"app": slug, "app_id": expected_id, "contracts": app["contracts"], "sea_url": app["sea_url"],
                          "bundle_sha256": sha256(index), "manifest_sha256": sha256(encoded)})
    return state, manifests, summaries


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--aether", default=DEFAULT_AETHER)
    parser.add_argument("--artifacts", type=pathlib.Path)
    parser.add_argument("--fixture-artifacts", type=pathlib.Path)
    parser.add_argument("--build-fixtures", action="store_true")
    parser.add_argument("--run-dir", type=pathlib.Path)
    parser.add_argument("--forge", default=shutil.which("forge") or "forge")
    parser.add_argument("--cast", default=shutil.which("cast") or "cast")
    parser.add_argument("--node", default=shutil.which("node") or "node")
    parser.add_argument("--chrome", help="optional headless Chrome executable; otherwise Playwright's cached Chromium")
    parser.add_argument("--no-smoke", action="store_true", help="diagnostic deployment-only run; not full verification")
    args = parser.parse_args()
    (ROOT / "tmp").mkdir(exist_ok=True)
    run_dir = args.run_dir.resolve() if args.run_dir else pathlib.Path(tempfile.mkdtemp(prefix="publish-devnet-", dir=ROOT / "tmp"))
    if not run_dir.is_relative_to((ROOT / "tmp").resolve()):
        parser.error("--run-dir must stay under this workspace's tmp/")
    run_dir.mkdir(parents=True, exist_ok=True)
    runtime = run_dir / "runtime"
    runtime.mkdir(exist_ok=True)
    os.environ.update(TMPDIR=str(runtime), TMP=str(runtime), TEMP=str(runtime), PYTHONPYCACHEPREFIX=str(run_dir / "pycache"))
    if not pathlib.Path(args.aether).is_file() or not os.access(args.aether, os.X_OK):
        parser.error(f"existing Aether binary is missing/not executable: {args.aether}")
    artifacts = (args.artifacts or (ROOT / "contracts/out")).resolve()
    if not artifacts.exists() and not args.artifacts:
        artifacts = pathlib.Path("/Volumes/workspace/eastsea-toolbox/contracts/out")
    processes, logs = [], []
    report = {"scope": "owned offline devnet only", "run_dir": str(run_dir),
              "registry": "pending-interface onchain fixture; native implementation unavailable",
              "names": "pending-subdomain onchain fixture; native implementation unavailable",
              "content": "explicit stub; native aether_appBundle protocol unavailable", "passed": False}
    try:
        report["source_hashes_verified"] = verify_artifacts(artifacts, args.cast)
        fixtures = fixture_artifacts(args, run_dir)
        url, processes, logs = start_devnet(args, run_dir)
        report["node_status"] = rpc(url, "aether_status")
        report["b5_state_quote_advertised"] = "state" in report["node_status"].get("base_fee", {})
        with pathlib.Path(args.aether).open("rb") as binary:
            report["aether_binary_sha256"] = hashlib.file_digest(binary, "sha256").hexdigest()
        marker = run_dir / "owned-devnet.json"
        json_write(marker, {"kind": "toolbox-owned-devnet", "rpc": url, "chain_id": 7777,
                            "process_ids": [process.pid for process in processes]})
        wallet_command = [sys.executable, str(ROOT / "scripts/devnet-wallet.py"), "--aether", args.aether, "--rpc", url,
                          "--owned-marker", str(marker), "--audit-log", str(run_dir / "wallet-transactions.jsonl")]
        sender = wallet_request(wallet_command, "eth_accounts")[0].lower()
        output = run_dir / "published"
        systems_file = run_dir / "systems.json"
        if systems_file.is_file():
            systems = json.loads(systems_file.read_text())
            registry, names = systems["registry"], systems["names"]
        else:
            registry = deploy_fixture(wallet_command, url, fixtures, "PublishRegistryFixture", [], args.cast)
            names = deploy_fixture(wallet_command, url, fixtures, "PublishNamesFixture", ["smokepublisher", sender], args.cast)
            json_write(systems_file, {"registry": registry, "names": names})
        command = [sys.executable, ROOT / "scripts/publish.py", "--rpc", url, "--from", sender, "--name", "smokepublisher",
                   "--registry", registry, "--names", names, "--artifacts", artifacts, "--output", output,
                   "--wallet-command", shlex.join(wallet_command), "--bundle-mode", "stub", "--cast", args.cast]
        nonce_before = rpc(url, "eth_getTransactionCount", [sender, "latest"])
        dryrun = run([*command, "--dry-run"])
        (run_dir / "dry-run.log").write_text(dryrun + "\n")
        if rpc(url, "eth_getTransactionCount", [sender, "latest"]) != nonce_before:
            raise RuntimeError("dry-run sent a transaction")
        print("Dry-run verified: no account nonce change", flush=True)
        with (run_dir / "publisher.log").open("w") as log:
            result = subprocess.run([str(value) for value in command], cwd=ROOT, stdout=log, stderr=log)
        if result.returncode:
            raise RuntimeError(f"publisher failed; inspect {run_dir / 'publisher.log'}")
        state, manifests, summaries = verify_published(args, url, output, sender, registry, names)
        nonce_before = rpc(url, "eth_getTransactionCount", [sender, "latest"])
        snapshot = {slug: (output / "examples" / slug / "manifest.json").read_bytes() for slug in manifests}
        with (run_dir / "publisher-rerun.log").open("w") as log:
            result = subprocess.run([str(value) for value in command], cwd=ROOT, stdout=log, stderr=log)
        if result.returncode:
            raise RuntimeError(f"idempotent rerun failed; inspect {run_dir / 'publisher-rerun.log'}")
        rerun, _, _ = verify_published(args, url, output, sender, registry, names)
        if rpc(url, "eth_getTransactionCount", [sender, "latest"]) != nonce_before or state["contracts"] != rerun["contracts"]:
            raise RuntimeError("idempotent rerun redeployed or changed account nonce")
        if any((output / "examples" / slug / "manifest.json").read_bytes() != previous for slug, previous in snapshot.items()):
            raise RuntimeError("idempotent rerun changed deterministic manifest bytes")
        report.update(dry_run=True, idempotent=True, bundles_verified=True, apps=summaries)
        print("Verified 17 real app deployments, fixture registrations, owned subdomains and deterministic bundles; rerun sent no transactions", flush=True)
        if not args.no_smoke:
            accounts = run([args.aether, "dev-accounts"])
            other = re.search(r"^dev\s+2\s+(0x[0-9a-fA-F]{40})$", accounts, re.M).group(1)
            smoke_config = run_dir / "smoke-config.json"
            json_write(smoke_config, {"run_dir": str(run_dir), "rpc": url, "wallet_command": wallet_command,
                                     "from": sender, "other": other, "bundles": str(output / "bundles"),
                                     "manifests": manifests, "cast": args.cast, "chrome": args.chrome})
            result = subprocess.run([args.node, str(ROOT / "scripts/smoke-published-apps.mjs"), "--config", str(smoke_config)], cwd=ROOT)
            if result.returncode:
                raise RuntimeError(f"frontend smoke failed; inspect {run_dir / 'frontend-smoke.json'}")
            report["frontend_smoke"] = True
        report["passed"] = not args.no_smoke
        print(f"Evidence: {run_dir / 'integration-report.json'}", flush=True)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        report["error"] = str(exc)
        print(f"test-publish-devnet: {exc}", file=sys.stderr)
        return 1
    finally:
        stop_devnet(processes, logs)
        json_write(run_dir / "integration-report.json", report)


if __name__ == "__main__":
    sys.exit(main())
