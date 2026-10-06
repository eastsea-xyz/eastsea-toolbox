# B1 Streams and vesting: security notes

Unaudited. These notes describe intended behaviour and the tests that check it. They are not a safety certificate.

## Who can stop, censor, misreport or steal

| Party | Can | Cannot |
|---|---|---|
| Grant creator | choose the beneficiary, amount and schedule at funding time | cancel, claw back, change the schedule or beneficiary, or sweep |
| Beneficiary | claim the earned part whenever they like; abandon it | claim more than is earned, or redirect a payout away from themselves (the money only goes to the stored address) |
| Relayer / caller | pay to trigger a claim, or refuse to | change the recipient or the amount |
| Token issuer / proxy admin | freeze or seize. A code-hash change trips the brake, but an upgrade behind an unchanged proxy facade does not | — |
| Committee / producer | censor or delay. A delay never reduces the earned amount | pay early: earning follows `block.timestamp` |
| Anyone | latch the brake **only while its predicate holds** | pause claims |
| Pipln / founder | nothing: there is no key anywhere | — |

## Invariants and the tests that check them

| Invariant | Test |
|---|---|
| `outstanding == Σ (total − released)` over live grants | `invariant_outstandingEqualsUnpaidEntitlements` |
| funded = paid + outstanding; balance = outstanding + donations | `invariant_conservation` |
| Every claim pays exactly the model's `earned − released` to the beneficiary, and reverts exactly when that is 0 (exits always open, no overpayment) | `invariant_everyClaimMatchesModel` |
| Earned is monotone, ≤ total, exactly the floor, 0 at the cliff and total at the end, across the full uint128/uint32 range | `testFuzz_earnedMonotoneBoundedFloor`, `test_schedule_boundaries`, `test_schedule_roundsDown` |
| Any claim schedule sums to exactly `total`, and the grant then retires | `testFuzz_anyClaimScheduleSumsToTotal` |
| No overflow at `2^128−1` over `2^32−1` s; no timestamp wrap after 2106 | `test_schedule_maxGrantNoOverflow` |
| Grants never share backing | `testFuzz_grantsIsolated`, `test_brake_deficitBlocksEntryAndUnbackedPayouts` |
| Donations change no entitlement | `test_donationDoesNotChangeEntitlements` |
| No cancellation path; the creator's only power is paying the beneficiary | `test_noCancellation_creatorHasNoPower` |
| A failed transfer keeps the right | `test_blockedBeneficiaryKeepsRight` |
| Reentrancy through a token callback is blocked | `test_reentrancy_fromBeneficiaryCallback` |
| A completed id never comes back | `test_claim_relayedToBeneficiary_partialThenFinalDeletes` |

Rounding: each claim pays `floor(earned) − released`. Because `released` holds the cumulative floor, rounding never accumulates. The beneficiary receives exactly `total` by `end`, and never more at any time.

## Brake

`brakeState()` returns `(state, guardian=0, sinceHeight)`. Predicate bits: `1` token code hash changed, `2` `balanceOf(this) < outstanding`, `4` `nextId == 2^64−1`. While any bit holds, `create` and `createBatch` revert. `tripBrake()` latches permanently, and only while the predicate holds. `claim` never checks the brake. Each payout must leave `balanceOf(this) ≥ outstanding`, so during a deficit payouts fail until someone tops up the instance. There is no pro-rata haircut, bailout or sweep.

## Known limits

- A lost beneficiary key, or a beneficiary the token blocklists, leaves the money in place indefinitely. There is no rescue key, by design.
- Public payroll: amounts and timing are visible on-chain.
- Equal timestamps give equal earnings. Fast block confirmation does not speed up the salary clock.
