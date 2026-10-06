# B0 Claims: cost record (measured)

**Measured on the EastSea executor, head-to-head against Uniswap MerkleDistributor.** Original: `Uniswap/merkle-distributor@25a79e8` (GPL-3.0-or-later, solc 0.8.17, optimizer 5,000; runtime 2,615 B), one deployment per allocation. Native: `ClaimCampaigns` from this folder (solc 0.8.31, Osaka, optimizer 200; runtime 7,767 B), one shared instance per token. Both use the same 4,096-leaf allocation (proof depth 12, 1,000 tokens per leaf); each path uses its own leaf format (Uniswap packed leaf with the OZ sorted-pair tree; the native domain-separated positional tree).

## Head-to-head (warm unless stated)

| Action | Original U | Native U | Signatures (orig / native) | Note |
|---|---:|---:|---|---|
| Shared instance deploy (once per token) | — | 8,478 | — / 1 | 7,767 B code + account + meta word |
| Open an allocation | 3,026 (deploy 2,901 + fund 125) | **380** (480 first on a new instance) | 2 / 1 | native: one batch approve → create → approve(0) |
| Claim, warm holder, bitmap word already used | **45** | 47 | 1 / 1 | native +32 B calldata (`id`) and +32 B receipt (indexed topics) |
| Claim, first in a 256-index word | 145 | 147 | 1 / 1 | +1 bitmap slot on both |
| Claim, fresh token holder | 145 | 147 | 1 / 1 | +1 holder slot on both |
| Claim, fresh holder and first in word | 245 | 247 | 1 / 1 | |
| Relayed claim (third party pays, money goes to the leaf account) | 145 | 147 | relayer 1 | supported on both |
| Late claim after the native deadline | 145, **still paid** | 36, refused | 1 / 1 | the original never expires |
| Close and refund the remainder | not possible | 29 | — / anyone | MerkleDistributor has no sweep; unclaimed funds stay forever |
| Prune bitmap words (any count ≤ 8) | not possible | 25 | — / anyone | housekeeping only, refunds nothing |
| Rejected: replay / invalid proof / short proof | 33 / 33 / 32 | 36 / 34 / 35 | user pays | |
| Deficit (issuer seizes custody) | claims fail one by one when the balance is short | anyone latches the brake (21 u); every claim on the instance reverts until recapitalised (36 u per attempt) | | |

Exec gas per claim (warm holder, used word): original 56,903, native 78,225; prove gas 2,083 vs 3,470. Exec and prove are priced at 0 in this fee vector, so they do not change any fee here; they never bind the per-day ceilings (state does).

Fees: floor = U × 0.000001 DBLN. A warm claim costs 0.000045 (original) vs 0.000047 DBLN (native) at the floor, 0.000333 vs 0.000347 at debt 75,000, and 0.002457 vs 0.002566 at debt 99,999. Opening an allocation: 0.003026 vs 0.000380 DBLN at the floor, 0.022359 vs 0.002808 at debt 75,000.

Actions/day (state refill binds; 10 / 50 / 100 % of the refill): warm claim 6,144 / 30,720 / 61,440 (original, 45 u) vs 5,882 / 29,412 / 58,825 (native, 47 u). Opening an allocation: 91 / 456 / 913 (original) vs 727 / 3,637 / 7,275 (native). The five-claim mixed workflow: 381 / 1,906 / 3,813 vs 376 / 1,880 / 3,761.

## Cohorts (derived from the measured per-action units above)

| Scenario | Original total U (u/entitlement) | Native total U (u/entitlement) | Winner |
|---|---:|---:|---|
| H1: one 4,096-leaf allocation, all claimed, warm holders, instance already deployed (native closes and prunes 16 words) | 188,946 (46.13) | 194,571 (47.50) | **original, −2.9 %** |
| H1 with the native instance deployed for it | 188,946 (46.13) | 203,149 (49.60) | **original, −7.0 %** |
| H2: H1 with fresh holders (+100 u per holder on both) | 598,546 (146.13) | 604,171 (147.50) | original, −0.9 % |
| H3: 100 allocations × 256 leaves, all claimed, native instance deployed once | 1,464,600 (57.21) | 1,265,178 (49.42) | **native, −13.6 %** |
| H4: 10 % of 4,096 leaves claimed, spread over all 16 words | 23,076 (56.28) | 21,329 (52.02) | native, −7.6 % |

Break-even: on an existing instance native is cheaper for allocations up to **1,296 claimed entitlements**; from 1,297 the original wins (its per-claim saving of 2 u outweighs the 2,592 u per-allocation saving). The 8,478 u instance deploy is repaid after 5 allocations of 256 claims.

## Verdict

