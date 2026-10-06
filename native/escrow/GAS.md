# B2 Escrow: cost record (placeholders)

**Not measured on the EastSea executor.** The executor recorder (Lane A0, G0) fills the TO MEASURE cells. Only the layout facts below are checked, in Foundry. A Foundry gas number is not an EastSea cost ([MEASUREMENTS](../MEASUREMENTS.md)).

## Layout (compiler output)

| Slot | Fields | Occupied |
|---|---|---|
| 0 `_g` | `uint128 totalLiability │ uint64 nextId │ uint64 brakeSince` | at deployment (nextId = 1) |
| `_deals[id]` +0 (S0) | `address buyer │ uint64 clock │ uint8 phase │ uint8 paid` | per live deal |
| +1 (S1) | `address seller │ uint64 deliverBy │ uint8 policy` | per live deal |
| +2 (S2) | `uint128 amount │ uint128 sellerAward` | per live deal |
| +3 (S3) | `bytes32 termsHash` (nonzero) | per live deal |
| `_proposals[id]` (S4) | `uint128 sellerAward │ uint64 round │ uint8 proposer` | only after the first proposal; cleared at resolution |

Reentrancy lock: transient, 0 slots. Immutables (asset, arbiter, ruling window, spec hash, asset code hash, brake doc hash) cost code bytes only. Runtime 10,206 B, initcode 10,781 B (solc 0.8.31, osaka, optimizer 200).

## Checked in Foundry

| Action | New app slots | Cleared | Test |
|---|---:|---:|---|
| create | 4 | 0 | `test_create_fourWordsExactPull` |
| first proposal (even a zero award) | 1 | 0 | `test_split_proposalRules` |
| final payout | 0 | 4 | `test_sellerNeverAccepts_anyoneLapsesAndBuyerIsRefunded` |

## Events (metered bytes)

| Event | Topics | Data B | Metered B |
|---|---:|---:|---:|
| `Funded` | 4 | 160 | 352 |
| `Accepted` | 3 | 0 | 160 |
| `Proposed` | 3 | 64 | 224 |
| `Disputed` | 3 | 32 | 192 |
| `Resolved` | 2 | 32 | 160 |
| `Paid` | 3 | 32 | 192 |
| `BrakeLatched` | 1 | 64 | 160 |

## To measure (executor recorder)

| Action | exec gas | prove gas | envelope E | output O | U | floor fee |
|---|---|---|---|---|---|---|
| deploy (no arbiter / arbiter; ERC-20 / DBLN) | TO MEASURE | | | | | |
| create, ERC-20 3-call batch (warm / cold book) | | | | | | |
| create, DBLN with value | | | | | | |
| accept / cancel / release / refund | | | | | | |
| propose (first / later) / acceptProposal | | | | | | |
| dispute / rule / resolveTimeout | | | | | | |
| pay (warm / fresh recipient; final deletes record) | | | | | | |
| rejected calls (wrong actor, too early or late, stale) | | | | | | |
| tripBrake | | | | | | |
| README H1–H10 cohorts | | | | | | |

Design estimates for comparison (not results): create 461 u, accept 23 u, propose 127/27 u, resolve 24 u, dispute 25 u, pay 31 u; lifecycle 539 u warm and 739 u cold; 1,000-deal cohort 647.1 u/deal with an assumed deploy of 8,000 u ([DESIGN](DESIGN.md#meter-every-action-including-conditional-first-writes)). The measured runtime is 10,206 B, so deploy is likely above that estimate.
