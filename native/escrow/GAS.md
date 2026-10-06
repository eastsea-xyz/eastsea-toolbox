# B2 Escrow: cost record (measured)

**Measured on the EastSea executor, head-to-head against the toolbox's `MilestoneEscrow`** (solc 0.8.24, Paris, optimizer 200; runtime 4,042 B; native DBLN only; guardian `address(0)`, so no brake key). Native: `EscrowBook` from this folder (solc 0.8.31, Osaka, optimizer 200; runtime 10,206 B) deployed with the same asset (DBLN), no arbiter. Kleros Escrow and Seaport were **not** run. The arbiter and ERC-20 instances, which the original cannot express, are recorded separately below. Deal: 1,000,000 wei, acceptance window 100 s, delivery window 1,000 s, ruling window 500 s.

## Head-to-head (warm unless stated; DBLN, existing accounts)

| Action | Original U | Native U | Signer |
|---|---:|---:|---|
| Shared instance deploy | 4,616 | 11,082 | deployer, once |
| Fund a deal | 426 (4 words) | 434 (4 words) | buyer |
| Seller accepts | no such step | 22 | seller |
| Release to seller | 125 (approve milestone: +1 slot, kept forever) | 22 (`release`) + 24 (`pay`, deletes the 4 words) | buyer / anyone |
| Seller collects | 22 (`sellerWithdraw`) | — (the `pay` above) | seller |
| **Full deal: fund → (accept) → release → paid** | **573**, 3 tx, 3 signatures | **502**, 4 tx, 4 signatures | |
| Full deal, cold (with wallet delegation and instance deploy) | 5,234 | 11,629 | |
| 60/40 split, both paid | **595**, 4 tx | 653, 6 tx (propose +1 slot, accept proposal, 2 payouts) | |
| Seller never shows up, buyer gets the money back | **448**, 2 tx, buyer only | 480, 3 tx; after `acceptBy` anyone can lapse and pay the buyer | |
| Silence after acceptance (deadline passes) | not possible: the buyer can always refund unapproved funds; a seller who delivered has no remedy | 46 per side (timeout 22 + pay 24) by anyone, either policy | relayer |
| Dispute → arbiter rules 70/30 → 2 payouts | not possible | 23 + 23 + 24 + 24 after accept | arbiter instance |
| Dispute → absent arbiter → timeout → refund | not possible | 23 + 22 + 24 | anyone |
| ERC-20 deal, 3-call batch create, fresh-holder seller | not possible (DBLN only) | 753 lifecycle (create 579 incl. first custody slot; pay 130 incl. holder slot) | |
| Rejected calls (wrong actor, duplicate, too early, stale, deleted deal, brake predicate false) | 17–21 | 16–19 | the signer |
| State left after a completed deal | 5 slots per deal, forever | 0 | |

Exec / prove gas for the full deal: original 225,313 / 1,349, native 241,453 / 2,420.

Fees at the floor (U × 0.000001 DBLN): full deal 0.000573 vs 0.000502 DBLN; at debt 75,000 0.004234 vs 0.003709; at debt 99,999 0.031282 vs 0.027406. These are network fees only; the escrowed amount is principal.

Actions/day (state refill binds; 10 / 50 / 100 %): full deal 482 / 2,412 / 4,825 (original) vs 550 / 2,753 / 5,507 (native). Split 464 / 2,323 / 4,646 vs 423 / 2,116 / 4,233. No-show refund 617 / 3,085 / 6,171 vs 576 / 2,880 / 5,760.

## Cohorts (derived from the measured units, warm deals on one instance)

| Completed deals | Original u/deal (incl. deploy) | Native u/deal (incl. deploy) |
|---:|---:|---:|
| 1 | **5,189** | 11,584 |
| 10 | **1,034.6** | 1,610.2 |
| 100 | 619.2 | **612.8** |
| 1,000 (H8, existing seller accounts) | 577.6 | **513.1** (design estimate 647.1 assumed fresh sellers) |

Break-even: native is cheaper from **92 completed deals** per instance.

## Verdict

**Native wins per deal (−12 %) and on outcomes; the original wins on signatures, splits, no-shows and small instances.** The plain deal costs 502 vs 573 u because the original's approval occupies a milestone flag slot that is never cleared, while native deletes its four words. Native needs one more transaction (seller acceptance), its split is 10 % dearer (653 vs 595 u, six transactions vs four), its no-show refund is 7 % dearer (480 vs 448 u), and its 10,206 B instance takes 92 deals to repay against the 4,042 B original. In exchange native adds what the original cannot do at any price: seller acceptance, an agreed silence policy anyone can apply after the deadline (the original leaves a seller who delivered to an absent buyer unpaid forever), an optional fixed arbiter with an absent-arbiter fallback, ERC-20 deals, payouts anyone can trigger and no state left behind. For an atomic on-chain swap neither is the right tool (Seaport, not measured).

