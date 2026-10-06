# B1 Streams and vesting: cost record (measured)

**Measured on the EastSea executor, head-to-head against two toolbox originals** (compiled as in the toolbox examples: solc 0.8.24, Paris, optimizer 200): `LinearVesting` (one deployment per grant, runtime 2,011 B) and `TokenTimeLock` (one shared instance, one lock per beneficiary, runtime 3,827 B; guardian set to `address(0)`, so it has no brake key). Native: `GrantLedger` from this folder (solc 0.8.31, Osaka, optimizer 200; runtime 6,681 B). Sablier Lockup (BUSL-1.1) was **not** run; the toolbox originals have the same cliff-to-end curve with no catch-up at the cliff, so there is no curve mismatch. Grant: 4,000 tokens, cliff 100 s, end 500 s; claims at 25/50/75/100 % of the accrual window.

## Head-to-head (warm unless stated)

| Action | LinearVesting U | TokenTimeLock U | GrantLedger (native) U | Signatures (LV / TTL / native) |
|---|---:|---:|---:|---|
| Shared instance deploy (once per token) | — | 4,292 | 7,324 | — / 1 / 1 |
| Fund one grant | **2,635** (approve predicted address 125 + deploy 2,510) | **274** | 277 | 2 / 1 / 1 |
| First grant on a new or drained instance (+ custody balance slot) | 2,635 | 374 | 377 | |
| Claim, partial or final, warm holder | 28 (first claim 128: `claimed` slot) | **27** | 30 | 1 / 1 / 1 |
| Claim, fresh holder (first claim) | 228 | 127 | 130 | |
| Grant lifecycle (fund + 4 claims), warm holder | 2,847 | **382** | 397 | 6 / 5 / 5 |
| Grant lifecycle, cold (fresh holder, with setup and deploy) | 3,014 | 4,935 | 7,984 | 8 / 8 / 8 |
| 8 grants at once | 21,014 (one batch of 8 approvals + 8 deploys) | 1,842 (one batch: 8 × `lockFor`) | **1,784** (`createBatch`) / 1,866 (8 × `create` in one batch) | 9 / 1 / 1 |
| Relayed claim | 128, supported | 16, refused (only the beneficiary can release) | 30, supported | relayer pays |
| Claim before the cliff | 22, **succeeds and pays 0** | 16, refused | 18, refused | |
| Unknown id / second concurrent grant to the same beneficiary | n/a / allowed (new deploy) | n/a / **refused** (49 u) | 18 refused / allowed | |
| Deficit (issuer seizes custody) | that grant's claim fails (17 u) | **next claim succeeds, paid from other grants' backing** | anyone latches the brake (21 u); claims revert (19 u) until recapitalised | |
| State left after the final claim | account + 2,011 B code + 2 slots, forever | 2 slots per grant, forever | 0 (both words deleted) | |

Exec / prove gas per partial claim (warm): LinearVesting 47,667 / 939, TokenTimeLock 50,522 / 1,001, GrantLedger 58,714 / 2,175. Grant funding: LinearVesting 610,320 / 1,671, TokenTimeLock 113,103 / 3,208, GrantLedger 119,654 / 4,421.

Fees at the floor (U × 0.000001 DBLN): warm lifecycle 0.002847 / 0.000382 / 0.000397 DBLN; at debt 75,000: 0.021037 / 0.002823 / 0.002933; at debt 99,999: 0.155 / 0.0209 / 0.0217.

Actions/day (state refill binds; 10 / 50 / 100 %): warm grant lifecycle 97 / 485 / 971 (LinearVesting), 723 / 3,618 / 7,237 (TokenTimeLock), 696 / 3,482 / 6,964 (native). Partial claim: 9,874 / 49,371 / 98,742 (28 u), 10,240 / 51,200 / 102,400 (27 u), 9,216 / 46,080 / 92,160 (30 u).

## Cohorts (derived from the measured per-action units)

| Grants (fund + 4 claims each, warm holders) | LinearVesting u/grant | TokenTimeLock u/grant (incl. deploy) | GrantLedger u/grant (incl. deploy) |
|---:|---:|---:|---:|
| 1 | **2,847** | 4,774 | 7,821 |
| 4 | 2,847 | **1,480** | 2,253 (native passes LinearVesting here) |
| 100 (H2) | 2,847 | **425.9** | 471.2 (design estimate 469.65) |
| 1,000 | 2,847 | **386.4** | 404.4 |

