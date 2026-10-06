# B0 Claims: security notes

Unaudited. These notes describe intended behaviour and the tests that check it. They are not a safety certificate.

## Who can stop, censor, misreport or steal

| Party | Can | Cannot |
|---|---|---|
| Campaign creator | choose the eligibility set, amounts, deadline and refund recipient; underfund; publish a wrong or duplicate dataset; withhold proofs | edit the root, redirect a valid claim, sweep before the deadline, pause anything |
| Refund recipient | receive the remainder after `deadline` (or a zero remainder once fully paid) | close early while value remains, touch other campaigns |
| Relayer / submitter | pay to submit, or refuse to; delay a claim past the deadline by not submitting | change the recipient or the amount |
| Token issuer / proxy admin | freeze, seize or upgrade the token. This can block every exit; a code-hash change trips the brake, but an upgrade behind an unchanged proxy facade does not | — |
| Committee / block producer | censor or reorder; push a claim past the deadline | forge a proof |
| Anyone | latch the brake **only while its predicate holds**; close and prune eligible campaigns | set an arbitrary pause |
| Pipln / founder | nothing: there is no key in the constructor, storage or fallback | — |

## Invariants and the tests that check them

| Invariant | Test |
|---|---|
| `outstanding == Σ remaining(live campaigns)` | `invariant_outstandingIsSumOfLiveRemaining` |
| funded = claimed + refunded + outstanding; balance = outstanding + donations | `invariant_conservation`, `testFuzz_fullCampaignConserves` |
| Every call succeeds exactly when the model says it should. An entitled, backed claim inside the window never fails, and a replayed, tampered or expired claim never pays (exits always open, no unauthorised payout) | `invariant_modelAgreesWithEveryCall` |
| Any one-bit change to the proof, account, amount or index is rejected | `testFuzz_tamperedClaimRejected` |
| Leaf binds campaign, index, account and amount; no cross-campaign or cross-instance replay | `testFuzz_leafDomainBinding`, `test_claim_crossCampaignAndCrossInstanceReplay` |
| A 2^128-1 entitlement pays without overflow | `testFuzz_maxAmountSingleLeaf` |
| A closed id is never reissued; pruned bits cannot be replayed | `test_prune_onlyClosedAndNoResurrection` |
| A failed transfer rolls back the bit and the bookkeeping, so the right is kept | `test_claim_blockedRecipientKeepsRight`, `test_close_failedRefundKeepsCampaign` |
| Reentrancy from a token callback is blocked (transient lock) | `test_reentrancy_fromRecipientCallback` |
| Fee-on-transfer and no-op tokens never create a liability | `test_create_rejectsFeeOnTransferAsset`, `common/test/Common.t.sol` |

## Brake

`brakeState()` returns `(state, guardian=0, sinceHeight)`. The predicate bits, all computed from on-chain facts:

- `1`: `token.codehash` differs from the hash pinned at deployment.
- `2`: `token.balanceOf(this) < outstanding`.
- `4`: `nextCampaign == 2^64-1`.

While any bit holds, `create` reverts. Anyone can call `tripBrake()` to latch it permanently, and the latch survives even if the predicate later clears. Brake state is never checked on `claim`, `close`, `prune` or any view.

Every payout additionally requires `balanceOf(this) >= outstanding` after the transfer. So no exit can spend backing that belongs to another campaign. During a deficit **every payout fails** until someone voluntarily tops up the instance. There is no haircut, bailout or privileged drain. That is the design's choice ("exit open" means callable under solvency, not guaranteed to pay). Test: `test_brake_deficitClosesEntryKeepsBackedExits`.

## Known limits

- An underfunded or duplicate dataset is the issuer's error. `tools/claims_tree.py` reports `total` and `duplicateAccounts` so reviewers can check them before anyone relies on the root.
- A leaf naming an account the token refuses to pay (blocklisted, or this instance) stays unclaimable until the deadline, and its amount then goes to the refund recipient.
- A blocked refund recipient leaves the campaign open forever, still counted in `outstanding`. Nobody can redirect it.
- `deadline` is a block height. The wallet must convert it to a time estimate and say that it is an estimate.