## How this was measured

- **Executor:** `aether_execution::execute_block`, replayed through `build_block` and `execute_block_sequential` (identical roots and receipts asserted), recorded with the Lane A0 workflow recorder (`eastsea.workflow-record/v1`). No node, app or RPC. aether-node `feat/native-measure-b` @ `6b39815`, tests `crates/contracts-onchain/tests/contracts_onchain/native_b_*.rs`.
- **Genesis and fees:** new-genesis B5 harness, chain 7795; 100,000 u bucket, 32 u/height refill; fee vector exec 0, prove 0, state floor 10^12 wei/u. Floor fee = U × 0.000001 DBLN. Congestion case: state debt 75,000 (×7.39 floor); the per-workflow table also gives debt 99,999 (×54.6).
- **Same everything except the contract:** one harness per path from the same genesis; the same exact-transfer test ERC-20 (`SeizableToken`) and DBLN funding; the same P-256 key per actor; the batching user is delegated to the genesis `EastSeaAccount` (account runtime `0xdeaca4e6…85288a`) in setup on both paths, so a batch is one signature on both paths. Actors 0–8 already hold the token (warm holders), 10–15 never did (fresh holders).
- **U** = 100·new accounts + 100·newly occupied slots + persisted code bytes + ⌈(envelope + metered receipt)/32⌉, decomposed from the pre/post state and asserted equal to the executor's figure. Clearing a slot refunds nothing.
- **Cold** = including the setup phase (wallet delegation, shared-instance deployment). **Warm** = without it.
- **Workflows/day** = recorder ceilings at 10/50/100% of every shared per-height capacity; the binding limit was the state refill in every workflow measured (every U ≥ envelope/32, and the 4,096 B/height payload refill is 4× that). Upper bounds, not throughput.
- Reproduce: `CONTRACTS_ONCHAIN_WORKFLOWS=$PWD/tmp/w.jsonl cargo test -p aether-contracts-onchain -j 4 --test contracts_onchain native_b -- --test-threads=1` (or `scripts/run-contracts-onchain.sh`).

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

## Raw records

Every transaction the comparison included, as recorded. `acct / slots / code / archive` is the unit split (100 u per new account and per newly occupied slot, 1 u per code byte, 1 u per 32 archive bytes). Workflow names are `<path>/<workflow>`; steps marked (setup) are excluded from warm totals. `issuer/seize` is the test token's issuer power, sent by a third actor.

### Raw: Per transaction