H3 (fresh beneficiary balances) adds 100 u per holder on every path; LinearVesting's first claim also pays its `claimed` slot (+100) on every grant.

## Verdict

**Native beats the per-grant original by about 7× from four grants up; it loses narrowly on cost to the shared TokenTimeLock.** Against LinearVesting the shared ledger removes a 2,011 B deploy and an allowance slot per grant (2,847 → 397 u, 6 → 5 signatures; 8 grants: 9 signatures → 1). LinearVesting wins only for one to three grants per token, and its premature claim "succeeds" and charges for nothing. Against TokenTimeLock the original is **3–4 % cheaper** per grant (27 vs 30 u per claim: no `id` argument, fewer indexed topics; 4,292 vs 7,324 u deploy). What native buys for that: relayed claims, any number of grants per beneficiary, solvency isolation (TokenTimeLock pays one beneficiary out of other grants' backing after a seizure), deletion at the final claim, and a keyless brake. Cancellation (H10) is supported by none of the three; Sablier Lockup cancelable remains the only option there and was not measured.

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

## Raw records

Every transaction the comparison included, as recorded. `acct / slots / code / archive` is the unit split (100 u per new account and per newly occupied slot, 1 u per code byte, 1 u per 32 archive bytes). Workflow names are `<path>/<workflow>`; steps marked (setup) are excluded from warm totals. `issuer/seize` is the test token's issuer power, sent by a third actor.

### Raw: Per transaction

| Workflow | Step | Signer | Result | exec gas | prove gas | U | acct / slots / code / archive | envelope B | floor DBLN | debt 75k DBLN |
|---|---|---|---|---:|---:|---:|---|---:|---:|---:|
| original-linearvesting/grant-lifecycle-cold | EastSeaAccount/delegate-p256-account (setup) | user | ok | 38,377 | 186 | 45 | 0 / 0 / 23 / 22 | 448 | 0.000045 | 0.000333 |
| original-linearvesting/grant-lifecycle-cold | create/approve-predicted | user | ok | 46,074 | 171 | 125 | 0 / 1 / 0 / 25 | 427 | 0.000125 | 0.000924 |
| original-linearvesting/grant-lifecycle-cold | create/deploy-per-grant | user | ok | 564,246 | 1,500 | 2,510 | 1 / 2 / 2,011 / 199 | 4,010 | 0.002510 | 0.018547 |
| original-linearvesting/grant-lifecycle-cold | claim/before-cliff | user | ok | 27,453 | 178 | 22 | 0 / 0 / 0 / 22 | 363 | 0.000022 | 0.000163 |
| original-linearvesting/grant-lifecycle-cold | claim/1-partial | user | ok | 81,867 | 939 | 228 | 0 / 2 / 0 / 28 | 363 | 0.000228 | 0.001685 |
| original-linearvesting/grant-lifecycle-cold | claim/2-partial | user | ok | 47,667 | 939 | 28 | 0 / 0 / 0 / 28 | 363 | 0.000028 | 0.000207 |
| original-linearvesting/grant-lifecycle-cold | claim/3-partial | user | ok | 47,667 | 939 | 28 | 0 / 0 / 0 / 28 | 363 | 0.000028 | 0.000207 |
| original-linearvesting/grant-lifecycle-cold | claim/4-final | user | ok | 42,527 | 839 | 28 | 0 / 0 / 0 / 28 | 363 | 0.000028 | 0.000207 |
| original-linearvesting/grant-lifecycle-warm | create/approve-predicted | user | ok | 46,074 | 171 | 125 | 0 / 1 / 0 / 25 | 427 | 0.000125 | 0.000924 |
| original-linearvesting/grant-lifecycle-warm | create/deploy-per-grant | user | ok | 564,246 | 1,500 | 2,510 | 1 / 2 / 2,011 / 199 | 4,010 | 0.002510 | 0.018547 |
| original-linearvesting/grant-lifecycle-warm | claim/1-partial | user | ok | 64,767 | 939 | 128 | 0 / 1 / 0 / 28 | 363 | 0.000128 | 0.000946 |
| original-linearvesting/grant-lifecycle-warm | claim/2-partial | user | ok | 47,667 | 939 | 28 | 0 / 0 / 0 / 28 | 363 | 0.000028 | 0.000207 |
| original-linearvesting/grant-lifecycle-warm | claim/3-partial | user | ok | 47,667 | 939 | 28 | 0 / 0 / 0 / 28 | 363 | 0.000028 | 0.000207 |
| original-linearvesting/grant-lifecycle-warm | claim/4-final | user | ok | 42,527 | 839 | 28 | 0 / 0 / 0 / 28 | 363 | 0.000028 | 0.000207 |
| original-linearvesting/create-8 | create-8/batch-approve-8-predicted | user | ok | 245,062 | 4,546 | 934 | 0 / 8 / 0 / 134 | 2,475 | 0.000934 | 0.006901 |
| original-linearvesting/create-8 | create-8/deploy-1 | user | ok | 564,246 | 1,500 | 2,510 | 1 / 2 / 2,011 / 199 | 4,010 | 0.002510 | 0.018547 |
| original-linearvesting/create-8 | create-8/deploy-2 | user | ok | 564,246 | 1,500 | 2,510 | 1 / 2 / 2,011 / 199 | 4,010 | 0.002510 | 0.018547 |
| original-linearvesting/create-8 | create-8/deploy-3 | user | ok | 564,246 | 1,500 | 2,510 | 1 / 2 / 2,011 / 199 | 4,010 | 0.002510 | 0.018547 |
| original-linearvesting/create-8 | create-8/deploy-4 | user | ok | 564,246 | 1,500 | 2,510 | 1 / 2 / 2,011 / 199 | 4,010 | 0.002510 | 0.018547 |
| original-linearvesting/create-8 | create-8/deploy-5 | user | ok | 564,246 | 1,500 | 2,510 | 1 / 2 / 2,011 / 199 | 4,010 | 0.002510 | 0.018547 |
| original-linearvesting/create-8 | create-8/deploy-6 | user | ok | 564,246 | 1,500 | 2,510 | 1 / 2 / 2,011 / 199 | 4,010 | 0.002510 | 0.018547 |
| original-linearvesting/create-8 | create-8/deploy-7 | user | ok | 564,246 | 1,500 | 2,510 | 1 / 2 / 2,011 / 199 | 4,010 | 0.002510 | 0.018547 |
| original-linearvesting/create-8 | create-8/deploy-8 | user | ok | 564,246 | 1,500 | 2,510 | 1 / 2 / 2,011 / 199 | 4,010 | 0.002510 | 0.018547 |
| original-linearvesting/relayed-rejected-deficit | create/approve-predicted | user | ok | 46,074 | 171 | 125 | 0 / 1 / 0 / 25 | 427 | 0.000125 | 0.000924 |
| original-linearvesting/relayed-rejected-deficit | create/deploy-per-grant | user | ok | 564,246 | 1,500 | 2,510 | 1 / 2 / 2,011 / 199 | 4,010 | 0.002510 | 0.018547 |
| original-linearvesting/relayed-rejected-deficit | claim/relayed | relayer | ok | 64,767 | 939 | 128 | 0 / 1 / 0 / 28 | 363 | 0.000128 | 0.000946 |
| original-linearvesting/relayed-rejected-deficit | issuer/seize | relayer | ok | 34,124 | 223 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| original-linearvesting/relayed-rejected-deficit | claim/blocked-by-deficit | user | revert | 38,333 | 636 | 17 | 0 / 0 / 0 / 17 | 363 | 0.000017 | 0.000126 |
| original-tokentimelock/grant-lifecycle-cold | EastSeaAccount/delegate-p256-account (setup) | user | ok | 38,377 | 186 | 45 | 0 / 0 / 23 / 22 | 448 | 0.000045 | 0.000333 |
| original-tokentimelock/grant-lifecycle-cold | setup/deploy-shared-instance (setup) | user | ok | 906,919 | 173 | 4,292 | 1 / 1 / 3,827 / 265 | 4,495 | 0.004292 | 0.031714 |
| original-tokentimelock/grant-lifecycle-cold | create/batch-approve-lockFor-approve0 | user | ok | 130,203 | 3,208 | 374 | 0 / 3 / 0 / 74 | 1,259 | 0.000374 | 0.002764 |
| original-tokentimelock/grant-lifecycle-cold | claim/before-cliff | user | revert | 31,255 | 215 | 16 | 0 / 0 / 0 / 16 | 363 | 0.000016 | 0.000118 |
| original-tokentimelock/grant-lifecycle-cold | claim/1-partial | user | ok | 67,622 | 1,001 | 127 | 0 / 1 / 0 / 27 | 363 | 0.000127 | 0.000938 |
| original-tokentimelock/grant-lifecycle-cold | claim/2-partial | user | ok | 50,522 | 1,001 | 27 | 0 / 0 / 0 / 27 | 363 | 0.000027 | 0.000200 |
| original-tokentimelock/grant-lifecycle-cold | claim/3-partial | user | ok | 50,522 | 1,001 | 27 | 0 / 0 / 0 / 27 | 363 | 0.000027 | 0.000200 |
| original-tokentimelock/grant-lifecycle-cold | claim/4-final | user | ok | 45,128 | 883 | 27 | 0 / 0 / 0 / 27 | 363 | 0.000027 | 0.000200 |
| original-tokentimelock/grant-lifecycle-warm | create/batch-approve-lockFor-approve0 | user | ok | 113,103 | 3,208 | 274 | 0 / 2 / 0 / 74 | 1,259 | 0.000274 | 0.002025 |
| original-tokentimelock/grant-lifecycle-warm | claim/1-partial | user | ok | 50,522 | 1,001 | 27 | 0 / 0 / 0 / 27 | 363 | 0.000027 | 0.000200 |
| original-tokentimelock/grant-lifecycle-warm | claim/2-partial | user | ok | 50,522 | 1,001 | 27 | 0 / 0 / 0 / 27 | 363 | 0.000027 | 0.000200 |
| original-tokentimelock/grant-lifecycle-warm | claim/3-partial | user | ok | 50,522 | 1,001 | 27 | 0 / 0 / 0 / 27 | 363 | 0.000027 | 0.000200 |
| original-tokentimelock/grant-lifecycle-warm | claim/4-final | user | ok | 49,928 | 883 | 27 | 0 / 0 / 0 / 27 | 363 | 0.000027 | 0.000200 |
| original-tokentimelock/create-8 | create-8/batch-approve-8xlockFor-approve0 | user | ok | 522,920 | 16,732 | 1,842 | 0 / 16 / 0 / 242 | 3,499 | 0.001842 | 0.013611 |
| original-tokentimelock/relayed-rejected-deficit | create/batch-approve-lockFor-approve0 | user | ok | 113,103 | 3,208 | 274 | 0 / 2 / 0 / 74 | 1,259 | 0.000274 | 0.002025 |
| original-tokentimelock/relayed-rejected-deficit | claim/relayed-unsupported | relayer | revert | 28,898 | 165 | 16 | 0 / 0 / 0 / 16 | 363 | 0.000016 | 0.000118 |
| original-tokentimelock/relayed-rejected-deficit | reject/second-concurrent-grant-same-beneficiary | user | revert | 69,707 | 1,426 | 49 | 0 / 0 / 0 / 49 | 1,259 | 0.000049 | 0.000362 |
| original-tokentimelock/relayed-rejected-deficit | issuer/seize | relayer | ok | 34,124 | 223 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| original-tokentimelock/relayed-rejected-deficit | claim/paid-from-other-grants-backing | user | ok | 49,928 | 883 | 27 | 0 / 0 / 0 / 27 | 363 | 0.000027 | 0.000200 |
| native/grant-lifecycle-cold | EastSeaAccount/delegate-p256-account (setup) | user | ok | 38,377 | 186 | 45 | 0 / 0 / 23 / 22 | 448 | 0.000045 | 0.000333 |
| native/grant-lifecycle-cold | setup/deploy-shared-instance (setup) | user | ok | 1,524,013 | 178 | 7,324 | 1 / 1 / 6,681 / 443 | 7,364 | 0.007324 | 0.054117 |
| native/grant-lifecycle-cold | create/batch-approve-create-approve0 | user | ok | 136,754 | 4,421 | 377 | 0 / 3 / 0 / 77 | 1,291 | 0.000377 | 0.002786 |
| native/grant-lifecycle-cold | claim/before-cliff | user | revert | 26,648 | 242 | 18 | 0 / 0 / 0 / 18 | 395 | 0.000018 | 0.000133 |
| native/grant-lifecycle-cold | claim/1-partial | user | ok | 75,814 | 2,175 | 130 | 0 / 1 / 0 / 30 | 395 | 0.000130 | 0.000961 |
| native/grant-lifecycle-cold | claim/2-partial | user | ok | 58,714 | 2,175 | 30 | 0 / 0 / 0 / 30 | 395 | 0.000030 | 0.000222 |
| native/grant-lifecycle-cold | claim/3-partial | user | ok | 58,714 | 2,175 | 30 | 0 / 0 / 0 / 30 | 395 | 0.000030 | 0.000222 |
| native/grant-lifecycle-cold | claim/4-final | user | ok | 48,873 | 2,036 | 30 | 0 / 0 / 0 / 30 | 395 | 0.000030 | 0.000222 |
| native/grant-lifecycle-warm | create/batch-approve-create-approve0 | user | ok | 119,654 | 4,421 | 277 | 0 / 2 / 0 / 77 | 1,291 | 0.000277 | 0.002047 |
| native/grant-lifecycle-warm | claim/1-partial | user | ok | 58,714 | 2,175 | 30 | 0 / 0 / 0 / 30 | 395 | 0.000030 | 0.000222 |
| native/grant-lifecycle-warm | claim/2-partial | user | ok | 58,714 | 2,175 | 30 | 0 / 0 / 0 / 30 | 395 | 0.000030 | 0.000222 |
| native/grant-lifecycle-warm | claim/3-partial | user | ok | 58,714 | 2,175 | 30 | 0 / 0 / 0 / 30 | 395 | 0.000030 | 0.000222 |
| native/grant-lifecycle-warm | claim/4-final | user | ok | 51,491 | 2,036 | 30 | 0 / 0 / 0 / 30 | 395 | 0.000030 | 0.000222 |
| native/create-8 | create-8/batch-approve-createBatch8-approve0 | user | ok | 482,738 | 12,220 | 1,784 | 0 / 16 / 0 / 184 | 2,475 | 0.001784 | 0.013182 |
| native/create-8 | create-8/batch-approve-8xcreate-approve0 | user | ok | 569,762 | 26,436 | 1,866 | 0 / 16 / 0 / 266 | 3,755 | 0.001866 | 0.013788 |
| native/relayed-rejected-deficit | create/batch-approve-create-approve0 | user | ok | 119,654 | 4,421 | 277 | 0 / 2 / 0 / 77 | 1,291 | 0.000277 | 0.002047 |
| native/relayed-rejected-deficit | claim/relayed | relayer | ok | 58,714 | 2,175 | 30 | 0 / 0 / 0 / 30 | 395 | 0.000030 | 0.000222 |
| native/relayed-rejected-deficit | reject/unknown-grant | user | revert | 24,106 | 134 | 18 | 0 / 0 / 0 / 18 | 395 | 0.000018 | 0.000133 |
| native/relayed-rejected-deficit | reject/trip-brake-predicate-false | user | revert | 29,366 | 345 | 16 | 0 / 0 / 0 / 16 | 363 | 0.000016 | 0.000118 |
| native/relayed-rejected-deficit | issuer/seize | relayer | ok | 34,124 | 223 | 24 | 0 / 0 / 0 / 24 | 427 | 0.000024 | 0.000177 |
| native/relayed-rejected-deficit | brake/trip-latch | relayer | ok | 33,786 | 398 | 21 | 0 / 0 / 0 / 21 | 363 | 0.000021 | 0.000155 |
| native/relayed-rejected-deficit | claim/blocked-by-deficit | user | revert | 59,030 | 1,996 | 19 | 0 / 0 / 0 / 19 | 395 | 0.000019 | 0.000140 |

### Raw: Per workflow (cold = with setup; warm = without)

| Workflow | Tx cold/warm | User sigs cold/warm | Relayer tx | U cold | U warm | exec gas warm | prove gas warm | Floor warm DBLN | Debt 75k / 99,999 warm DBLN | Warm workflows/day at 10 / 50 / 100% (binding) |
|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
| original-linearvesting/grant-lifecycle-cold | 8/7 | 8/7 | 0 | 3,014 | 2,969 | 857,501 | 5,505 | 0.002969 | 0.021938 / 0.162089 | 93 / 465 / 931 (state_refill) |
| original-linearvesting/grant-lifecycle-warm | 6/6 | 6/6 | 0 | 2,847 | 2,847 | 812,948 | 5,327 | 0.002847 | 0.021037 / 0.155428 | 97 / 485 / 971 (state_refill) |
| original-linearvesting/create-8 | 9/9 | 9/9 | 0 | 21,014 | 21,014 | 4,759,030 | 16,546 | 0.021014 | 0.155274 / 1.147234 | 13 / 65 / 131 (state_refill) |
| original-linearvesting/relayed-rejected-deficit | 5/5 | 3/3 | 2 | 2,804 | 2,804 | 747,544 | 3,469 | 0.002804 | 0.020719 / 0.153081 | 98 / 493 / 986 (state_refill) |
| original-tokentimelock/grant-lifecycle-cold | 8/6 | 8/6 | 0 | 4,935 | 598 | 375,252 | 7,309 | 0.000598 | 0.004419 / 0.032647 | 462 / 2,311 / 4,623 (state_refill) |
| original-tokentimelock/grant-lifecycle-warm | 5/5 | 5/5 | 0 | 382 | 382 | 314,597 | 7,094 | 0.000382 | 0.002823 / 0.020855 | 723 / 3,618 / 7,237 (state_refill) |
| original-tokentimelock/create-8 | 1/1 | 1/1 | 0 | 1,842 | 1,842 | 522,920 | 16,732 | 0.001842 | 0.013611 / 0.100562 | 150 / 750 / 1,500 (state_refill) |
| original-tokentimelock/relayed-rejected-deficit | 5/5 | 3/3 | 2 | 390 | 390 | 295,760 | 5,905 | 0.000390 | 0.002882 / 0.021292 | 708 / 3,544 / 7,089 (state_refill) |
| native/grant-lifecycle-cold | 8/6 | 8/6 | 0 | 7,984 | 615 | 405,517 | 13,224 | 0.000615 | 0.004544 / 0.033575 | 449 / 2,247 / 4,495 (state_refill) |
| native/grant-lifecycle-warm | 5/5 | 5/5 | 0 | 397 | 397 | 347,287 | 12,982 | 0.000397 | 0.002933 / 0.021674 | 696 / 3,482 / 6,964 (state_refill) |
| native/create-8 | 2/2 | 2/2 | 0 | 3,650 | 3,650 | 1,052,500 | 38,656 | 0.003650 | 0.026970 / 0.199267 | 75 / 378 / 757 (state_refill) |
| native/relayed-rejected-deficit | 7/7 | 4/4 | 3 | 405 | 405 | 358,780 | 9,692 | 0.000405 | 0.002993 / 0.022110 | 682 / 3,413 / 6,826 (state_refill) |

### Raw: Failures (expected reverts; the signer pays)

| Workflow | Step | Payer | U | exec gas | Fee paid = floor DBLN |
|---|---|---|---:|---:|---:|
| original-linearvesting/relayed-rejected-deficit | claim/blocked-by-deficit | user | 17 | 38,333 | 0.000017 |
| original-tokentimelock/grant-lifecycle-cold | claim/before-cliff | user | 16 | 31,255 | 0.000016 |
| original-tokentimelock/relayed-rejected-deficit | claim/relayed-unsupported | relayer | 16 | 28,898 | 0.000016 |
| original-tokentimelock/relayed-rejected-deficit | reject/second-concurrent-grant-same-beneficiary | user | 49 | 69,707 | 0.000049 |
| native/grant-lifecycle-cold | claim/before-cliff | user | 18 | 26,648 | 0.000018 |
| native/relayed-rejected-deficit | reject/unknown-grant | user | 18 | 24,106 | 0.000018 |
| native/relayed-rejected-deficit | reject/trip-brake-predicate-false | user | 16 | 29,366 | 0.000016 |
| native/relayed-rejected-deficit | claim/blocked-by-deficit | user | 19 | 59,030 | 0.000019 |
