# B2 Escrow: security notes

Unaudited. These notes describe intended behaviour and the tests that check it. They are not a safety certificate.

## Who can stop, censor, misreport or steal

| Party | Can | Cannot |
|---|---|---|
| Buyer | fund; cancel before acceptance; release; propose or accept a split; dispute; pay anyone's award to its owner | refund themselves after acceptance without the seller, the arbiter or the silence policy |
| Seller | accept; refund; propose or accept a split; dispute | release funds to themselves without the buyer, the arbiter or the silence policy |
| Arbiter (fixed per instance, optional) | split a **disputed** deal between the two parties before `rulingBy`; rule dishonestly; ignore the dispute | extend a deadline, pay itself or a third party, touch an undisputed deal, rule after a settlement or after `rulingBy` |
| Anyone | lapse an unaccepted offer from `acceptBy`; apply the silence policy at the deadline; trigger payouts to their fixed owners; latch the brake **only while its predicate holds** | redirect money, choose a split, pause exits |
| Token issuer | freeze or seize, which can block exits. A code-hash change trips the brake | — |
| Committee / producer | censor a party until a deadline passes (the outcome then follows the silence policy) | forge an authorisation |
| Pipln / founder | nothing: there is no key | — |

## Invariants and the tests that check them

| Invariant | Test |
|---|---|
| Every action succeeds exactly when the model allows it (right actor, right phase, before or after the right deadline), and every payout is exactly the model's award to the fixed party. This covers authorisation, single resolution, single payout and "exits always open" | `invariant_everyCallMatchesModel` |
| `totalLiability == Σ` of unresolved amounts plus unpaid awards | `invariant_liabilityEqualsUnpaidAwards` |
| funded = paid + liability = custody (no unbacked liability, no stranded value) | `invariant_conservation` |
| Any split reached by any route pays exactly `amount` in total and retires the record | `testFuzz_anySplitConserves` |
| Silence outcome depends only on the agreed policy | `testFuzz_silenceFollowsPolicy`, `test_timeout_noArbiter_bothPolicies` |
| A stranger can do nothing that moves money or changes terms | `testFuzz_strangerHasNoPower` |
| A failed transfer blocks only its own payout and keeps the right | `test_blockedRecipient_onlyBlocksOwnPayout`, `test_native_rejectingRecipientKeepsRight_andReentryBlocked` |
| Voluntary settlement ends a dispute and later rulings revert | `test_voluntarySettlementEndsDispute` |
| Reentrancy through a token callback or native receive is blocked | `test_reentrancy_fromTokenCallback`, native test above |
| Fee-on-transfer and no-op tokens never create a liability | `test_create_rejectsFeeOnTransferAsset`, `common/test/Common.t.sol` |

## Brake

`brakeState()` returns `(state, guardian=0, sinceHeight)`. Predicate bits: `1` ERC-20 code hash changed (an addition to the design's predicate, for consistency with B0/B1), `2` custody `< totalLiability`, `4` `nextId == 2^64−1`. While any bit holds, `create` reverts. `tripBrake()` latches permanently, and only while the predicate holds. Acceptance, proposals, disputes, rulings, timeouts and payouts keep their ordinary checks under the brake. Each payout must leave custody `≥ totalLiability`, so during a deficit payouts wait for someone to top up the instance. A donation gives the donor no claim. Test: `test_brake_deficit_entryClosed_exitsWaitForBacking`.

## Known limits and design choices

- `G` packs `totalLiability │ nextId │ brakeSince` (64-bit latch height). The design's separate `latched:uint8` is folded into `brakeSince != 0`.
- `acceptBy`, `deliverBy` and `rulingBy` are `block.timestamp` deadlines (lint `block-timestamp` is deliberately silenced). Producers can shift time by seconds, not days.
- An acceptance or cancel race at `acceptBy` is decided by ordering. The wallet should not accept with seconds to spare.
- The terms hash proves the agreement bytes, not their availability or truth.