**Mixed: native wins many small or medium allocations, the original wins one large one.** Native removes the per-allocation 2,615 B deployment (3,026 → 380 u and two signatures → one), adds a deadline, a refund to a fixed recipient, pruning and a brake, and refuses late claims. The original wins every individual claim by 2 u (≈4 %: shorter calldata, unindexed event), wins any single allocation above ~1,300 claims, wins whenever only one allocation per token will ever exist, and never expires (a late recipient still gets paid). It also loses: an underfunded or seized distributor pays first-come claimers, and unclaimed tokens are locked forever. Native's shared balance means one deficit blocks every campaign on that instance (H9 is a loss of isolation, by design).

## How this was measured

- **Executor:** `aether_execution::execute_block`, replayed through `build_block` and `execute_block_sequential` (identical roots and receipts asserted), recorded with the Lane A0 workflow recorder (`eastsea.workflow-record/v1`). No node, app or RPC. aether-node `feat/native-measure-b` @ `6b39815`, tests `crates/contracts-onchain/tests/contracts_onchain/native_b_*.rs`.
- **Genesis and fees:** new-genesis B5 harness, chain 7795; 100,000 u bucket, 32 u/height refill; fee vector exec 0, prove 0, state floor 10^12 wei/u. Floor fee = U × 0.000001 DBLN. Congestion case: state debt 75,000 (×7.39 floor); the per-workflow table also gives debt 99,999 (×54.6).
- **Same everything except the contract:** one harness per path from the same genesis; the same exact-transfer test ERC-20 (`SeizableToken`) and DBLN funding; the same P-256 key per actor; the batching user is delegated to the genesis `EastSeaAccount` (account runtime `0xdeaca4e6…85288a`) in setup on both paths, so a batch is one signature on both paths. Actors 0–8 already hold the token (warm holders), 10–15 never did (fresh holders).
- **U** = 100·new accounts + 100·newly occupied slots + persisted code bytes + ⌈(envelope + metered receipt)/32⌉, decomposed from the pre/post state and asserted equal to the executor's figure. Clearing a slot refunds nothing.
- **Cold** = including the setup phase (wallet delegation, shared-instance deployment). **Warm** = without it.
- **Workflows/day** = recorder ceilings at 10/50/100% of every shared per-height capacity; the binding limit was the state refill in every workflow measured (every U ≥ envelope/32, and the 4,096 B/height payload refill is 4× that). Upper bounds, not throughput.
- Reproduce: `CONTRACTS_ONCHAIN_WORKFLOWS=$PWD/tmp/w.jsonl cargo test -p aether-contracts-onchain -j 4 --test contracts_onchain native_b -- --test-threads=1` (or `scripts/run-contracts-onchain.sh`).

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

## Raw records

Every transaction the comparison included, as recorded. `acct / slots / code / archive` is the unit split (100 u per new account and per newly occupied slot, 1 u per code byte, 1 u per 32 archive bytes). Workflow names are `<path>/<workflow>`; steps marked (setup) are excluded from warm totals. `issuer/seize` is the test token's issuer power, sent by a third actor.

### Raw: Per transaction

