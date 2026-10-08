#!/usr/bin/env python3
"""Test-only EIP-1193 wallet adapter for an isolated, owned Aether devnet.

Reads one request from stdin and writes its bare JSON result to stdout. Signing
uses the CLI's public development P-256 account; no private-key file is read.
The owned-devnet marker, loopback RPC and chain-id checks deliberately prevent
using this adapter for the live testnet or as a user's publishing wallet.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_AETHER = "/Volumes/workspace/aether-node/.claude/worktrees/lead/target/release/aether"


def rpc(url, method, params=None):
    request = urllib.request.Request(
        url,
        json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode(),
        {"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        reply = json.load(response)
    if "error" in reply:
        raise RuntimeError(f"{method}: {reply['error']}")
    return reply.get("result")


def quantity(value):
    return int(value, 16) if isinstance(value, str) and value.startswith("0x") else int(value)


def check_owned(args):
    url = urllib.parse.urlsplit(args.rpc)
    if url.scheme != "http" or url.hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise RuntimeError("devnet wallet only accepts an owned loopback HTTP RPC")
    marker = pathlib.Path(args.owned_marker).resolve()
    if not marker.is_relative_to((ROOT / "tmp").resolve()):
        raise RuntimeError("owned-devnet marker must be inside this workspace's tmp/")
    proof = json.loads(marker.read_text())
    if proof.get("rpc") != args.rpc or proof.get("chain_id") != 7777 or proof.get("kind") != "toolbox-owned-devnet":
        raise RuntimeError("owned-devnet marker does not match this RPC")
    if quantity(rpc(args.rpc, "eth_chainId")) != 7777:
        raise RuntimeError("devnet wallet refuses any chain other than the isolated 7777 devnet")
    public = subprocess.run([args.aether, "dev-accounts"], check=True, capture_output=True, text=True).stdout
    match = re.search(rf"^dev\s+{args.account}\s+(0x[0-9a-fA-F]{{40}})$", public, re.M)
    if not match:
        raise RuntimeError("selected development account was not reported by the CLI")
    return match.group(1)


def request(args, req):
    account = check_owned(args)
    audit_path = pathlib.Path(args.audit_log).resolve() if args.audit_log else None
    if audit_path and not audit_path.is_relative_to((ROOT / "tmp").resolve()):
        raise RuntimeError("wallet audit log must be inside workspace tmp/")
    if audit_path:
        audit_path.parent.mkdir(parents=True, exist_ok=True)
    method = req.get("method")
    params = req.get("params") or []
    if method in {"eth_accounts", "eth_requestAccounts"}:
        return [account]
    if method == "eth_sendTransaction":
        if len(params) != 1 or not isinstance(params[0], dict):
            raise RuntimeError("eth_sendTransaction requires one transaction")
        tx = params[0]
        if str(tx.get("from", "")).lower() != account.lower():
            raise RuntimeError("sender must match the selected P-256 development account")
        if set(tx) - {"from", "to", "data", "value", "gas"}:
            raise RuntimeError("the test wallet accepts call fields only; the CLI owns B5 fees and signing")
        gas = quantity(tx.get("gas", "0x7a1200"))
        if not 21_000 <= gas <= 30_000_000:
            raise RuntimeError("invalid execution gas cap")
        data = tx.get("data") or "0x"
        if not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", data):
            raise RuntimeError("transaction data must be even-length hex")
        common = ["--rpc", args.rpc, "--from-dev", str(args.account), "--gas", str(gas)]
        if tx.get("to"):
            if not re.fullmatch(r"0x[0-9a-fA-F]{40}", tx["to"]):
                raise RuntimeError("invalid transaction recipient")
            command = [args.aether, "call", *common, "--to", tx["to"], "--data", data,
                       "--value", str(quantity(tx.get("value", "0x0"))), "--wait"]
        else:
            if quantity(tx.get("value", "0x0")):
                raise RuntimeError("CLI deployment does not support a nonzero creation value")
            command = [args.aether, "deploy", *common, "--code", data]
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        match = re.search(r"^tx (0x[0-9a-fA-F]{64})\b", result.stdout, re.M)
        if not match:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "CLI did not return a transaction hash")
        hash_ = match.group(1)
        receipt = None
        try:
            receipt = rpc(args.rpc, "aether_getReceipt", [hash_])
        except (OSError, ValueError, RuntimeError) as exc:
            print(f"devnet-wallet: accepted {hash_}; audit receipt unavailable: {exc}", file=sys.stderr)
        if audit_path:
            try:
                with audit_path.open("a") as stream:
                    stream.write(json.dumps({"method": method, "from": account, "tx": tx, "hash": hash_,
                                             "receipt": receipt.get("receipt") if receipt else None}, sort_keys=True) + "\n")
            except OSError as exc:
                print(f"devnet-wallet: accepted {hash_}; audit log unavailable: {exc}", file=sys.stderr)
        # Return the accepted hash even when execution reverted. The caller must
        # journal it before checking the receipt, so an idempotent rerun never
        # resends a failed or uncertain transaction behind the user's back.
        return hash_
    if method == "wallet_switchEthereumChain":
        if len(params) != 1 or quantity(params[0].get("chainId", "0x0")) != 7777:
            raise RuntimeError("owned devnet wallet cannot switch to another network")
        return None
    if method in {"eth_sign", "personal_sign", "eth_signTypedData", "eth_signTypedData_v4"}:
        raise RuntimeError("Ethereum ECDSA signing is not provided by this P-256 test wallet")
    if method == "eth_getTransactionReceipt":
        result = rpc(args.rpc, "aether_getReceipt", params)
        if not result or "receipt" not in result:
            return None
        native = result["receipt"]
        return {"transactionHash": params[0], "status": "0x1" if native["success"] else "0x0",
                "contractAddress": native.get("contract_address"), "blockNumber": hex(result["height"])}
    if not isinstance(method, str):
        raise RuntimeError("request needs a method")
    return rpc(args.rpc, method, params)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--owned-marker", required=True)
    parser.add_argument("--account", type=int, choices=range(1, 11), default=1)
    parser.add_argument("--aether", default=DEFAULT_AETHER)
    parser.add_argument("--audit-log")
    args = parser.parse_args()
    try:
        result = request(args, json.load(sys.stdin))
        print(json.dumps(result))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"devnet-wallet: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
