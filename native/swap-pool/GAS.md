# C1 Swap pool: cost record (placeholders)

**Not measured on the EastSea executor.** The executor recorder (Lane A0, G0) fills the TO MEASURE cells. Only the layout facts below are checked, in Foundry. A Foundry gas number is not an EastSea cost ([MEASUREMENTS](../MEASUREMENTS.md)).

## Layout (compiler output)

| Slot | Fields | Occupied |
|---|---|---|
| 0 `_r` | `uint112 reserve0 │ uint112 reserve1 │ uint32 lastHeightLow` | at first liquidity |
| 1 `_s` | `uint128 totalShares │ uint128 lockedShares` (locked minimum lives here, no sink entry) | at first liquidity |
| 2 `_m` | `uint64 createdAt │ uint64 latchedAt │ uint8 reason` | at deployment (`createdAt != 0`) |
| `shares[lp]` | `uint128` | per newly nonzero LP; cleared on full exit |

Reentrancy lock: transient, 0 slots. Immutables (two tokens, fee, two pinned code hashes, brake document hash) cost code bytes only. Runtime **9,212 B**, initcode **9,905 B** (solc 0.8.31, osaka, optimizer 200). The design's illustrative cohort assumed nothing about code size; deployment `D = 200 + runtime + H(...)` uses the actual bytes.

## Checked in Foundry

| Action | New pool slots | Cleared | Test |
|---|---:|---:|---|
| deploy | 1 (`_m`) | 0 | `test_deploy_occupiesOnlyBrakeMetadata` |
| first liquidity | 3 (`_r`, `_s`, `shares[lp]`) | 0 | `test_firstAdd_threeSlots_locksMinimumInsideSupply` |
| new LP add | 1 | 0 | `test_newLp_oneSlot_proportional_roundedUp_restStaysWithUser` |
| existing LP add | 0 | 0 | `test_existingLp_addsWithNoNewSlot` |
| warm swap | 0 | 0 | `test_exactInput_formula_noNewSlot_kGrows` |
| full exit | 0 | 1 | `test_remove_fullExit_clearsSlot_proRata` |
| approve → swap → approve(0) batch | 0 in the input token (allowance set and cleared), 0 in pool and output token when balances are warm | — | `test_approveSwapReset_oneSignature_noLingeringAllowance`, `test_warmBatch_occupiesNoNewSlotInPoolOrOutputToken` |

The design's "first liquidity" row counts 2 global + 1 LP slots in the pool; the brake metadata word is charged at deployment, as designed. Token balance slots (pool and holders) are counted in the token, outside this core.

## Events (metered bytes = 64 + 32·topics + data)

| Event | Topics | Data B | Metered B |
|---|---:|---:|---:|
| `Swap(sender, delta0, delta1)` | 2 | 64 | 192 |
| `Added(owner, amount0, amount1, shares)` | 2 | 96 | 224 |
| `Removed(owner, amount0, amount1, shares)` | 2 | 96 | 224 |
| `BrakeLatched(sinceHeight, reasons)` | 1 | 64 | 160 |

## To measure (executor recorder)

| Action | exec gas | prove gas | envelope E | output O | U | floor fee |
|---|---|---|---|---|---|---|
| deploy | TO MEASURE | | | | | |
| first liquidity (fresh pool token balances) | | | | | | |
| new LP add / existing LP add | | | | | | |
| exact-input swap, 3-call batch (warm / zero output balance) | | | | | | |
| exact-output swap, 3-call batch | | | | | | |
| two-hop route, 6-call batch | | | | | | |
| remove (partial / full; warm / fresh receiver) | | | | | | |
| reverted swap: slippage, expired, braked | | | | | | |
| tripBrake; remove that self-latches | | | | | | |
| README H1–H13 cohorts, incl. contention and ≥10,000-height sustained runs | | | | | | |

Design estimates for comparison (not results): warm swap 62 u, swap to zero output balance 162 u, first liquidity 583 u, new LP 183 u, existing LP 83 u, full remove 43 u, brake latch 25 u; full cohort (first LP, ten warm swaps, remove) 1,246 u + D ([DESIGN](DESIGN.md#proposed-storage-and-persistence-meter)).