| Workflow | Step | Signer | Result | exec gas | prove gas | U | acct / slots / code / archive | envelope B | floor DBLN | debt 75k DBLN |
|---|---|---|---|---:|---:|---:|---|---:|---:|---:|
| original/open-campaign | EastSeaAccount/delegate-p256-account (setup) | user | ok | 38,377 | 186 | 45 | 0 / 0 / 23 / 22 | 448 | 0.000045 | 0.000333 |
| original/open-campaign | open/deploy-distributor | user | ok | 615,900 | 114 | 2,901 | 1 / 0 / 2,615 / 186 | 3,194 | 0.002901 | 0.021436 |
| original/open-campaign | open/fund-transfer | user | ok | 51,386 | 269 | 125 | 0 / 1 / 0 / 25 | 427 | 0.000125 | 0.000924 |
| original/open-campaign-repeat | open-repeat/deploy-distributor | user | ok | 615,900 | 114 | 2,901 | 1 / 0 / 2,615 / 186 | 3,194 | 0.002901 | 0.021436 |
| original/open-campaign-repeat | open-repeat/fund-transfer | user | ok | 51,386 | 269 | 125 | 0 / 1 / 0 / 25 | 427 | 0.000125 | 0.000924 |
| original/claims | claim/fresh-holder/first-in-word | user | ok | 91,067 | 2,076 | 245 | 0 / 2 / 0 / 45 | 907 | 0.000245 | 0.001810 |
| original/claims | claim/fresh-holder/same-word | user | ok | 73,943 | 2,069 | 145 | 0 / 1 / 0 / 45 | 907 | 0.000145 | 0.001071 |
| original/claims | claim/warm-holder/same-word | user | ok | 56,903 | 2,083 | 45 | 0 / 0 / 0 / 45 | 907 | 0.000045 | 0.000333 |
| original/claims | claim/warm-holder/first-in-word | user | ok | 73,907 | 2,048 | 145 | 0 / 1 / 0 / 45 | 907 | 0.000145 | 0.001071 |
| original/claims | claim/relayed/fresh-address | relayer | ok | 73,979 | 2,076 | 145 | 0 / 1 / 0 / 45 | 907 | 0.000145 | 0.001071 |
| original/rejected | reject/replay | user | revert | 38,720 | 227 | 33 | 0 / 0 / 0 / 33 | 907 | 0.000033 | 0.000244 |
| original/rejected | reject/invalid-proof | user | revert | 38,750 | 1,311 | 33 | 0 / 0 / 0 / 33 | 907 | 0.000033 | 0.000244 |
| original/rejected | reject/short-proof | user | revert | 37,500 | 1,244 | 32 | 0 / 0 / 0 / 32 | 875 | 0.000032 | 0.000236 |
| original/end-of-life | claim/late-still-paid | user | ok | 73,955 | 2,069 | 145 | 0 / 1 / 0 / 45 | 907 | 0.000145 | 0.001071 |
| original/deficit | issuer/seize | relayer | ok | 34,136 | 223 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| original/deficit | claim/blocked-by-deficit | user | revert | 44,932 | 1,835 | 34 | 0 / 0 / 0 / 34 | 907 | 0.000034 | 0.000251 |
| native/open-campaign | EastSeaAccount/delegate-p256-account (setup) | user | ok | 38,377 | 186 | 45 | 0 / 0 / 23 / 22 | 448 | 0.000045 | 0.000333 |
| native/open-campaign | setup/deploy-shared-instance (setup) | user | ok | 1,758,795 | 178 | 8,478 | 1 / 1 / 7,767 / 511 | 8,450 | 0.008478 | 0.062644 |
| native/open-campaign | open/batch-approve-create-approve0 | user | ok | 159,816 | 4,000 | 480 | 0 / 4 / 0 / 80 | 1,355 | 0.000480 | 0.003547 |
| native/open-campaign-repeat | open-repeat/batch-approve-create-approve0 | user | ok | 142,728 | 4,000 | 380 | 0 / 3 / 0 / 80 | 1,355 | 0.000380 | 0.002808 |
| native/claims | claim/fresh-holder/first-in-word | user | ok | 112,403 | 3,469 | 247 | 0 / 2 / 0 / 47 | 939 | 0.000247 | 0.001825 |
| native/claims | claim/fresh-holder/same-word | user | ok | 95,301 | 3,470 | 147 | 0 / 1 / 0 / 47 | 939 | 0.000147 | 0.001086 |
| native/claims | claim/warm-holder/same-word | user | ok | 78,225 | 3,470 | 47 | 0 / 0 / 0 / 47 | 939 | 0.000047 | 0.000347 |
| native/claims | claim/warm-holder/first-in-word | user | ok | 95,325 | 3,470 | 147 | 0 / 1 / 0 / 47 | 939 | 0.000147 | 0.001086 |
| native/claims | claim/relayed/fresh-address | relayer | ok | 95,335 | 3,471 | 147 | 0 / 1 / 0 / 47 | 939 | 0.000147 | 0.001086 |
| native/rejected | reject/replay | user | revert | 41,063 | 1,642 | 36 | 0 / 0 / 0 / 36 | 939 | 0.000036 | 0.000266 |
| native/rejected | reject/invalid-proof | user | revert | 39,220 | 1,570 | 34 | 0 / 0 / 0 / 34 | 939 | 0.000034 | 0.000251 |
| native/rejected | reject/short-proof | user | revert | 37,940 | 797 | 35 | 0 / 0 / 0 / 35 | 907 | 0.000035 | 0.000259 |
| native/rejected | reject/trip-brake-predicate-false | user | revert | 29,343 | 339 | 16 | 0 / 0 / 0 / 16 | 363 | 0.000016 | 0.000118 |
| native/end-of-life | claim/late-refused | user | revert | 39,220 | 332 | 36 | 0 / 0 / 0 / 36 | 939 | 0.000036 | 0.000266 |
| native/end-of-life | close/refund-remainder | relayer | ok | 52,620 | 1,943 | 29 | 0 / 0 / 0 / 29 | 395 | 0.000029 | 0.000214 |
| native/end-of-life | prune/2-touched-words | relayer | ok | 30,773 | 298 | 25 | 0 / 0 / 0 / 25 | 459 | 0.000025 | 0.000185 |
| native/deficit | issuer/seize | relayer | ok | 34,124 | 223 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native/deficit | brake/trip-latch | relayer | ok | 33,763 | 392 | 21 | 0 / 0 / 0 / 21 | 363 | 0.000021 | 0.000155 |
| native/deficit | claim/blocked-by-deficit | user | revert | 92,926 | 3,441 | 36 | 0 / 0 / 0 / 36 | 939 | 0.000036 | 0.000266 |

