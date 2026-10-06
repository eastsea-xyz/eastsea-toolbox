# Hazard probes (H1–H14)

Each probe is a standalone contract under `src/` with a `run()` function that **reverts on mismatch**. It has no forge-std and uses no cheatcodes. The same files compile unchanged in the EastSea executor harness. The Foundry runners under `test/` add only the staging that a test chain needs: `vm.etch`, `vm.prank`, `vm.roll`/`vm.warp`, and `vm.prevrandao`.

```bash
cd proof && forge test            # all probes (solc 0.8.31, evm_version osaka, EIP-170 enforced)
cd proof && forge test --mc H02   # one hazard
```

The probes pin **EastSea's behaviour today**: revm 43 at the Osaka spec, `prevrandao = 0`, about 1 s blocks, and no canonical predeploys. If EastSea changes one of these, the matching probe fails. That failure is the signal to update both the probe and the compatibility profile; it is not a bug in the probe.

## Map

| ID | Hazard | Probe | What `run()` asserts | Harness staging |
|---|---|---|---|---|
| H1 | Opcodes | `H01Opcodes` | PUSH0, TSTORE/TLOAD round trip, MCOPY, CLZ (EIP-7939: CLZ(0)=256), BLOBHASH(0)=0, BLOBBASEFEE ≥ 1 | none |
| H2 | Precompiles | `H02Precompiles` | 0x01–0x0a, BLS12-381 0x0b–0x11, P256VERIFY 0x100: output equals the EIP vector; gas is exact (succeeds at cost, fails at cost−1) for 0x01–0x0a and 0x100 | none |
| H3 | Signatures | `H03EcrecoverVsP256` | ecrecover over a P-256 signature never yields the P-256 account address; P256VERIFY rejects a secp256k1 signature | none |
| H4 | 7702 code on EOAs | `H04DelegatedAccounts` | `safeMint` to a hook-less delegate reverts (B2 open); with hooks it succeeds; a delegated user has 23 B of code `0xef0100‖delegate`; the `tx.origin == msg.sender` guard still passes for a direct 7702 call | `safeMintToDelegatedUser(user, id, expectOk)` with a real delegated EastSea user |
| H5 | Block cadence | `H05BlockCadence` | observed ms/block is within 500–2000 | `observe()`, then `run()` in a later block |
| H6 | Timestamps | `H06Timestamps` | the timestamp never decreases; equal-second blocks are counted | `step()` once per block, then `run()` |
| H7 | Randomness | `H07Prevrandao` | `block.prevrandao == 0` | none |
| H8 | Size and gas limits | `H08CodeLimits` | runtime 24,576 B deploys and 24,577 B fails; initcode 49,152 B deploys and 49,153 B fails; the whole run fits the 16,777,216 per-tx cap | none |
| H9 | Paid state (exec-gas side) | `H09PaidState` | a new slot costs ≥ 22,100 exec gas and a warm overwrite < 5,000 | harness records **state units** for the same calls (see `../bench/`) |
| H10 | SELFDESTRUCT | `H10Selfdestruct` | EIP-6780: code persists after a SELFDESTRUCT outside the creation tx | `checkCrossTxDestruct(victim)` with a victim from an earlier tx; harness checks that a same-tx victim is gone after the tx |
| H11 | Canonical addresses | `H11CanonicalAddresses` | any code at Multicall3, the CREATE2 deployer, the Safe singleton factory, Permit2 or EntryPoint v0.8 has the mainnet code hash. `presentMask()` reports which exist (EastSea today: none, B3) | none |
| H12 | Native staking | no probe | not EVM-observable. Verdict "No" for real staking (catalog §1) | n/a |
| H13 | Tx format and tooling | no probe | not EVM-observable. Deployment goes through the harness or SDK, not `forge script --broadcast` | harness |
| H14 | Old compilers | `../fidelity.py` | the rebuilt runtime equals mainnet `eth_getCode`, modulo immutables and metadata | n/a |

