# B0 Claims: cost record (placeholders)

**Not measured on the EastSea executor.** The executor recorder (Lane A0, G0) fills the TO MEASURE cells. Only the layout facts below are checked, and only in Foundry, by `SlotDiff` final-diff tests. A Foundry gas number is not an EastSea cost ([MEASUREMENTS](../MEASUREMENTS.md)).

## Layout (compiler output, `forge inspect ClaimCampaigns storageLayout`)

| Slot | Fields | Occupied |
|---|---|---|
| 0 `_meta` | `uint64 nextCampaign │ uint64 brakeSince │ uint128 outstanding` | at deployment (nextCampaign = 1) |
| `_campaigns[id]` +0 | `bytes32 root` | per live campaign |
| +1 | `address refundRecipient │ uint64 deadline │ uint32 leafCount` | per live campaign |
| +2 | `uint128 remaining │ uint128 initiallyFunded` | per live campaign; `initiallyFunded` keeps it nonzero |
| `_used[id][word]` | 256 claim bits | per first-touched 256-index word |

Reentrancy lock: transient, 0 slots. Immutables (`token`, `tokenCodeHash`, brake doc hash) cost code bytes only.

Runtime 7,767 B, initcode 8,047 B (solc 0.8.31, osaka, optimizer 200; `forge build --sizes`).

## Checked in Foundry

| Action | New app slots | Cleared | Test |
|---|---:|---:|---|
| create | 3 | 0 | `test_create_storesThreeWordsAndPullsExactly` |
| first claim in a bitmap word | 1 | 0 | `test_claim_slotOccupancyPerBitmapWord` |
| later claim in the same word | 0 | 0 | same |
| close | 0 | 3 | `test_close_onlyAfterDeadlineOrEmpty` |
| prune 3 words | 0 | 3 | `test_prune_onlyClosedAndNoResurrection` |

Token-side slots (instance balance first occupied, recipient balance first occupied, allowance) belong to the token contract and are recorded separately.

## Events (metered bytes = 64 + 32·topics + data)

| Event | Topics | Data B | Metered B |
|---|---:|---:|---:|
| `CampaignCreated` | 3 | 192 | 352 (design's 320 + `dataHash`) |
| `Claimed` | 4 | 32 | 224 |
| `Closed` | 3 | 32 | 192 |
| `Pruned` | 2 | 64 | 192 |
| `BrakeLatched` | 1 | 64 | 160 |

## To measure (executor recorder)

| Action | exec gas | prove gas | envelope E | output O | U (state units) | floor fee |
|---|---|---|---|---|---|---|
| deploy | TO MEASURE | | | | | |
| create (warm instance balance) | | | | | | |
| create (first, instance balance zero) | | | | | | |
| claim (warm word, warm holder) | | | | | | |
| claim (first in word) | | | | | | |
| claim (fresh holder) | | | | | | |
| claim rejected: invalid / replay / expired | | | | | | |
| close (zero remainder) / (refund) | | | | | | |
| prune 8 words | | | | | | |
| tripBrake | | | | | | |
| H1–H10 cohorts from README | | | | | | |

Design estimates for comparison (not results): create 360 u, claim 69 u (+100 for the first claim in a word, +100 for a fresh holder), close 30–36 u, prune 46 u, deploy ≈6,465 u ([DESIGN](DESIGN.md#illustrative-exact-action-ledger)). The measured runtime is 7,767 B rather than the design's assumed 6,000 B, so deploy is about 1,767 u higher than that estimate before envelope bytes.