### Raw: Per workflow (cold = with setup; warm = without)

| Workflow | Tx cold/warm | User sigs cold/warm | Relayer tx | U cold | U warm | exec gas warm | prove gas warm | Floor warm DBLN | Debt 75k / 99,999 warm DBLN | Warm workflows/day at 10 / 50 / 100% (binding) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
| original/open-campaign | 3/2 | 3/2 | 0 | 3,071 | 3,026 | 667,286 | 383 | 0.003026 | 0.022359 / 0.165201 | 91 / 456 / 913 (state_refill) |
| original/open-campaign-repeat | 2/2 | 2/2 | 0 | 3,026 | 3,026 | 667,286 | 383 | 0.003026 | 0.022359 / 0.165201 | 91 / 456 / 913 (state_refill) |
| original/claims | 5/5 | 4/4 | 1 | 725 | 725 | 369,799 | 10,352 | 0.000725 | 0.005357 / 0.039580 | 381 / 1,906 / 3,813 (state_refill) |
| original/rejected | 3/3 | 3/3 | 0 | 98 | 98 | 114,970 | 2,782 | 0.000098 | 0.000724 / 0.005350 | 2,821 / 14,106 / 28,212 (state_refill) |
| original/end-of-life | 1/1 | 1/1 | 0 | 145 | 145 | 73,955 | 2,069 | 0.000145 | 0.001071 / 0.007916 | 1,906 / 9,533 / 19,067 (state_refill) |
| original/deficit | 2/2 | 1/1 | 1 | 58 | 58 | 79,068 | 2,058 | 0.000058 | 0.000429 / 0.003166 | 4,766 / 23,834 / 47,668 (state_refill) |
| native/open-campaign | 3/1 | 3/1 | 0 | 9,003 | 480 | 159,816 | 4,000 | 0.000480 | 0.003547 / 0.026205 | 576 / 2,880 / 5,760 (state_refill) |
| native/open-campaign-repeat | 1/1 | 1/1 | 0 | 380 | 380 | 142,728 | 4,000 | 0.000380 | 0.002808 / 0.020746 | 727 / 3,637 / 7,275 (state_refill) |
| native/claims | 5/5 | 4/4 | 1 | 735 | 735 | 476,589 | 17,350 | 0.000735 | 0.005431 / 0.040126 | 376 / 1,880 / 3,761 (state_refill) |
| native/rejected | 4/4 | 4/4 | 0 | 121 | 121 | 147,566 | 4,348 | 0.000121 | 0.000894 / 0.006606 | 2,284 / 11,424 / 22,849 (state_refill) |
| native/end-of-life | 3/3 | 1/1 | 2 | 90 | 90 | 122,613 | 2,573 | 0.000090 | 0.000665 / 0.004913 | 3,072 / 15,360 / 30,720 (state_refill) |
| native/deficit | 3/3 | 1/1 | 2 | 81 | 81 | 160,813 | 4,056 | 0.000081 | 0.000599 / 0.004422 | 3,413 / 17,066 / 34,133 (state_refill) |

### Raw: Failures (expected reverts; the signer pays)

| Workflow | Step | Payer | U | exec gas | Fee paid = floor DBLN |
|---|---|---|---:|---:|---:|
| original/rejected | reject/replay | user | 33 | 38,720 | 0.000033 |
| original/rejected | reject/invalid-proof | user | 33 | 38,750 | 0.000033 |
| original/rejected | reject/short-proof | user | 32 | 37,500 | 0.000032 |
| original/deficit | claim/blocked-by-deficit | user | 34 | 44,932 | 0.000034 |
| native/rejected | reject/replay | user | 36 | 41,063 | 0.000036 |
| native/rejected | reject/invalid-proof | user | 34 | 39,220 | 0.000034 |
| native/rejected | reject/short-proof | user | 35 | 37,940 | 0.000035 |
| native/rejected | reject/trip-brake-predicate-false | user | 16 | 29,343 | 0.000016 |
| native/end-of-life | claim/late-refused | user | 36 | 39,220 | 0.000036 |
| native/deficit | claim/blocked-by-deficit | user | 36 | 92,926 | 0.000036 |