## Where Foundry differs from EastSea (and how the runners handle it)

| Difference | Runner handling |
|---|---|
| Foundry lifts EIP-170 for test deployments by default | `foundry.toml` sets `code_size_limit = 24576`. One runner per hazard keeps each test contract under the limit. With the limit lifted, `test_H08_limits` fails, which is how the probe is meant to work. |
| Foundry predeploys the Arachnid CREATE2 deployer at `0x4e59…956C` (its code hash equals mainnet). EastSea genesis has none (B3) | `test_H11_canonicalAddressesAbsent` etches the address empty before it asserts `presentMask() == 0`. `test_Foundry_H11_create2DeployerIsMainnetCode` records the Foundry fact. |
| Foundry's `prevrandao` and cadence are whatever the cheatcodes set | The runners set EastSea's values: 1 s blocks and `prevrandao = 0`. `test_Ethereum_H05_*` and `test_Ethereum_H07_*` show that Ethereum's values (12 s blocks, non-zero prevrandao) fail the pins. |
| The test gas limit (2³⁰) is above EIP-7825's 16,777,216 | Not enforced in Foundry. `H08` keeps its own run at about 10.7 M gas so it fits one EastSea tx. |

## Test vectors and sources

- **ecrecover**: secp256k1 private key d = 1 (address `0x7E5F…5Bdf`), with a low-s signature per EIP-2. Invalid case: v = 29, which must return empty output.
- **sha256 / ripemd160 / identity**: NIST "abc" and empty-string digests. Gas is 60+12w, 600+120w and 15+3w.
- **modexp**: 3⁵ mod 7 = 5 and 3⁴⁰⁹⁶ mod 5 = 1. The gas floor is **500** under Osaka (EIP-7883); it was 200 under EIP-2565.
- **bn254 add/mul/pairing**: EIP-196/197 generator arithmetic; e(P,Q)·e(−P,Q) = 1. Gas follows EIP-1108 (150 / 6,000 / 45,000 + 34,000k).
- **blake2f**: EIP-152 test vector 5 (12 rounds, "abc"), gas = rounds.
- **KZG point evaluation**: p(x) = 1, z = 0, commitment = compressed G1 generator, proof = point at infinity. Success returns `4096 ‖ BLS_MODULUS` (EIP-4844). Gas is 50,000.
- **BLS12-381**: EIP-2537 final address layout: 0x0b G1ADD, 0x0c G1MSM, 0x0d G2ADD, 0x0e G2MSM, 0x0f PAIRING_CHECK, 0x10 MAP_FP_TO_G1, 0x11 MAP_FP2_TO_G2. The probe asserts correctness only: G1+O, 2·G1, O+O, O·1, e(O,O)=1, and map(0) ≠ O. Gas is recorded but not asserted, because EIP-2537 pricing changed several times before Prague.
- **P256VERIFY**: the RIP-7212 appendix vector. Gas is **6,900** under Osaka (EIP-7951); RIP-7212 L2s charge 3,450. A failed check returns **empty output**, not a zero word.
- **Canonical code hashes (H11)**: `keccak256(eth_getCode)` on Ethereum mainnet, fetched on 2026-10-06.

## Probe bugs fixed while finishing Lane 0

The first draft failed for reasons that had nothing to do with the EVM under test. Each fix is listed so the history is visible:
TSTORE runtime underflowed the stack (missing key); the "bad ecrecover" case flipped a bit of `s`, which still recovers *some* address (now v = 29); P256VERIFY failure was expected as a zero word (it is empty); BLAKE2F state lacked the parameter-block XOR; KZG success output was expected as `1` (it is `4096 ‖ modulus`); BLS used pre-final addresses (G2ADD at 0x0e); the 7702 designator check had bytes 1–2 swapped; H08 expected an over-limit initcode CREATE to return 0 (EIP-3860 aborts the calling frame); modexp and P256VERIFY gas were pinned to pre-Osaka prices.
