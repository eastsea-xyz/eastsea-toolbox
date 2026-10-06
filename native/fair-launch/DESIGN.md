# Bootstrap a finite sale without promising fair price discovery

Status: design, 2026-10-06; **Lane B, P2** for a finite funded sale, **P3 / BLOCKED** for sealed fair-price clearing. Best layer: contract for reserved inventory/refunds; wallet for the purchase agreement. No Solidity or measured results. Inherits [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md).

## The person's problem

A new community has no initial liquidity, useful price or recruited market maker; buyers want a stated opportunity to acquire the initial supply without privileged early execution. Pump explicitly describes the liquidity/price-discovery cold start that bonding curves address. A finite sale can establish a funding/inventory agreement, but it does not deliver a continuously tradable market or an impartial market price. [Pump bonding-curve explanation, checked 2026-10-06](https://pump.fun/docs/bonding-curve).

## Original evidence and the limited native answer

An original collector study observes 166,098 launches during 2026-06-11–25 and recurring early-buyer cohorts; latest revision 2026-08-03. It is a qualified empirical sample, not a platform census or proof every early buyer is abusive. Revised research also warns that collector timeouts do not establish non-graduation. Do not substitute a universal failure rate for the actual access/market problem. [Cohort study](https://arxiv.org/abs/2607.02795), [measurement warning, revised 2026-09-10](https://arxiv.org/abs/2607.02823).

The native v1 below gives bounded priced inventory, atomic completion and a deadline refund without platform fees or an administrator. It loses the original curve's continuous price discovery/trading and does **not** solve first-come access, Sybil participation or insider information. Account batching improves both original and native controls. Strong fairness remains a separate design gate; naming this directory does not confer it.

## Finite funded-lot state machine

One immutable instance pins distinct exact-transfer token T and quote asset Q, their code identities, a fixed seller, lot size in T base units, Q price per lot, at most 64 total lots, open/reserve-end/claim-deadline heights and a maximum reservation lease. All products/totals fit `uint128`; each lot and price are positive integers. There is no mutable price, mint role, fee recipient, seller override, allowlist, proxy or forced market graduation.

`Preparing → Funded → Reserving → Completing → Closed`. Anyone may voluntarily fund **exactly the full T inventory** from their own balance before openHeight. The wallet makes the fixed seller/unsold-return recipient explicit; a different contributor is giving that inventory under these rules. Funding never pulls someone else's allowance merely because it exists. Partial/unfunded instances cannot open.

During `openHeight <= height < reserveEnd`, a buyer's account reserves positive whole lots from free inventory, pays exact Q and receives a unique monotonic id. Record buyer=`msg.sender`; expiry=`min(height+lease,claimDeadline)`. Reserved lots leave free inventory and Q joins liability; at most 64 live records exist because every record reserves at least one lot. A user can obtain several lots/addresses; this is not a per-human limit.

Before expiry, anyone completes a reservation: send its fixed T quantity to the recorded buyer and exact Q price to the fixed seller, atomically. Clear both reservation words and adjust all liabilities/counts before external calls. If either token fails exact delivery, everything rolls back. A caller cannot change price, buyer, seller or lot quantity.

At/after expiry, anyone refunds Q to the recorded buyer, clears the record and restores its lots to free inventory. Refund and completion have disjoint height inequalities. No early cancellation is promised: reservation temporarily locks inventory, which can be abused to deny access until lease expiry. Failed refunds keep the buyer's right and reserved inventory intact.

After reserveEnd, anyone transfers only **free, unreserved** T back to the fixed seller; outstanding reservations retain backing. Later expired reservations create newly reclaimable stock. No seller key seizes a live buyer's Q or reserved T. There is no loop over all participants; point claims/refunds and bounded batches are sufficient. Once all stock is delivered/reclaimed and all reservations are settled, metadata records closure; no sweep takes unsolicited surplus or abandoned live refund rights.

## Storage and paid-state lifecycle

| Word | Fields | First occupation |
|---|---|---:|
| M0 | `uint128 quoteLiability; uint64 nextId; uint64 brakeSince` | 100 u at deployment, nextId starts at one |
| M1 | `uint64 freeLots; uint64 reservedLots; uint64 deliveredLots; uint56 reclaimedLots; uint8 phase` | 100 u at deployment, Preparing is nonzero |
| Reservation R0 | `address buyer; uint64 expiry; uint32 flags` | 100 u per live reservation |
| Reservation R1 | `uint128 paidQuote; uint64 lots; uint64 reserved` | 100 u per live reservation |
| Token state | Sale T/Q holders, buyer T/refund-Q, seller proceeds/returned-T; retained allowances | 100 u per newly occupied word |

`free+reserved+delivered+reclaimed == totalLots` after funding. Actual T backs `(free+reserved)*lotSize`; actual Q backs quoteLiability. Every payout preserves both post-transfer inequalities, so a deficit grants no first-exit priority. Donations do not create sale lots or withdrawable proceeds. Immutable counters never reuse deleted ids; calls to absent records fail. A transaction-scoped guard clears within the transaction; any persistently initialized guard is an additional metered deployment word.

Completed R0/R1 delete with **no burned-state-fee refund**. Abandoned valid refunds remain live while token transfer is impossible; the seller cannot erase them. Token balances emptied by earlier funding/payments incur another 100 u when reoccupied. There is no recurring rent under design 27. [ES1](../SOURCES.md#es1).

## Signatures and what the buyer sees

Inventory funder: one funded P-256 `[approve(T),fund,approve(T,0)]` batch after deployment. Buyer: one `[approve(Q),reserve,approve(Q,0)]` batch, then one claim batch, or any willing funded caller completes to the fixed parties. Refund is permissionless to the fixed buyer. Count deployment, funding, reservation and completion separately; current payment sessions cannot reserve/claim.

No 1271 or NFT receiver hook is required for this ERC-20-only sale. Added-owner relay requires funded setup and pays its own fee; native sponsor settlement is absent. The buyer sees lot quantity, total price, seller, temporary reservation, completion/refund deadline and a failure reason. They need not learn curve formulas, proofs, allowances or fee dimensions. They must see that the fixed price and first-come access were chosen rather than discovered fairly. [ES2](../SOURCES.md#es2), [sponsorship](../sponsorship/DESIGN.md).

## Illustrative complete-cost ledger

`H=ceil((E+128+O+L)/32)`; estimates only, O=0 in self batches. Transfer/Approval each 192 B; account event 128 B. `Funded(seller indexed,lots,T)` is 192 B; `Reserved(id indexed,buyer indexed,lots,Q,expiry)` is 256 B; `Claimed(id indexed,buyer indexed,lots,Q)` is 224 B; `Refunded(id indexed,buyer indexed,Q)` is 192 B; `Reclaimed(seller indexed,lots,T)` is 192 B.

| Action | Final new words | E / L | Estimated U |
|---|---:|---|---:|
| Full initial T funding | sale T holder = 1 | 768 / 896 (two Approvals, Transfer, Funded, account) | 156 |
| Reserve with nonzero sale Q holder | R0+R1 = 2 | 768 / 960 | 258 |
| First reserve after sale Q holder is zero | R0+R1+Q holder = 3 | same | 358 |
| Complete; buyer T/seller Q balances nonzero | 0, reservation clears | 512 / 736 | 43 |
| Complete into zero buyer T/seller Q balances | +1 for each zero holder | same | +100 each |
| Expired refund into warm Q holder | 0, reservation clears | 512 / 512 | 36 |
| Reclaim free inventory into warm seller T holder | 0 | 512 / 512 | 36; +100 if holder zero |
| Failed simple action | 0 app growth | E512/O128/L0 | 24 |
| Local brake latch | 0; M0 already occupied | 512 / 288 | 29 |

Exact approval/reset leaves zero final allowance words, but both Approval events remain priced. Add first sender accounts, optional retained approvals, extra token logs and real deployment wrappers. An expired/refunded/remarketed lot has multiple reservation lifetimes; it is not priced as one successful claim.

Planning deployment: C=6,000 runtime B, two metadata words, one account, E=8,192/O0/L160 → **6,565 u**. Complete cohort: 64 one-lot reservations are funded before any completion so sale Q holder stays nonzero until last payout; all accounts exist and seller/receivers' token holdings remain nonzero. `6,565+156+358+63*258+64*43 = 26,085 u`, **407.578125 u per completed lot**. Sixty-four first T holders and one first seller Q holder add 6,500 u: **32,585 u / 509.140625 u per lot**. T issuance, token deployments and initial participant asset acquisition are separate and must be priced for a truly cold launch.

Full-refill state ceilings are `floor(2,764,800/407.578125)` warm or `floor(2,764,800/509.140625)` fresh-holder completed lots/day. The warm sale burns **0.026085 DBLN** in floor state fees and occupies `ceil(26,085/32)=816` refill heights. Exec/prove gas, actual ABI/envelopes, contention, source issuance and achieved throughput are **TO MEASURE**. Lease/window waits and archive capacity are additional limits; these ceilings do not predict a successful market.

## Brake, MEV and the gated fair variant

`brakeState()` reports guardian zero. New funding/reservations stop after their window, on pinned-code mismatch or either backing deficit. A permissionless successful latch records permanent structural closure; entries recompute predicates before any latch. Completing/refunding/reclaiming stays callable with its existing conditions and full remaining backing. Issuer freezes can block all asset exits; there is no bailout or mutable haircut.

Public ordering favors fast/connected buyers; quota-free addresses permit Sybil purchases; inventory leases permit temporary denial; the seller selected price/asset supply. A copied completion/refund cannot redirect funds. Finality improves confirmation, not fair admission. These are explicit v1 limitations; original continuous curves may provide more useful price discovery and liquidity.

Sealed uniform-price clearing is a **separate BLOCKED variant**: require the draw TLE SDK, authenticated raw seed, an on-chain enforceable cutoff **before signing**, complete available bids, verified deposits and a bounded deterministic clearing checker. `randomness(epoch)==0`, an organizer's result/root or a predictable fallback cannot provide these. Threshold collusion can open early; draw timing follows rotation. No algorithm, key-release API, encrypted mempool or fair clearing claim is delivered here. If the requirements cannot be enforced without new certified metadata/signing rules, request an explicit protocol upgrade. [ES4](../SOURCES.md#es4), [ES5](../SOURCES.md#es5), [G3/G4](../PLAN.md#gate-register-do-not-assume-these-exist).

## Tests and original head-to-head

Pin Pump/Raydium documented behavior and licences before any implementation; compare funding/inventory acquisition and initial buyer execution separately from continuing trading/AMM graduation. Give originals equivalent EastSea account batching where their on-chain path permits it. Match stock, price/spread, freshness, first/late access and maker funding; publish the native fixed-price/no-curve capabilities removed from the control.

Test lot/quote/stock conservation; uint128/height/id boundaries; partial funding rejection; expiry equality and concurrent complete/refund; repeated inventory leases; all partial/last payouts; exact delivery/reentrancy; seller token reoccupation; abandoned/frozen refunds; backing deficit and local brake; shared-counter/token contention and sequential/parallel roots. Benchmark successful, expired and rejected lifetimes with the [common method](../MEASUREMENTS.md). Random/sealed tests are feasibility gates until every missing prerequisite exists, not evidence of fairness.
