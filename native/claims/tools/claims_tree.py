#!/usr/bin/env python3
"""Build, export and check ClaimCampaigns Merkle data. Standard library only.

The issuer publishes the canonical CSV and the exported JSON (root, every leaf
and proof) to independent mirrors *before* asking anyone to claim; recipients'
wallets keep their own leaf and proof. The contract cannot supply missing data.

    claims_tree.py build  --csv alloc.csv --chain-id 1 --instance 0x.. --campaign 1 > export.json
    claims_tree.py verify --json export.json        # recompute root and every proof

CSV: one `account,amount` row per entitlement, in index order (no header).
dataHash = sha256 of the canonical CSV bytes: `index,0xaccount,amount\n` per
row, lowercase hex, decimal amount. Pass it as `dataHash` to `create`.

Format (must match ClaimCampaigns.sol):
    leaf = keccak256(abi.encode(LEAF_DOMAIN, chainId, instance, campaign,
                                index, account, amount))
    node = keccak256(left || right); positional tree; empty slots = 0x00..00
    depth = ceil(log2(leafCount)); proof = siblings from leaf level upward.
"""

import argparse
import hashlib
import json
import sys

MAX_LEAVES = 1 << 16

# ---------------------------------------------------------------- keccak-256
# Plain Keccak-f[1600] (original Keccak padding 0x01, not SHA-3's 0x06).

_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [
    [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
]
_M = (1 << 64) - 1


def _rol(v, n):
    return ((v << n) | (v >> (64 - n))) & _M if n else v


def _f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    msg = bytearray(data) + b"\x01"
    while len(msg) % rate:
        msg.append(0)
    msg[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        block = msg[off:off + rate]
        for i in range(rate // 8):
            x, y = i % 5, i // 5
            a[x][y] ^= int.from_bytes(block[8 * i:8 * i + 8], "little")
        a = _f(a)
    out = b""
    for i in range(4):
        out += a[i % 5][i // 5].to_bytes(8, "little")
    return out


# ------------------------------------------------------------------- format

LEAF_DOMAIN = keccak256(b"eastsea.native.claims.leaf.v1")
ZERO = b"\x00" * 32


def _word(v: int) -> bytes:
    return v.to_bytes(32, "big")


def _addr(s: str) -> int:
    s = s.strip().lower()
    if not (s.startswith("0x") and len(s) == 42):
        raise ValueError(f"bad address {s!r}")
    return int(s, 16)


def leaf_hash(chain_id, instance, campaign, index, account, amount) -> bytes:
    return keccak256(LEAF_DOMAIN + _word(chain_id) + _word(instance) + _word(campaign)
                     + _word(index) + _word(account) + _word(amount))


def depth_for(n: int) -> int:
    d = 0
    while (1 << d) < n:
        d += 1
    return d


def build_levels(leaves):
    depth = depth_for(len(leaves))
    level = list(leaves) + [ZERO] * ((1 << depth) - len(leaves))
    levels = [level]
    while len(level) > 1:
        level = [keccak256(level[i] + level[i + 1]) for i in range(0, len(level), 2)]
        levels.append(level)
    return levels


def proof_for(levels, index):
    out = []
    for lvl in levels[:-1]:
        out.append(lvl[index ^ 1])
        index >>= 1
    return out


def root_from(leaf, index, proof):
    h = leaf
    for i, s in enumerate(proof):
        h = keccak256(h + s) if (index >> i) & 1 == 0 else keccak256(s + h)
    return h


def canonical_csv(rows) -> bytes:
    return "".join(f"{i},0x{a:040x},{amt}\n" for i, (a, amt) in enumerate(rows)).encode()


def read_csv(path):
    rows = []
    with open(path) as f:
        for ln, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) != 2:
                raise ValueError(f"line {ln}: want account,amount")
            amt = int(parts[1])
            if amt <= 0 or amt >= 1 << 128:
                raise ValueError(f"line {ln}: amount must be in (0, 2^128)")
            rows.append((_addr(parts[0]), amt))
    if not rows or len(rows) > MAX_LEAVES:
        raise ValueError(f"leaf count must be 1..{MAX_LEAVES}")
    return rows


def build(rows, chain_id, instance, campaign):
    leaves = [leaf_hash(chain_id, instance, campaign, i, a, amt) for i, (a, amt) in enumerate(rows)]
    levels = build_levels(leaves)
    total = sum(amt for _, amt in rows)
    accounts = [a for a, _ in rows]
    return {
        "format": "eastsea.native.claims.leaf.v1",
        "chainId": chain_id,
        "instance": f"0x{instance:040x}",
        "campaign": campaign,
        "root": "0x" + levels[-1][0].hex(),
        "leafCount": len(rows),
        "depth": depth_for(len(rows)),
        "total": str(total),
        # The root does not prove these; the issuer and reviewers must.
        "duplicateAccounts": len(accounts) - len(set(accounts)),
        "dataHash": "0x" + hashlib.sha256(canonical_csv(rows)).hexdigest(),
        "leaves": [
            {
                "index": i,
                "account": f"0x{a:040x}",
                "amount": str(amt),
                "leaf": "0x" + leaves[i].hex(),
                "proof": ["0x" + p.hex() for p in proof_for(levels, i)],
            }
            for i, (a, amt) in enumerate(rows)
        ],
    }


def verify(doc):
    chain_id, instance, campaign = doc["chainId"], _addr(doc["instance"]), doc["campaign"]
    root = bytes.fromhex(doc["root"][2:])
    for e in doc["leaves"]:
        leaf = leaf_hash(chain_id, instance, campaign, e["index"], _addr(e["account"]), int(e["amount"]))
        proof = [bytes.fromhex(p[2:]) for p in e["proof"]]
        if len(proof) != depth_for(doc["leafCount"]) or root_from(leaf, e["index"], proof) != root:
            raise SystemExit(f"index {e['index']}: proof does not reach root")
    rows = [(_addr(e["account"]), int(e["amount"])) for e in doc["leaves"]]
    if "0x" + hashlib.sha256(canonical_csv(rows)).hexdigest() != doc["dataHash"]:
        raise SystemExit("dataHash mismatch")
    return len(doc["leaves"])


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--csv", required=True)
    b.add_argument("--chain-id", type=int, required=True)
    b.add_argument("--instance", required=True)
    b.add_argument("--campaign", type=int, required=True)
    v = sub.add_parser("verify")
    v.add_argument("--json", required=True)
    args = p.parse_args(argv)
    if args.cmd == "build":
        doc = build(read_csv(args.csv), args.chain_id, _addr(args.instance), args.campaign)
        json.dump(doc, sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        with open(args.json) as f:
            n = verify(json.load(f))
        print(f"ok: {n} leaves reach the root")


if __name__ == "__main__":
    assert keccak256(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    main()