| Workflow | Step | Signer | Result | exec gas | prove gas | U | acct / slots / code / archive | envelope B | floor DBLN | debt 75k DBLN |
|---|---|---|---|---:|---:|---:|---|---:|---:|---:|
| original/deal-lifecycle-cold | EastSeaAccount/delegate-p256-account (setup) | user | ok | 38,377 | 186 | 45 | 0 / 0 / 23 / 22 | 448 | 0.000045 | 0.000333 |
| original/deal-lifecycle-cold | setup/deploy-shared-instance (setup) | user | ok | 971,858 | 101 | 4,616 | 1 / 2 / 4,042 / 274 | 4,575 | 0.004616 | 0.034108 |
| original/deal-lifecycle-cold | create/fund | user | ok | 124,132 | 565 | 426 | 0 / 4 / 0 / 26 | 427 | 0.000426 | 0.003148 |
| original/deal-lifecycle-cold | release/approve-milestone | user | ok | 58,861 | 471 | 125 | 0 / 1 / 0 / 25 | 459 | 0.000125 | 0.000924 |
| original/deal-lifecycle-cold | pay/seller-withdraw | user | ok | 42,320 | 313 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| original/deal-lifecycle-warm | create/fund | user | ok | 124,132 | 565 | 426 | 0 / 4 / 0 / 26 | 427 | 0.000426 | 0.003148 |
| original/deal-lifecycle-warm | release/approve-milestone | user | ok | 58,861 | 471 | 125 | 0 / 1 / 0 / 25 | 459 | 0.000125 | 0.000924 |
| original/deal-lifecycle-warm | pay/seller-withdraw | user | ok | 42,320 | 313 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| original/split | create/fund | user | ok | 124,132 | 565 | 426 | 0 / 4 / 0 / 26 | 427 | 0.000426 | 0.003148 |
| original/split | split/approve-milestone-60 | user | ok | 58,861 | 471 | 125 | 0 / 1 / 0 / 25 | 459 | 0.000125 | 0.000924 |
| original/split | pay/buyer-refund-40 | user | ok | 42,728 | 309 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| original/split | pay/seller-withdraw-60 | user | ok | 42,320 | 313 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| original/no-show | create/fund | user | ok | 124,132 | 565 | 426 | 0 / 4 / 0 / 26 | 427 | 0.000426 | 0.003148 |
| original/no-show | pay/buyer-refund | user | ok | 37,928 | 309 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| original/rejected | create/fund | user | ok | 124,132 | 565 | 426 | 0 / 4 / 0 / 26 | 427 | 0.000426 | 0.003148 |
| original/rejected | reject/wrong-actor | user | revert | 31,351 | 181 | 19 | 0 / 0 / 0 / 19 | 459 | 0.000019 | 0.000140 |
| original/rejected | release/approve-milestone-50 | user | ok | 58,861 | 471 | 125 | 0 / 1 / 0 / 25 | 459 | 0.000125 | 0.000924 |
| original/rejected | reject/duplicate-milestone | user | revert | 36,020 | 301 | 21 | 0 / 0 / 0 / 21 | 459 | 0.000021 | 0.000155 |
| original/rejected | reject/nothing-to-withdraw | user | revert | 33,289 | 192 | 17 | 0 / 0 / 0 / 17 | 395 | 0.000017 | 0.000126 |
| native/deal-lifecycle-cold | EastSeaAccount/delegate-p256-account (setup) | user | ok | 38,377 | 186 | 45 | 0 / 0 / 23 / 22 | 448 | 0.000045 | 0.000333 |
| native/deal-lifecycle-cold | setup/deploy-shared-instance (setup) | user | ok | 2,284,891 | 368 | 11,082 | 1 / 1 / 10,206 / 676 | 11,280 | 0.011082 | 0.081886 |
| native/deal-lifecycle-cold | create/fund | user | ok | 126,361 | 1,340 | 434 | 0 / 4 / 0 / 34 | 555 | 0.000434 | 0.003207 |
| native/deal-lifecycle-cold | accept | user | ok | 30,802 | 196 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/deal-lifecycle-cold | release | user | ok | 36,326 | 327 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/deal-lifecycle-cold | pay/seller-final-deletes-record | user | ok | 47,964 | 557 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native/deal-lifecycle-warm | create/fund | user | ok | 126,361 | 1,340 | 434 | 0 / 4 / 0 / 34 | 555 | 0.000434 | 0.003207 |
| native/deal-lifecycle-warm | accept | user | ok | 30,802 | 196 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/deal-lifecycle-warm | release | user | ok | 36,326 | 327 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/deal-lifecycle-warm | pay/seller-final-deletes-record | user | ok | 47,964 | 557 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native/split | create/fund | user | ok | 126,349 | 1,340 | 434 | 0 / 4 / 0 / 34 | 555 | 0.000434 | 0.003207 |
| native/split | accept | user | ok | 30,802 | 196 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/split | split/propose-60-first | user | ok | 51,523 | 440 | 125 | 0 / 1 / 0 / 25 | 427 | 0.000125 | 0.000924 |
| native/split | split/accept-proposal | user | ok | 37,725 | 556 | 24 | 0 / 0 / 0 / 24 | 459 | 0.000024 | 0.000177 |
| native/split | pay/buyer-40 | user | ok | 47,410 | 552 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native/split | pay/seller-60-final-deletes-record | user | ok | 47,964 | 557 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native/no-show | create/fund | user | ok | 126,361 | 1,340 | 434 | 0 / 4 / 0 / 34 | 555 | 0.000434 | 0.003207 |
| native/no-show | cancel/by-buyer | user | ok | 33,324 | 295 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/no-show | pay/buyer-refund-final | user | ok | 50,184 | 604 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native/no-show | create/fund-2 | user | ok | 126,361 | 1,340 | 434 | 0 / 4 / 0 / 34 | 555 | 0.000434 | 0.003207 |
| native/no-show | cancel/lapse-by-anyone | relayer | ok | 33,469 | 311 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/no-show | pay/buyer-refund-by-anyone | relayer | ok | 52,184 | 604 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native/silence | create/fund-buyer-refund-policy | user | ok | 126,361 | 1,340 | 434 | 0 / 4 / 0 / 34 | 555 | 0.000434 | 0.003207 |
| native/silence | accept | user | ok | 30,802 | 196 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/silence | create/fund-seller-payment-policy | user | ok | 126,373 | 1,340 | 434 | 0 / 4 / 0 / 34 | 555 | 0.000434 | 0.003207 |
| native/silence | accept-2 | user | ok | 30,802 | 196 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/silence | timeout/buyer-refund-policy | relayer | ok | 35,485 | 316 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/silence | pay/buyer-by-anyone | relayer | ok | 52,184 | 604 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native/silence | timeout/seller-payment-policy | relayer | ok | 38,411 | 326 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/silence | pay/seller-by-anyone | relayer | ok | 49,964 | 557 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native/rejected | create/fund | user | ok | 126,361 | 1,340 | 434 | 0 / 4 / 0 / 34 | 555 | 0.000434 | 0.003207 |
| native/rejected | reject/wrong-actor | user | revert | 26,121 | 164 | 17 | 0 / 0 / 0 / 17 | 395 | 0.000017 | 0.000126 |
| native/rejected | accept | user | ok | 30,802 | 196 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native/rejected | reject/seller-cannot-release | user | revert | 24,164 | 178 | 17 | 0 / 0 / 0 / 17 | 395 | 0.000017 | 0.000126 |
| native/rejected | reject/timeout-too-early | relayer | revert | 26,080 | 156 | 17 | 0 / 0 / 0 / 17 | 395 | 0.000017 | 0.000126 |
| native/rejected | reject/stale-proposal | user | revert | 29,214 | 343 | 19 | 0 / 0 / 0 / 19 | 459 | 0.000019 | 0.000140 |
| native/rejected | reject/pay-deleted-deal | user | revert | 24,371 | 171 | 19 | 0 / 0 / 0 / 19 | 427 | 0.000019 | 0.000140 |
| native/rejected | reject/trip-brake-predicate-false | relayer | revert | 23,933 | 164 | 16 | 0 / 0 / 0 / 16 | 363 | 0.000016 | 0.000118 |
| native-arbiter/dispute | setup/deploy-arbiter-instance (setup) | user | ok | 2,285,155 | 368 | 11,082 | 1 / 1 / 10,206 / 676 | 11,280 | 0.011082 | 0.081886 |
| native-arbiter/dispute | create/fund | user | ok | 126,471 | 1,375 | 434 | 0 / 4 / 0 / 34 | 555 | 0.000434 | 0.003207 |
| native-arbiter/dispute | accept | user | ok | 30,802 | 196 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native-arbiter/dispute | dispute | user | ok | 31,433 | 286 | 23 | 0 / 0 / 0 / 23 | 395 | 0.000023 | 0.000170 |
| native-arbiter/dispute | rule/70-30 | user | ok | 36,612 | 368 | 23 | 0 / 0 / 0 / 23 | 427 | 0.000023 | 0.000170 |
| native-arbiter/dispute | pay/seller-70 | user | ok | 46,635 | 505 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native-arbiter/dispute | pay/buyer-30-final | user | ok | 50,184 | 604 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native-arbiter/dispute | create/fund-2 | user | ok | 126,471 | 1,375 | 434 | 0 / 4 / 0 / 34 | 555 | 0.000434 | 0.003207 |
| native-arbiter/dispute | accept-2 | user | ok | 30,802 | 196 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native-arbiter/dispute | dispute-2 | user | ok | 31,287 | 271 | 23 | 0 / 0 / 0 / 23 | 395 | 0.000023 | 0.000170 |
| native-arbiter/dispute | timeout/absent-arbiter | relayer | ok | 35,511 | 323 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native-arbiter/dispute | pay/buyer-by-anyone | relayer | ok | 52,184 | 604 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native-erc20/deal-lifecycle | setup/deploy-erc20-instance (setup) | user | ok | 2,287,886 | 386 | 11,082 | 1 / 1 / 10,206 / 676 | 11,280 | 0.011082 | 0.081886 |
| native-erc20/deal-lifecycle | create/batch-approve-create-approve0 | user | ok | 183,191 | 4,273 | 579 | 0 / 5 / 0 / 79 | 1,323 | 0.000579 | 0.004278 |
| native-erc20/deal-lifecycle | accept | user | ok | 30,802 | 196 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native-erc20/deal-lifecycle | release | user | ok | 36,326 | 327 | 22 | 0 / 0 / 0 / 22 | 395 | 0.000022 | 0.000163 |
| native-erc20/deal-lifecycle | pay/fresh-holder-seller-final | user | ok | 72,800 | 2,085 | 130 | 0 / 1 / 0 / 30 | 427 | 0.000130 | 0.000961 |

