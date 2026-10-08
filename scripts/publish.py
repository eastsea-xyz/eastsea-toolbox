#!/usr/bin/env python3
"""Publish toolbox copies with a caller-owned EIP-1193 wallet; never handles keys."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import struct
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
import zlib

ROOT = Path(__file__).resolve().parent.parent
ZERO = "0x" + "0" * 40
ZERO_HASH = "0x" + "0" * 64
SLUGS = tuple(sorted(p.parent.name for p in (ROOT / "examples").glob("*/manifest.json")))
PRIMARY = {"token": "IslandCoin token", "nft": "Editions1155 sales", "lock": "LinearVesting"}
DEPENDENCIES = {"amm", "launchpad", "rewards", "lock", "dao"}
APP_ARTIFACTS = {
    "token": ("FixedSupplyToken",), "nft": ("OnchainNFT", "Editions1155"),
    "market": ("FixedPriceMarket",), "amm": ("AmmFactory", "AmmRouter"),
    "launchpad": ("BondingLaunchpad", "AmmFactory"), "rewards": ("RewardDistributor",),
    "lock": ("TokenTimeLock", "LinearVesting"), "multisig": ("SimpleMultisig",),
    "escrow": ("MilestoneEscrow",), "subscription": ("SubscriptionManager",),
    "dao": ("SimpleDAO",), "crowdfund": ("AllOrNothingCrowdfund",),
    "airdrop": ("MerkleAirdrop",), "raffle": ("CommitRevealRaffle",),
    "names": ("NameGatedDrop",), "invoice": ("InvoiceBook",), "vending": ("AgentVending",),
}


class PublishError(Exception):
    pass


class RpcError(PublishError):
    def __init__(self, error):
        self.code = error.get("code") if isinstance(error, dict) else None
        super().__init__(str(error))


class TransactionFailed(PublishError):
    pass


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def sha256(data):
    return "0x" + hashlib.sha256(data).hexdigest()


def address(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", str(value)) or value.lower() == ZERO:
        raise PublishError(f"Expected a nonzero 20-byte address: {value}")
    return value.lower()


def root_name(value):
    value = str(value).lower().removesuffix(".sea")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,30}[a-z0-9]", value) or value[2:4] == "--":
        raise PublishError("NAME must be your owned root label (3–32 lowercase characters), optionally ending .sea")
    return value


def selected(value):
    result = list(SLUGS) if value == "all" else value.split(",")
    if not result or len(set(result)) != len(result) or any(s not in SLUGS for s in result):
        raise PublishError(f"Select unique slugs from: {', '.join(SLUGS)}")
    return result


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    pending = path.with_suffix(path.suffix + ".pending")
    pending.write_bytes(canonical(value) + b"\n")
    pending.replace(path)


class Rpc:
    def __init__(self, url, timeout=30):
        parsed = urlsplit(url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
            raise PublishError("RPC must be an http(s) endpoint without embedded credentials")
        self.url, self.timeout = url, timeout

    def request(self, method, params=None):
        body = canonical({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []})
        try:
            with urlopen(Request(self.url, data=body, headers={"Content-Type": "application/json"}), timeout=self.timeout) as response:
                reply = json.load(response)
        except (HTTPError, URLError, TimeoutError, ValueError) as error:
            raise PublishError(f"RPC {method} failed: {error}") from error
        if "error" in reply:
            raise RpcError(reply["error"])
        if "result" not in reply:
            raise PublishError(f"RPC {method} returned no result")
        return reply["result"]


class Wallet:
    """A command or wallet RPC owns signing, account policy and B5 fee estimation."""

    def __init__(self, command=None, url=None, sender=None, chain=None, timeout=300):
        if command and url:
            raise PublishError("Choose WALLET_COMMAND/--wallet-command or --wallet-rpc")
        self.command = shlex.split(command) if command else None
        self.rpc = Rpc(url) if url else None
        self.browser = None
        self.browser_settings = (sender, chain, timeout) if not command and not url else None

    def close(self):
        if self.browser:
            self.browser.close()

    def request(self, method, params=None):
        if self.browser_settings:
            from wallet_bridge import BrowserWallet
            if not self.browser:
                self.browser = BrowserWallet(*self.browser_settings)
            try:
                return self.browser.request(method, params)
            except RuntimeError as error:
                if getattr(error, "code", None) in {4001, 4100, 4200, -32601, -32602}:
                    raise RpcError({"code": error.code, "message": str(error)}) from error
                raise PublishError(str(error)) from error
        if self.rpc:
            return self.rpc.request(method, params)
        task_tmp = ROOT / "tmp"
        task_tmp.mkdir(exist_ok=True)
        env = dict(os.environ, TMPDIR=str(task_tmp))
        try:
            result = subprocess.run(self.command, input=canonical({"method": method, "params": params or []}).decode(),
                                    capture_output=True, text=True, check=False, env=env)
        except OSError as error:
            raise PublishError(f"Wallet command could not run: {error}") from error
        if result.returncode:
            raise PublishError("Wallet rejected the request; inspect your wallet's output/policy")
        try:
            reply = json.loads(result.stdout)
        except ValueError as error:
            raise PublishError("Wallet command must return one JSON EIP-1193 result on stdout") from error
        if isinstance(reply, dict) and "error" in reply:
            raise RpcError(reply["error"])
        return reply["result"] if isinstance(reply, dict) and "result" in reply else reply


class Abi:
    def __init__(self, binary="cast"):
        self.binary = binary

    def run(self, *args):
        try:
            result = subprocess.run([self.binary, *map(str, args)], capture_output=True, text=True, check=False)
        except OSError as error:
            raise PublishError("Foundry cast is required for ABI encoding (no Ethereum signing is used)") from error
        if result.returncode:
            raise PublishError(f"cast {args[0]} failed: {result.stderr.strip()}")
        return result.stdout.strip()

    def encode(self, signature, *args):
        return self.run("abi-encode", signature, *args)

    def call(self, signature, *args):
        return self.run("calldata", signature, *args)

    def keccak(self, data):
        return self.run("keccak", "0x" + data.hex())


def words(data):
    if not isinstance(data, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{64})*", data):
        raise PublishError("Contract returned invalid ABI data")
    return [data[n:n + 64].lower() for n in range(2, len(data), 64)]


def abi_string(data):
    raw = bytes.fromhex(data.removeprefix("0x"))
    if len(raw) < 64:
        raise PublishError("Contract returned no ABI string")
    offset = int.from_bytes(raw[:32], "big")
    if offset + 32 > len(raw):
        raise PublishError("Invalid ABI string offset")
    size = int.from_bytes(raw[offset:offset + 32], "big")
    if offset + 32 + size > len(raw):
        raise PublishError("Truncated ABI string")
    return raw[offset + 32:offset + 32 + size].decode("utf-8")


def bundle_index(directory):
    """Design 31 §4 compact JSON, path-byte sorted, without timestamps or modes."""
    entries, total, seen = [], 0, set()
    for file in sorted(directory.rglob("*"), key=lambda p: p.relative_to(directory).as_posix().encode()):
        if file.is_symlink():
            raise PublishError(f"Bundle symlinks are not allowed: {file}")
        if file.is_dir():
            continue
        path = file.relative_to(directory).as_posix()
        if (not re.fullmatch(r"[A-Za-z0-9._/-]{1,200}", path) or path.lower() in seen
                or any(part in {"", ".", ".."} for part in path.split("/"))
                or file.suffix.lower() not in {".html", ".js", ".mjs", ".css", ".json", ".svg", ".png", ".jpg", ".webp", ".ico", ".woff2", ".txt"}):
            raise PublishError(f"Unsafe or case-duplicate bundle path: {path}")
        seen.add(path.lower())
        data = file.read_bytes()
        if len(data) > 10 * 1024 * 1024:
            raise PublishError(f"Bundle file exceeds 10 MiB: {path}")
        total += len(data)
        entries.append({"path": path, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
    if not entries or len(entries) > 2000 or total > 25 * 1024 * 1024:
        raise PublishError("Bundle must have 1–2000 files and at most 25 MiB")
    return canonical({"format": "eastsea-bundle/1", "files": entries})


def icon_png():
    """Deterministic 512px solid PNG; no image/build dependency."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = (b"\0" + bytes((18, 50, 67)) * 512) * 512
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 512, 512, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels, 9)) + chunk(b"IEND", b""))


