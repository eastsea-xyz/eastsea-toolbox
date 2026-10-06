# B1 Streams and vesting: cost record (placeholders)

**Not measured on the EastSea executor.** The executor recorder (Lane A0, G0) fills the TO MEASURE cells. Only the layout facts below are checked, in Foundry. A Foundry gas number is not an EastSea cost ([MEASUREMENTS](../MEASUREMENTS.md)).

## Layout (compiler output)

| Slot | Fields | Occupied |
|---|---|---|
| 0 `_meta` | `uint64 nextId │ uint64 brakeSince │ uint128 outstanding` | at deployment (nextId = 1) |
| `_grants[id]` +0 (S0) | `address beneficiary │ uint32 start │ uint32 cliff │ uint32 end` | per live grant |
| +1 (S1) | `uint128 total │ uint128 released` | per live grant; `total` keeps it nonzero |

Reentrancy lock: transient, 0 slots. Runtime 6,681 B, initcode 6,961 B (solc 0.8.31, osaka, optimizer 200).

## Checked in Foundry

| Action | New app slots | Cleared | Test |
|---|---:|---:|---|
| create | 2 | 0 | `test_create_twoWordsExactPull` |
| partial claim | 0 | 0 | `test_claim_relayedToBeneficiary_partialThenFinalDeletes` |
| final claim | 0 | 2 | same |

## Events (metered bytes)

| Event | Topics | Data B | Metered B |
|---|---:|---:|---:|
| `Created` | 4 | 128 | 320 |
| `Claimed` | 3 | 32 | 192 |
| `BrakeLatched` | 1 | 64 | 160 |

## To measure (executor recorder)

| Action | exec gas | prove gas | envelope E | output O | U | floor fee |
|---|---|---|---|---|---|---|
| deploy | TO MEASURE | | | | | |
| create (warm / first instance balance) | | | | | | |
| createBatch ×8 | | | | | | |
| claim partial (warm holder / fresh holder) | | | | | | |
| claim final (deletes two words) | | | | | | |
| claim rejected (nothing yet / unknown) | | | | | | |
| tripBrake | | | | | | |
| README H1–H10 cohorts | | | | | | |

Design estimates for comparison (not results): create 260/360 u, claim 36 u (+100 for a fresh holder), rejected 24 u, deploy ≈6,465 u at an assumed 6,000 B runtime. The measured runtime is 6,681 B.