### Raw: Per workflow (cold = with setup; warm = without)

| Workflow | Tx cold/warm | User sigs cold/warm | Relayer tx | U cold | U warm | exec gas warm | prove gas warm | Floor warm DBLN | Debt 75k / 99,999 warm DBLN | Warm workflows/day at 10 / 50 / 100% (binding) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
| original/deal-lifecycle-cold | 5/3 | 5/3 | 0 | 5,234 | 573 | 225,313 | 1,349 | 0.000573 | 0.004234 / 0.031282 | 482 / 2,412 / 4,825 (state_refill) |
| original/deal-lifecycle-warm | 3/3 | 3/3 | 0 | 573 | 573 | 225,313 | 1,349 | 0.000573 | 0.004234 / 0.031282 | 482 / 2,412 / 4,825 (state_refill) |
| original/split | 4/4 | 4/4 | 0 | 595 | 595 | 268,041 | 1,658 | 0.000595 | 0.004396 / 0.032483 | 464 / 2,323 / 4,646 (state_refill) |
| original/no-show | 2/2 | 2/2 | 0 | 448 | 448 | 162,060 | 874 | 0.000448 | 0.003310 / 0.024458 | 617 / 3,085 / 6,171 (state_refill) |
| original/rejected | 5/5 | 5/5 | 0 | 608 | 608 | 283,653 | 1,710 | 0.000608 | 0.004493 / 0.033193 | 454 / 2,273 / 4,547 (state_refill) |
| native/deal-lifecycle-cold | 6/4 | 6/4 | 0 | 11,629 | 502 | 241,453 | 2,420 | 0.000502 | 0.003709 / 0.027406 | 550 / 2,753 / 5,507 (state_refill) |
| native/deal-lifecycle-warm | 4/4 | 4/4 | 0 | 502 | 502 | 241,453 | 2,420 | 0.000502 | 0.003709 / 0.027406 | 550 / 2,753 / 5,507 (state_refill) |
| native/split | 6/6 | 6/6 | 0 | 653 | 653 | 341,773 | 3,641 | 0.000653 | 0.004825 / 0.035650 | 423 / 2,116 / 4,233 (state_refill) |
| native/no-show | 6/6 | 4/4 | 2 | 960 | 960 | 421,883 | 4,494 | 0.000960 | 0.007093 / 0.052410 | 288 / 1,440 / 2,880 (state_refill) |
| native/silence | 8/8 | 4/4 | 4 | 1,004 | 1,004 | 490,382 | 4,875 | 0.001004 | 0.007419 / 0.054812 | 275 / 1,376 / 2,753 (state_refill) |
| native/rejected | 8/8 | 6/6 | 2 | 561 | 561 | 311,046 | 2,712 | 0.000561 | 0.004145 / 0.030627 | 492 / 2,464 / 4,928 (state_refill) |
| native-arbiter/dispute | 12/11 | 10/9 | 2 | 12,157 | 1,075 | 598,392 | 6,103 | 0.001075 | 0.007943 / 0.058688 | 257 / 1,285 / 2,571 (state_refill) |
| native-erc20/deal-lifecycle | 5/4 | 5/4 | 0 | 11,835 | 753 | 323,119 | 6,881 | 0.000753 | 0.005564 / 0.041109 | 367 / 1,835 / 3,671 (state_refill) |

### Raw: Failures (expected reverts; the signer pays)

| Workflow | Step | Payer | U | exec gas | Fee paid = floor DBLN |
|---|---|---|---:|---:|---:|
| original/rejected | reject/wrong-actor | user | 19 | 31,351 | 0.000019 |
| original/rejected | reject/duplicate-milestone | user | 21 | 36,020 | 0.000021 |
| original/rejected | reject/nothing-to-withdraw | user | 17 | 33,289 | 0.000017 |
| native/rejected | reject/wrong-actor | user | 17 | 26,121 | 0.000017 |
| native/rejected | reject/seller-cannot-release | user | 17 | 24,164 | 0.000017 |
| native/rejected | reject/timeout-too-early | relayer | 17 | 26,080 | 0.000017 |
| native/rejected | reject/stale-proposal | user | 19 | 29,214 | 0.000019 |
| native/rejected | reject/pay-deleted-deal | user | 19 | 24,371 | 0.000019 |
| native/rejected | reject/trip-brake-predicate-false | relayer | 16 | 23,933 | 0.000016 |