def normalize_receipt(reply):
    if not reply:
        return None
    if reply.get("dropped") or reply.get("status") == "dropped":
        raise TransactionFailed("Transaction was dropped; inspect the wallet before retrying")
    if "receipt" in reply:
        receipt = reply["receipt"]
        return {"success": receipt.get("success"), "contractAddress": receipt.get("contract_address")}
    if reply.get("status") in {"0x0", "0x1"}:
        return {"success": int(reply["status"], 16) == 1, "contractAddress": reply.get("contractAddress")}
    return None


class Publisher:
    def __init__(self, args, rpc=None, wallet=None, abi=None):
        self.args = args
        self.rpc = rpc or Rpc(args.rpc)
        self.abi = abi or Abi(args.cast)
        self.sender = address(args.sender)
        self.names, self.registry = address(args.names), address(args.registry)
        self.chain = hex(int(self.rpc.request("eth_chainId"), 16))
        if int(self.chain, 16) not in args.test_chain_ids:
            raise PublishError(f"Chain {self.chain} is not an explicitly configured test chain; use --test-chain-id for an owned devnet/testnet")
        self.wallet = wallet or Wallet(args.wallet_command, args.wallet_rpc, self.sender, self.chain, args.wallet_timeout)
        self.name = root_name(args.name or abi_string(self.read(self.names, "reverseOf(address)", self.sender)))
        default_output = ROOT / "tmp" / "publish-testnet" / f"{self.chain}-{self.sender[2:]}-{self.name}"
        self.output = Path(args.output or default_output).resolve()
        if self.output == ROOT or ROOT in self.output.parents and self.output.parts[len(ROOT.parts)] in {"apps", "examples", "contracts", "scripts"}:
            raise PublishError("Output must be isolated from repository source files")
        self.output.mkdir(parents=True, exist_ok=True)
        self.state_file = self.output / "state.json"
        self.state = json.loads(self.state_file.read_text()) if self.state_file.exists() else {
            "schema": "toolbox-publish-state/1", "chain_id": self.chain, "from": self.sender,
            "name": self.name, "registry": self.registry, "names": self.names, "transactions": {}, "contracts": {}, "apps": {},
        }
        for key, expected in (("chain_id", self.chain), ("from", self.sender), ("name", self.name), ("registry", self.registry), ("names", self.names)):
            if self.state.get(key) != expected:
                raise PublishError(f"Output state belongs to a different {key}; choose another --output")
        self.artifact_cache = {}
        self.source_hashes = {}
        self.library_roots = {}
        self.lock = None

    def save(self):
        atomic_json(self.state_file, self.state)

    def read(self, target, signature, *args):
        return self.rpc.request("eth_call", [{"from": self.sender, "to": target, "data": self.abi.call(signature, *args)}, "latest"])

    def code(self, target):
        result = self.rpc.request("eth_getCode", [target, "latest"])
        if not result or result in {"0x", "0x0"}:
            raise PublishError(f"No contract code at {target}")
        return result

    def preflight(self):
        accounts = self.wallet.request("eth_accounts")
        if not isinstance(accounts, list) or self.sender not in [a.lower() for a in accounts]:
            raise PublishError("FROM is not an account exposed by your wallet; connect/authorize it first")
        wallet_chain = self.wallet.request("eth_chainId")
        if int(wallet_chain, 16) != int(self.chain, 16):
            raise PublishError("Wallet and node are on different chains")
        self.code(self.names)
        self.code(self.registry)
        node = words(self.read(self.names, "nodeFor(string)", self.name + ".sea"))
        if len(node) != 1:
            raise PublishError("Names service does not implement nodeFor(string)")
        owner = words(self.read(self.names, "ownerOf(bytes32)", "0x" + node[0]))
        if not owner or "0x" + owner[0][-40:] != self.sender:
            raise PublishError(f"FROM must own the live root name {self.name}.sea before publishing")
        try:
            binding = abi_string(self.read(self.names, "textOf(bytes32,string)", "0x" + node[0], "app"))
            # Simulate an unchanged value, so a root with four text keys is valid.
            self.read(self.names, "setText(string,string,string)", self.name + ".sea", "app", binding)
        except PublishError as error:
            raise PublishError("Names service does not support the required app text records") from error
        for slug in selected(self.args.apps):
            # Simulate without signing. This also prevents partial deployments on legacy names services.
            host = f"{slug}.{self.name}.sea"
            try:
                child = words(self.read(self.names, "nodeFor(string)", host))
                if len(child) != 1:
                    raise PublishError("Invalid child node")
                child_owner = words(self.read(self.names, "ownerOf(bytes32)", "0x" + child[0]))
                if len(child_owner) != 1 or "0x" + child_owner[0][-40:] not in {ZERO, self.sender}:
                    raise PublishError(f"Subdomain {host} belongs to another account")
                if int(child_owner[0], 16) == 0:
                    self.read(self.names, "createSubdomain(string,address)", host, self.sender)
                app_id = self.app_id(slug)
                if self.read(self.registry, "appIdOf(address,string)", self.sender, slug).lower() != app_id:
                    raise PublishError("Registry appId derivation differs from eastsea-app/1")
                record = words(self.read(self.registry, "appOf(bytes32)", app_id))
                if len(record) < 7:
                    raise PublishError("Invalid registry appOf response")
                if int(record[0], 16) and "0x" + record[0][-40:] != self.sender:
                    raise PublishError("Registry app record belongs to another publisher")
                if int(record[0], 16) == 0:
                    dummy_hash = sha256(b"toolbox-publish-preflight")
                    simulated = self.read(self.registry, "publish(string,bytes32,bytes32,address,string)", slug, dummy_hash, dummy_hash, ZERO, "")
                    if simulated.lower() != app_id:
                        raise PublishError("Registry publish simulation returned a different app id")
            except PublishError as error:
                raise PublishError("Registry/.sea subdomain API is unavailable or rejects this account; install the app-content/sea-names implementation first") from error
        if self.args.bundle_mode == "rpc":
            try:
                capability = self.rpc.request("aether_appBundle", [{"operation": "capabilities"}])
            except RpcError as error:
                raise PublishError("aether_appBundle upload protocol is pending; use --bundle-mode stub to save visibly pending upload requests") from error
            if not isinstance(capability, dict) or capability.get("publish_protocol") != "toolbox-appBundle/1":
                raise PublishError("Node does not advertise toolbox-appBundle/1; adapt the bundle uploader to its published protocol or use --bundle-mode stub")
        required = {name for slug in selected(self.args.apps) for name in APP_ARTIFACTS[slug]}
        if DEPENDENCIES.intersection(selected(self.args.apps)):
            required.add("FixedSupplyToken")
        for contract in sorted(required):
            self.artifact(contract)

    def app_id(self, slug):
        encoded = self.abi.encode("f(address,string)", self.sender, slug)
        return self.abi.keccak(bytes.fromhex(encoded[2:]))

    def receipt(self, tx_hash):
        started = time.monotonic()
        while True:
            try:
                reply = self.rpc.request("eth_getTransactionReceipt", [tx_hash])
            except RpcError as error:
                if error.code != -32601:
                    raise
                reply = self.rpc.request("aether_getReceipt", [tx_hash])
            receipt = normalize_receipt(reply)
            if receipt is not None:
                if receipt["success"] is not True:
                    raise TransactionFailed(f"Transaction reverted: {tx_hash}; explicit --retry-tx required")
                return receipt
            if time.monotonic() - started > self.args.receipt_timeout:
                raise PublishError(f"Receipt still pending: {tx_hash}; rerun with the same output to resume")
            time.sleep(self.args.poll_interval)

    def transact(self, key, data, target=None, value=0):
        tx = {"from": self.sender, "data": data, "value": hex(value)}
        if target:
            tx["to"] = address(target)
        # gas/fee/nonce omitted intentionally: the P-256 wallet estimates all B5 dimensions.
        fingerprint = sha256(canonical(tx))
        previous = self.state["transactions"].get(key)
        if previous:
            if previous["intent"] != fingerprint:
                raise PublishError(f"Transaction intent changed for {key}; choose new output/app slug/version")
            if not previous.get("hash"):
                raise PublishError(f"Submission outcome unknown for {key}; use --recover-tx {key}=0xHASH after checking your wallet (no automatic resend)")
            receipt = self.receipt(previous["hash"])
            previous["status"] = "finalized"
            self.save()
            return receipt
        self.state["transactions"][key] = {"intent": fingerprint, "status": "submitting"}
        self.save()
        try:
            tx_hash = self.wallet.request("eth_sendTransaction", [tx])
        except RpcError as error:
            if error.code in {4001, 4100, 4200, -32601, -32602}:  # Explicit pre-submission refusal.
                del self.state["transactions"][key]
                self.save()
            raise
        if not isinstance(tx_hash, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", tx_hash):
            raise PublishError(f"Wallet returned no valid transaction hash for {key}; inspect wallet before recovery")
        self.state["transactions"][key].update(hash=tx_hash.lower(), status="submitted")
        self.save()
        result = self.receipt(tx_hash)
        self.state["transactions"][key]["status"] = "finalized"
        self.save()
        return result

    def artifact(self, contract):
        if contract not in self.artifact_cache:
            file = Path(self.args.artifacts) / f"{contract}.sol" / f"{contract}.json"
            if not file.is_file():
                raise PublishError(f"Missing artifact {file}; run make publish-build first (or pass --artifacts to source-verified build output)")
            artifact = json.loads(file.read_text())
            bytecode = artifact.get("bytecode", {}).get("object", "")
            if not bytecode.startswith("0x"):
                bytecode = "0x" + bytecode
            if not re.fullmatch(r"0x[0-9a-fA-F]+", bytecode):
                raise PublishError(f"Unlinked/empty creation bytecode: {contract}")
            metadata = artifact.get("metadata") or json.loads(artifact.get("rawMetadata", "{}"))
            if not metadata.get("sources"):
                raise PublishError(f"Artifact has no source provenance: {contract}; rebuild")
            for source, info in metadata.get("sources", {}).items():
                path = Path(source)
                if path.is_absolute() or ".." in path.parts or not re.fullmatch(r"(?:src|lib)/[A-Za-z0-9_./-]+\.sol", source):
                    raise PublishError(f"Unexpected artifact source path: {source}")
                file_source = ROOT / "contracts" / source
                if not file_source.is_file() and source.startswith("lib/"):
                    # A cached checkout may contain the pinned submodule when
                    # the worktree does not; prove its gitlink before reusing it.
                    dependency = Path(*path.parts[:2])
                    libraries = self.__dict__.setdefault("library_roots", {})
                    if dependency not in libraries:
                        checkout = Path(self.args.artifacts).resolve().parent / dependency
                        def git(directory, *arguments):
                            result = subprocess.run(["git", "-C", str(directory), *map(str, arguments)], capture_output=True, text=True)
                            if result.returncode:
                                raise PublishError("Cached dependency provenance could not be verified")
                            return result.stdout.strip()
                        pinned = git(ROOT, "ls-tree", "HEAD", Path("contracts") / dependency)
                        match = re.fullmatch(r"160000 commit ([0-9a-f]{40})\t.+", pinned)
                        if not match or not checkout.is_dir() or git(checkout, "rev-parse", "HEAD") != match.group(1):
                            raise PublishError(f"Cached dependency does not match the pinned submodule: {dependency}")
                        if git(checkout, "status", "--porcelain", "--untracked-files=no", "--", "contracts"):
                            raise PublishError(f"Cached dependency contains source edits: {dependency}")
                        libraries[dependency] = checkout
                    file_source = libraries[dependency] / Path(*path.parts[2:])
                if not file_source.is_file():
                    raise PublishError(f"Artifact source is missing: {source}")
                if source not in self.source_hashes:
                    self.source_hashes[source] = self.abi.keccak(file_source.read_bytes())
                if self.source_hashes[source] != info["keccak256"]:
                    raise PublishError(f"Artifact source differs from this toolbox: {source}; rebuild")
            self.artifact_cache[contract] = bytecode
        return self.artifact_cache[contract]

    def deploy(self, key, contract, signature, *args):
        data = self.artifact(contract) + self.abi.encode(signature, *args)[2:]
        existing = self.state["contracts"].get(key)
        if existing:
            if existing["init_sha256"] != sha256(data.encode()):
                raise PublishError(f"Deployment changed for {key}; choose another output")
            if sha256(self.code(existing["address"]).encode()) != existing["code_sha256"]:
                raise PublishError(f"Deployed code changed for {key}")
            return existing["address"]
        print(f"Deploying {key} ({contract})", file=sys.stderr, flush=True)
        receipt = self.transact("deploy:" + key, data)
        deployed = address(receipt.get("contractAddress"))
        self.state["contracts"][key] = {"address": deployed, "contract": contract,
            "init_sha256": sha256(data.encode()), "code_sha256": sha256(self.code(deployed).encode())}
        self.save()
        return deployed

    def contracts(self, slug):
        sender, amount = self.sender, 10**18
        token = factory = None
        if slug in DEPENDENCIES:
            token = self.deploy("shared.token", "FixedSupplyToken", "f(string,string,uint256,address)", "Toolbox Test Coin", "TEST", 10**24, sender)
        if slug in {"amm", "launchpad"}:
            factory = self.deploy("shared.factory", "AmmFactory", "f(address)", sender)
        recipes = {
            "token": [("IslandCoin token", "FixedSupplyToken", "f(string,string,uint256,address)", ("Island Test Coin", "ISLE", 10**24, sender))],
            "nft": [("OnchainNFT 721", "OnchainNFT", "f(string,string,uint256,uint96,address)", ("Island Folk", "FOLK", 1000, 500, sender)), ("Editions1155 sales", "Editions1155", "f(address)", (sender,))],
            "market": [("FixedPriceMarket", "FixedPriceMarket", "f(address)", (sender,))],
            "rewards": [("RewardDistributor", "RewardDistributor", "f(address,address,address)", (sender, token, token))],
            "multisig": [("SimpleMultisig", "SimpleMultisig", "f(address[],uint256)", (f"[{sender}]", 1))],
            "escrow": [("MilestoneEscrow", "MilestoneEscrow", "f(address)", (sender,))],
            "subscription": [("SubscriptionManager", "SubscriptionManager", "f(address,address,uint256)", (sender, sender, 10**12))],
            "dao": [("SimpleDAO", "SimpleDAO", "f(address,address,uint256,uint48,uint48,uint48)", (sender, token, amount, 3600, 3600, 86400))],
            "crowdfund": [("AllOrNothingCrowdfund", "AllOrNothingCrowdfund", "f(address,address,uint128,uint48)", (sender, sender, 10**19, 86400))],
            "invoice": [("InvoiceBook", "InvoiceBook", "f(address,address)", (sender, sender))],
            "vending": [("AgentVending", "AgentVending", "f(address,address,uint256,uint48)", (sender, sender, 10**15, 3600))],
        }
        if slug == "amm":
            router = self.deploy("amm.AmmRouter", "AmmRouter", "f(address)", factory)
            return {"AmmFactory": factory, "AmmRouter": router}
        if slug == "launchpad":
            cfg = f"(Tide Test Token,TIDE,{10**24},{10**20},{10**22},{10**21},30,0,0,0,{sender})"
            recipes[slug] = [("BondingLaunchpad", "BondingLaunchpad", "f(address,address,address,(string,string,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,address))", (sender, token, factory, cfg))]
        if slug == "lock":
            lock = self.deploy("lock.TokenTimeLock", "TokenTimeLock", "f(address,address)", sender, token)
            # Once a creation was submitted, only its saved receipt may resolve it.
            if "deploy:lock.LinearVesting" not in self.state["transactions"]:
                nonce = int(self.rpc.request("eth_getTransactionCount", [sender, "latest"]), 16)
                def creation_address(at_nonce):
                    predicted = self.abi.run("compute-address", sender, "--nonce", at_nonce)
                    match = re.search(r"0x[0-9a-fA-F]{40}", predicted)
                    if not match:
                        raise PublishError("Could not predict LinearVesting constructor address")
                    return address(match.group())
                expected = self.state.get("lock.vesting-target")
                approved = 0
                if expected:
                    approval_key = "lock.approve:" + expected
                    approval = self.state["transactions"].get(approval_key)
                    if approval and approval.get("status") != "finalized":
                        self.transact(approval_key, self.abi.call("approve(address,uint256)", expected, amount), token)
                        nonce = int(self.rpc.request("eth_getTransactionCount", [sender, "latest"]), 16)
                    approved = int(words(self.read(token, "allowance(address,address)", sender, expected))[0], 16)
                if expected != creation_address(nonce) or approved < amount:
                    # Approval consumes one nonce. A failed CREATE/rejected
                    # approval gets a new target and independently journaled approval.
                    expected = creation_address(nonce + 1)
                    self.state["lock.vesting-target"] = expected
                    self.save()
                    self.transact("lock.approve:" + expected, self.abi.call("approve(address,uint256)", expected, amount), token)
                current = int(self.rpc.request("eth_getTransactionCount", [sender, "latest"]), 16)
                if creation_address(current) != expected:
                    raise PublishError("Wallet nonce changed during vesting approval; stop other account activity and rerun")
            expected = self.state["lock.vesting-target"]
            vest = self.deploy("lock.LinearVesting", "LinearVesting", "f(address,address,uint256,uint256,uint256)", token, sender, amount, 0, 86400)
            if vest != expected:
                raise PublishError("Wallet nonce changed between approval and vesting deployment; use an isolated publishing session")
            return {"TokenTimeLock": lock, "LinearVesting": vest}
        if slug == "airdrop":
            leaf = self.abi.keccak(bytes.fromhex(sender[2:]) + amount.to_bytes(32, "big"))
            recipes[slug] = [("MerkleAirdrop", "MerkleAirdrop", "f(bytes32,address,uint48)", (leaf, sender, 86400))]
        if slug == "raffle":
            # Public deterministic test-only seed, not a wallet key or fair randomness claim.
            seed = self.abi.keccak(canonical(["toolbox-test-seed", self.chain, sender]))
            self.state["raffle_test_seed"] = seed
            self.save()
            recipes[slug] = [("CommitRevealRaffle", "CommitRevealRaffle", "f(address,bytes32,uint256,uint48,uint48)", (sender, self.abi.keccak(bytes.fromhex(seed[2:])), 10**15, 86400, 3600))]
        if slug == "names":
            drop = self.deploy("names.NameGatedDrop", "NameGatedDrop", "f(address,address,uint256,uint48)", self.names, sender, amount, 86400)
            return {"NameGatedDrop": drop, "EastSeaNames (system)": self.names}
        return {label: self.deploy(f"{slug}.{contract}", contract, signature, *args) for label, contract, signature, args in recipes[slug]}

    def build_bundle(self, slug, deployed):
        manifest = json.loads((ROOT / "examples" / slug / "manifest.json").read_text())
        manifest.pop("x-toolbox-note", None)
        manifest.update(app_id=self.app_id(slug), name_binding=f"{slug}.{self.name}.sea", noindex=True,
                        publisher={"display": self.name})
        for contract in manifest["contracts"]:
            contract["address"] = deployed[contract["label"]]
            if contract.get("brake") != "none" and "brake" in contract:
                contract["brake"] = "none" if slug in {"airdrop", "names"} else contract["address"]
            if slug == "amm" and contract["label"] == "AmmRouter":
                contract["brake"] = deployed["AmmFactory"]
        extensions = {"x-toolbox-chain-id": self.chain, "x-toolbox-native-currency": {"symbol": "SEA", "decimals": 18},
                      "x-toolbox-primary-contract": PRIMARY.get(slug, manifest["contracts"][0]["label"]),
                      "x-toolbox-test-only": True}
        manifest.update(extensions)
        bundle = self.output / "bundles" / slug
        # Rebuild in place, rejecting unknown leftovers rather than hashing stale files.
        bundle.mkdir(parents=True, exist_ok=True)
        allowed = {"index.html", "manifest.json", "icon.png", "README.txt", "GAS.txt", "SECURITY.txt"}
        if any(p.name not in allowed or p.is_symlink() for p in bundle.iterdir()):
            raise PublishError(f"Unexpected files in bundle directory: {bundle}")
        frontend = (ROOT / "apps" / slug / "index.html").read_bytes()
        for doc in ("README", "GAS", "SECURITY"):
            frontend = frontend.replace(f"../../examples/{slug}/{doc}.md".encode(), f"{doc}.txt".encode())
            (bundle / f"{doc}.txt").write_bytes((ROOT / "examples" / slug / f"{doc}.md").read_bytes())
        (bundle / "index.html").write_bytes(frontend)
        (bundle / "icon.png").write_bytes(icon_png())
        runtime = {"schema": "toolbox-runtime/1", "app_id": manifest["app_id"], "contracts": manifest["contracts"], **extensions}
        (bundle / "manifest.json").write_bytes(canonical(runtime) + b"\n")
        index = bundle_index(bundle)
        entries = json.loads(index)["files"]
        manifest["bundle"] = {"format": "eastsea-bundle/1", "sha256": sha256(index),
                              "size": sum(e["size"] for e in entries), "files": len(entries)}
        encoded = canonical(manifest) + b"\n"
        if len(encoded) > 64 * 1024:
            raise PublishError("Registration manifest exceeds 64 KiB")
        try:
            import jsonschema
        except ImportError as error:
            raise PublishError("Install the toolbox's existing jsonschema dependency before publishing") from error
        schema = json.loads((ROOT / "templates/publish/schema/eastsea-app-1.json").read_text())
        errors = list(jsonschema.Draft202012Validator(schema).iter_errors(manifest))
        if errors:
            raise PublishError("Resolved manifest is invalid: " + errors[0].message)
        atomic_json(self.output / "examples" / slug / "manifest.json", manifest)
        (self.output / "bundles" / f"{slug}.index.json").write_bytes(index)
        return manifest, encoded, bundle, index

    def upload(self, slug, manifest, encoded, bundle, index):
        # Adapter contract is explicit: actual aether_appBundle API is not shipped yet.
        request = {"protocol": "toolbox-appBundle/1", "operation": "put", "sha256": manifest["bundle"]["sha256"],
                   "index": json.loads(index), "manifest_sha256": sha256(encoded),
                   "manifest_base64": base64.b64encode(encoded).decode(),
                   "files": [{"path": e["path"], "content_base64": base64.b64encode((bundle / e["path"]).read_bytes()).decode()}
                             for e in json.loads(index)["files"]]}
        atomic_json(self.output / "uploads" / f"{slug}.json", request)
        if self.args.bundle_mode == "stub":
            return "stub-content-pending"
        result = self.rpc.request("aether_appBundle", [request])
        if not isinstance(result, dict) or result.get("sha256") != manifest["bundle"]["sha256"] or result.get("verified") is not True:
            raise PublishError("Node did not verify the uploaded bundle digest")
        return "node-verified"

    def register(self, slug, manifest, encoded):
        app_id = manifest["app_id"]
        expected_manifest, expected_bundle = sha256(encoded), manifest["bundle"]["sha256"]
        record = words(self.read(self.registry, "appOf(bytes32)", app_id))
        if len(record) < 7:
            raise PublishError("Registry returned invalid appOf data")
        if int(record[0], 16) == 0:
            data = self.abi.call("publish(string,bytes32,bytes32,address,string)", slug, expected_manifest, expected_bundle, ZERO, "")
            self.transact("register:" + slug, data, self.registry)
            record = words(self.read(self.registry, "appOf(bytes32)", app_id))
        if len(record) < 7 or "0x" + record[0][-40:] != self.sender or "0x" + record[4] != expected_manifest or "0x" + record[5] != expected_bundle or int(record[6], 16):
            raise PublishError(f"Registry record for {slug} conflicts with this publication; do not overwrite a release")
        host = manifest["name_binding"]
        node = "0x" + words(self.read(self.names, "nodeFor(string)", host))[0]
        owner = "0x" + words(self.read(self.names, "ownerOf(bytes32)", node))[0][-40:]
        if owner == ZERO:
            self.transact("subdomain:" + slug, self.abi.call("createSubdomain(string,address)", host, self.sender), self.names)
        elif owner != self.sender:
            raise PublishError(f"Subdomain {host} is controlled by another account")
        binding = abi_string(self.read(self.names, "textOf(bytes32,string)", node, "app"))
        if binding and binding != app_id:
            raise PublishError(f"Subdomain {host} already binds another app")
        if not binding:
            self.transact("binding:" + slug, self.abi.call("setText(string,string,string)", host, "app", app_id), self.names)
        owner = "0x" + words(self.read(self.names, "ownerOf(bytes32)", node))[0][-40:]
        binding = abi_string(self.read(self.names, "textOf(bytes32,string)", node, "app"))
        if owner != self.sender or binding != app_id:
            raise PublishError(f"Subdomain {host} did not verify on-chain")

    def run(self):
        lock_file = self.output / ".publisher.lock"
        try:
            self.lock = os.open(lock_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError as error:
            raise PublishError(f"Publication is locked at {lock_file}; check its PID before removing a stale lock") from error
        try:
            os.write(self.lock, str(os.getpid()).encode())
            if self.state_file.exists():
                loaded = json.loads(self.state_file.read_text())
                for key in ("chain_id", "from", "name", "registry", "names"):
                    if loaded.get(key) != self.state[key]:
                        raise PublishError(f"Publication state changed its {key} while acquiring the lock")
                self.state = loaded
            for key in self.args.retry_tx:
                tx = self.state["transactions"].get(key)
                if not tx or not tx.get("hash"):
                    raise PublishError("Retry requires a recorded transaction hash; uncertain submissions need recovery")
                try:
                    self.receipt(tx["hash"])
                except TransactionFailed:
                    self.state.setdefault("failed_transactions", []).append({"key": key, **tx})
                    del self.state["transactions"][key]
                    self.save()
                else:
                    raise PublishError(f"Transaction {key} succeeded; refusing to resend it")
            for recovery in self.args.recover_tx:
                key, tx_hash = recovery.rsplit("=", 1)
                tx = self.state["transactions"].get(key)
                if not tx or tx.get("hash") or not re.fullmatch(r"0x[0-9a-f]{64}", tx_hash):
                    raise PublishError("Recovery requires an existing uncertain intent and lowercase transaction hash")
                try:
                    recovered = self.rpc.request("eth_getTransactionByHash", [tx_hash])
                except RpcError as error:
                    raise PublishError("This node cannot verify recovery transaction input; leave the uncertain intent untouched and inspect your wallet") from error
                if not isinstance(recovered, dict):
                    raise PublishError("Recovery transaction is unknown")
                candidate = {"from": str(recovered.get("from", "")).lower(),
                             "data": recovered.get("input", recovered.get("data", "0x")).lower(),
                             "value": hex(int(recovered.get("value", "0x0"), 16))}
                if recovered.get("to"):
                    candidate["to"] = str(recovered["to"]).lower()
                if recovered.get("hash", "").lower() != tx_hash or sha256(canonical(candidate)) != tx["intent"]:
                    raise PublishError("Recovery transaction sender/input/value/recipient do not match the saved intent")
                tx.update(hash=tx_hash, status="submitted")
                self.save()
            self.preflight()
            for slug in selected(self.args.apps):
                deployed = self.contracts(slug)
                manifest, encoded, bundle, index = self.build_bundle(slug, deployed)
                delivery = self.upload(slug, manifest, encoded, bundle, index)
                self.register(slug, manifest, encoded)
                self.state["apps"][slug] = {"contracts": deployed, "app_id": manifest["app_id"],
                    "manifest_sha256": sha256(encoded), "bundle_sha256": manifest["bundle"]["sha256"],
                    "sea_url": f"sea://{slug}.{self.name}.sea/", "bundle_status": delivery, "registered": True}
                self.save()
            summary(self.state["apps"], selected(self.args.apps))
            if self.args.bundle_mode == "stub":
                print("Content delivery pending: upload requests are saved; no node upload or hosting is claimed.")
            print(f"Account-scoped output: {self.output}")
        finally:
            os.close(self.lock)
            lock_file.unlink()
            if hasattr(self.wallet, "close"):
                self.wallet.close()


def summary(apps, slugs):
    print("App | Contract addresses | sea:// URL | Bundle")
    print("--- | --- | --- | ---")
    for slug in slugs:
        app = apps[slug]
        print(f"{slug} | " + "; ".join(f"{label}: {target}" for label, target in app["contracts"].items())
              + f" | {app['sea_url']} | {app['bundle_status']}")


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--rpc", default=os.getenv("RPC"))
    p.add_argument("--from", dest="sender", default=os.getenv("FROM"))
    p.add_argument("--name", default=os.getenv("NAME"))
    p.add_argument("--registry", default=os.getenv("REGISTRY"))
    p.add_argument("--names", default=os.getenv("NAMES"))
    p.add_argument("--apps", default="all", help="all (17) or comma-separated example slugs")
    p.add_argument("--wallet-command", default=os.getenv("WALLET_COMMAND"))
    p.add_argument("--wallet-rpc", default=os.getenv("WALLET_RPC"))
    p.add_argument("--wallet-timeout", type=float, default=300, help="local browser-wallet request timeout; no automatic resubmission")
    p.add_argument("--artifacts", default=str(ROOT / "tmp" / "publish-artifacts"))
    p.add_argument("--output", help="isolated output directory; default ./tmp/publish-testnet/<chain-account-name>")
    p.add_argument("--bundle-mode", choices=("rpc", "stub"), default="rpc")
    p.add_argument("--test-chain-id", dest="test_chain_ids", action="append", type=lambda x: int(x, 0), default=[7777, 7780])
    p.add_argument("--receipt-timeout", type=float, default=300)
    p.add_argument("--poll-interval", type=float, default=1)
    p.add_argument("--recover-tx", action="append", default=[], metavar="INTENT=0xHASH")
    p.add_argument("--retry-tx", action="append", default=[], metavar="INTENT", help="explicitly resend a confirmed reverted/dropped transaction, never a pending one")
    p.add_argument("--dry-run", action="store_true", help="offline plan; no RPC, wallet, build or output changes")
    p.add_argument("--hash-bundle", type=Path, help="print canonical JSON index hash without publishing")
    p.add_argument("--index", action="store_true", help="print index bytes with --hash-bundle")
    p.add_argument("--cast", default="cast")
    return p


def main(argv=None):
    p = parser()
    args = p.parse_args(argv)
    try:
        if args.hash_bundle:
            if not args.hash_bundle.is_dir():
                raise PublishError("Bundle directory does not exist")
            index = bundle_index(args.hash_bundle)
            print(index.decode() if args.index else sha256(index))
            return 0
        slugs = selected(args.apps)
        if not args.sender:
            raise PublishError("--from/FROM is required")
        sender = address(args.sender)
        if args.dry_run:
            name = root_name(args.name or "your-name")
            summary({slug: {"contracts": {c["label"]: "(deploy from " + sender + ")" for c in json.loads((ROOT / "examples" / slug / "manifest.json").read_text())["contracts"]},
                           "sea_url": f"sea://{slug}.{name}.sea/ (planned)", "bundle_status": "planned"} for slug in slugs}, slugs)
            print("DRY RUN: offline plan only; no wallet/RPC requests, transactions, files or builds.")
            return 0
        if not all((args.rpc, args.registry, args.names)):
            raise PublishError("RPC, REGISTRY and NAMES are required; no network or system addresses are assumed")
        if any(not math.isfinite(v) or v <= 0 for v in (args.receipt_timeout, args.poll_interval, args.wallet_timeout)):
            raise PublishError("Receipt/wallet timeouts and polling interval must be positive and finite")
        Publisher(args).run()
        return 0
    except (PublishError, OSError, ValueError, KeyError) as error:
        print(f"publish: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
