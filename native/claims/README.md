# B0 Claims: receive a fixed allocation with one clear claim

Status: **implementation, unaudited, not deployed, not measured on the EastSea executor.** The design is in [DESIGN.md](DESIGN.md). The rules from [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md) apply. This code is provided AS IS for testing and benchmarking, like the rest of this repository. Whoever deploys or uses it is responsible for doing so.

## The person's problem

An issuer wants a published allocation to reach its eligible recipients without running a custodial batch-paying service. A recipient wants to know whether they are eligible, receive the right amount, and never pay twice for an entitlement that has already been used. The UNI distribution allocated claims to 251,534 historical addresses. Those are eligible addresses, not completed claims or people ([source](https://blog.uniswap.org/uni)).

## What the original already solves

Uniswap's [MerkleDistributor](https://github.com/Uniswap/merkle-distributor/blob/master/contracts/MerkleDistributor.sol) already has an immutable root and token, a packed 256-claim bitmap and permissionless submission to the leaf's account. None of those are native inventions. It deploys one contract per allocation, has no deadline or refund path (later variants add an owner-controlled sweep), and cannot supply leaf or proof data that has gone missing.

## What this contract does

`ClaimCampaigns` ([src](src/ClaimCampaigns.sol)) is **one shared immutable instance per exact-transfer ERC-20** that holds many finite campaigns:

| Action | Who | Effect |
|---|---|---|
| `create(expectedId, root, leafCount, refundRecipient, deadline, amount, dataHash)` | anyone | Funds exactly `amount` (the balance delta is checked) and stores 3 words. The call reverts before any token moves if `expectedId` is stale. |
| `claim(id, index, account, amount, proof)` | anyone | Pays exactly `amount` to the leaf's `account`, never to the caller. Sets one bit. |
| `close(id)` | anyone, after `deadline` or once fully paid | Sends the remainder to the fixed `refundRecipient` and clears the 3 campaign words. |
| `prune(id, startWord, ≤8)` | anyone, only after close | Clears bitmap words. A closed id is never reissued, so old proofs stay dead. |
| `tripBrake()` | anyone, only while the predicate holds | Permanently closes `create`. Claims and close stay open. |

There is no owner, root edit, sweep key, fee, proxy or upgrade. Leaves bind chain id, instance, campaign id, index, account and amount. The tree is positional: a proof has exactly `ceil(log2(leafCount))` siblings, so each index has exactly one valid leaf.

**Data export.** [`tools/claims_tree.py`](tools/claims_tree.py) needs only the Python standard library. It turns `account,amount` rows into the root, every leaf and every proof (JSON), and reports `dataHash`, which is the sha256 of the canonical CSV and is passed to `create` and emitted in its event. `verify` recomputes all of it. The test `ClaimsExportTest` checks that the tool's output for a fixture is accepted by the contract byte for byte. The issuer must publish the CSV and JSON to independent mirrors **before** asking anyone to claim. Wallets keep their own leaf and proof. The contract cannot recover data that was never published.

## Wallet flow (P-256 account, existing A1 batch)

- Issuer: one batch `approve(exact) → create → approve(0)`. One biometric prompt. The allowance ends at zero, so no allowance slot is left occupied.
- Recipient: the wallet checks the leaf locally with `verify` (an `eth_call`, free) and shows "You can receive X by height H". One batch, one prompt. A relayer or friend can submit the same proof, and the money still goes only to the leaf's account.
- After the deadline: "This allocation ended". Anyone can close and prune.

No ERC-1271, typed signature, NFT hook or session permission is needed. True zero-DBLN first claims still need the native fee-payer (gate G6).

## Better on EastSea, and worse

**Possibly better (to be measured):** one runtime (7,767 B in Foundry) shared by many campaigns, instead of one deployment per allocation. A finite lifecycle whose closed campaign words and bitmap can be cleared. A refund recipient fixed at creation instead of an owner sweep. A local leaf check before any fee is spent. Exact-transfer enforcement on both sides of every movement. A deterministic brake with no keyholder.

**Worse or unchanged, stated plainly:**
- Each live campaign stores **3 words**. The original stores the root and token in code as immutables, so it has zero campaign words. For one large, long-lived allocation the original may cost less.
- Claims are **finite**. A late recipient loses to the refund recipient after `deadline`. The original never expires.
- All campaigns share **one token balance**, so a global deficit (an issuer seizure, a rebase down) blocks every payout until someone restores backing. A per-campaign original is isolated.
- The root proves membership only. It does **not** prove that the funding covers the sum, that recipients are unique people, or that the allocation was honest. An underfunded root becomes a race (`InsufficientBacking`).
- Clearing words refunds no burned state fee (design 27). Pruning is housekeeping, not a rebate.

## Head-to-head test plan (to run with the executor recorder)

Follow [MEASUREMENTS](../MEASUREMENTS.md): (1) the original on Ethereum, (2) the fidelity-checked original on the EastSea executor, (3) this contract on the same B5 genesis. Both EastSea paths get the same P-256 batch wallet, the same holder freshness and the same deadline.

| # | Scenario | Original control | Native | Record |
|---|---|---|---|---|
| H1 | One 4,096-leaf campaign, all claimed, warm holders | 1 MerkleDistributor deploy | 1 instance, 1 campaign, close + 2 prunes | total u, u/entitlement, exec/prove gas |
| H2 | Same, fresh recipient balances | same | same | +100 u per holder on both |
| H3 | 100 campaigns × 256 leaves | 100 deploys | 1 instance, 100 campaigns | code-amortization break-even point |
| H4 | Sparse claims: 10% of leaves spread across bitmap words | same | same | bitmap high-water u per completed claim |
| H5 | Expired partial campaign | no expiry (funds stay forever) / owner sweep variant | close → refund | unclaimed value outcome, close u |
| H6 | Relayed claim | third-party `claim` | same | recipient binding, relayer cost |
| H7 | Failure costs | invalid proof, replay | same + expired, wrong length | failed-attempt u and fee |
| H8 | Unavailable mirror | — | — | can the wallet still claim from its local export? |
| H9 | Deficit / token freeze | n/a | brake latch, exits blocked until recapitalised | user-visible outcome |
| H10 | Contention | n/a | concurrent claims across campaigns on one balance | conflict re-executions |

Publish where the original wins (expected: H1 for a single campaign, H5 for late recipients) as well as where native wins.

## Files

- `src/ClaimCampaigns.sol`: the contract.
- `tools/claims_tree.py`: builds, exports and verifies leaf, root and proof data.
- `test/`: unit (`ClaimCampaigns.t.sol`), fuzz (`ClaimCampaignsFuzz.t.sol`), invariants (`ClaimCampaignsInvariant.t.sol`), export fixture (`fixtures/`).
- [SECURITY.md](SECURITY.md), [GAS.md](GAS.md).

```bash
cd native && forge test --match-path 'claims/*'
python3 native/claims/tools/claims_tree.py verify --json native/claims/test/fixtures/campaign1.json
```
