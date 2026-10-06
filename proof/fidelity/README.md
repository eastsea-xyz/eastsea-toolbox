# Fidelity check (H14)

`../fidelity.py` rebuilds an original from its pinned upstream commit with the **original** compiler settings, then compares the runtime bytecode with Ethereum mainnet `eth_getCode` at the canonical address. Equal bytes are the strongest evidence that the code we test on EastSea is the code Ethereum runs.

```bash
proof/fidelity.py                 # all items, offline (uses proof/mainnet-code/ and the source cache)
proof/fidelity.py --fetch         # first run: git fetch the pinned commits, eth_getCode once per address
proof/fidelity.py permit2 --json  # one item, machine-readable
```

- **Requirements:** Python 3.9+, git and Foundry. A missing solc version is installed through Foundry's svm into `~/.svm`. Vyper items need `vyper==<version>` on `PATH`; without it they report `NOT_COMPARABLE`.
- **Caches:**
  - Mainnet runtime code is committed under `proof/mainnet-code/<chainId>-<address>.hex`, so CI runs offline.
  - Upstream sources are fetched into `proof/.fidelity-work/`, which is gitignored and never committed.
- **Exit status:** 1 if any item is `MISMATCH`.

## Verdicts

| Verdict | Meaning |
|---|---|
| `MATCH` | byte-identical |
| `MATCH (modulo metadata)` | identical after masking the hash inside each CBOR metadata blob. The blob depends on source paths and comments, not on what the code does |
| `MATCH (modulo immutables)` | identical after masking `immutableReferences`, linked-library slots and a library's self-address (metadata masked too) |
| `MISMATCH (detail)` | different code. The output gives the lengths or the first differing byte |
| `NOT_COMPARABLE (reason)` | no mainnet instance, compiler unavailable, or sources/code not cached |

## Item manifest (`items/<id>.json`)

| Field | Meaning |
|---|---|
| `catalog` | ID in the clone catalog (E1…E28) |
| `name`, `licence`, `folder` | display name, SPDX licence, and the `originals/<class>/` folder it belongs to |
| `repo`, `commit` | upstream git URL and the exact commit (full SHA) |
| `submodules` | `true` to fetch the commit's pinned submodules (for imports from `lib/`) |
| `entry`, `contract` | source file (repo-relative) and contract name |
| `remappings` | solc remappings, as upstream builds use them |
| `compiler` | `solc` version, or `vyper` version; `optimizer`, `runs`, `evmVersion`, `viaIR`, `bytecodeHash` |
| `settingsSource` | where the settings came from (upstream config file, or the Etherscan verified settings) |
| `mainnet` | `chainId` and `address` of the canonical deployment. Omit it to get `NOT_COMPARABLE` |

## Results so far (2026-10-06)

| Item | Compiler | Verdict |
|---|---|---|
| E1 Multicall3 | solc 0.8.12, runs 10,000,000 | MATCH (modulo metadata) |
| E3 WETH9 | solc 0.4.19, optimizer off | MATCH (modulo metadata) |
| E4 Uniswap V2 Factory (embeds Pair initcode) | solc 0.5.16, istanbul, runs 999,999 | MATCH (byte-identical) |
| E7 Permit2 | solc 0.8.17, viaIR, runs 1,000,000, no metadata hash | MATCH (modulo immutables: cached chain id and domain separator) |

As a negative control, building Multicall3 with `runs = 200` gives `MISMATCH (length 3286 vs mainnet 3808)`.
