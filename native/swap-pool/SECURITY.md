# C1 Swap pool: security notes

Unaudited. These notes describe intended behaviour and the tests that check it. They are not a safety certificate.

## Who can stop, censor, misreport or steal

| Party | Can | Cannot |
|---|---|---|
| Trader | swap within its own signed `minOut`/`maxIn` and deadline | receive more than the curve allows, take the whole reserve, use another account's approval |
| LP | add proportionally; remove its own shares to any receiver | remove another LP's shares or the locked minimum; capture a donation made before it joined |
| Searcher / block producer | reorder public swaps before inclusion and sandwich up to the victim's tolerance; censor until a deadline passes | push a victim below its signed `minOut` |
| Anyone | latch the brake **only while its predicate holds**; donate (benefits current LPs) | pause, unpause, sweep, skim, change fee or tokens |
| Token issuer / proxy admin | freeze, seize, pause, blocklist, or upgrade the token. A code-hash change or a seizure trips the brake; a frozen token can block exits | — |
| Wallet / frontend / relayer | refuse service or show a bad quote (the signed bound still holds) | change the signed bound or recipient |
| Pipln / founder / deployer | nothing after deployment: there is no key | — |

## Invariants and the tests that check them

| Invariant | Test |
|---|---|
| Constant product never decreases on a swap; it grows only by the fee | `invariant_kAndValuePerShare`, `testFuzz_exactInput_matchesCurve_kNeverDown`, `testFuzz_exactOutput_chargesMinimalCeiling` |
| No rounding theft: value per share (`k / totalShares²`) never decreases on add, swap or remove outside an issuer loss; add-then-remove and A→B→A never profit | `invariant_kAndValuePerShare`, `testFuzz_valuePerShare_monotone`, `testFuzz_addRemove_noProfit`, `testFuzz_roundTrip_noProfit` |
| Rounding direction: output floor, exact-output input ceiling (and tight), proportional deposits ceiling | `test_exactOutput_paysCeiling_andMaxIn`, `testFuzz_exactOutput_chargesMinimalCeiling`, `test_newLp_oneSlot_proportional_roundedUp_restStaysWithUser` |
| Conservation: pool balance = in − out + donations − seizures | `invariant_conservation` |
| Books never exceed balances without a seizure, and a deficit is visible as braked | `invariant_booksBackedOrBraked` |
| Exits always open: every remove by an LP holding shares succeeds, braked or not (honest tokens) | `invariant_exitsAlwaysOpen`, `test_deficit_closesEntry_latchIsPermanent_exitsProRata`, `test_codeHashChange_closesEntry_exitsStayOpen`, `test_tokenTurnsFeeOnTransfer_exitStillOpen`, `test_rebasingRounding_entryRefused_exitStillOpen` |
| Brake latch is permanent, closes entry, has no guardian | `invariant_brakeLatch`, `test_deficit_closesEntry_latchIsPermanent_exitsProRata`, `test_tripBrake_requiresPredicate`, `test_noOneCanPauseWithoutPredicate` |
| A live deficit is recorded before an exit syncs the books | `test_remove_latchesALiveDeficit_itself` |
| Shares: Σ LP shares + locked = supply; locked minimum never redeemable | `invariant_shareSupply`, `test_lockedMinimum_isNeverRedeemable` |
| Swap output ≥ signed minimum; quotes equal execution | `invariant_kAndValuePerShare` (overpaid counter), `testFuzz_quotesMatchExecution` |
| First-depositor inflation is bounded by `minShares` and the locked minimum | `testFuzz_inflationAttack_boundedByMinShares` |
| Reentrancy through a token callback is rejected | `test_reentrancyThroughTokenCallback_isBlocked` |
| Fee-on-transfer and no-op tokens cannot enter; no-bool tokens work | `test_feeOnTransfer_cannotEnter`, `test_noopTrueToken_cannotEnter`, `test_noBoolToken_fullLifecycle` |
| A no-op token cannot make an LP burn shares for nothing past its minimum | `test_exitMinimum_isCheckedOnActualDebit` |

## Brake

`brakeState()` returns `(state, guardian = address(0), sinceHeight)`; `brakeSpec()` returns this anchor and the deployer-supplied document hash; `brakeMeta()` returns `(createdAt, latchedAt, reason)` from the one metadata word occupied at deployment.

| Bit | Predicate |
|---|---|
| `1` | `token0.codehash` or `token1.codehash` differs from the value pinned at deployment |
| `2` | `balanceOf(pool) < reserve` for either token |
| `8` | shares and reserves disagree (`totalShares == 0` with nonzero reserves, or nonzero supply with a zero reserve, or supply below the locked minimum) |

While any bit holds, `add`, `swapExactInput` and `swapExactOutput` revert with `EntryBraked`. `tripBrake()` succeeds only while a bit holds and latches `latchedAt = block.number` and the reasons permanently; nobody can clear it. `remove` never checks the brake and latches a live predicate itself before re-syncing reserves to balances. After the latch, LPs leave pro rata of whatever the pool actually holds, recalculated each exit; there is no privileged sweep.

## Known limits and design choices

- **Public swaps are reorderable.** One-second finality does not prevent sandwiches or execution at the worst permitted price. The simulation (`test_sim_sandwichBoundedByMinOut`) shows extraction bounded by, and growing with, the victim's tolerance. Keep caps narrow; compare RFQ (C2, gated on G1).
- **Deadlines** are `block.timestamp`; censoring until a deadline passes makes a swap fail, not execute badly.
- **Frozen or paused tokens block exits** for the frozen leg; both legs move in one call, so a frozen token0 also holds token1 until the issuer cooperates. An LP blocked as a receiver can name another receiver.
- **Upgrades behind an unchanged proxy facade** do not change the code hash and are not detected by bit `1`.
- **Balances above `2^112`** (an absurd donation) make entry revert with `ReserveOverflow`; exits cap their arithmetic at `2^112` and keep working. Deploy another pair.
- **Rebasing tokens** are unsupported: positive rebases are absorbed for LPs, negative ones trip the brake, and index rounding makes entry transfers inexact (refused).
- **First LP sets the ratio.** It is not a certified price; a wallet must not present a fresh pool's quote as a market price.
- **Abandoned shares** keep their slot until the owner exits; no one else can retire them. Deleting a slot refunds no burned state fee.
- **Cross-pool routes** are composed in the wallet; this contract has no router and no multi-hop function.
