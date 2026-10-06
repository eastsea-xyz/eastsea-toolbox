# Sponsorship: let the app pay without taking the user's authority

Status: design, 2026-10-06; **Lane A, P0**. **Protocol fee-payer support is missing.** Funded added-owner relays are available; ordinary zero-balance onboarding is not. Inherits [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md).

## The user's problem

A person who only wants to receive a payment, claim a ticket or try an app should not first buy a network token and arrange a second payment. App builders need a predictable acquisition budget without custody of users' assets. ERC-4337 explicitly identifies developer fee subsidies and token-denominated fee payment as paymaster use cases; Sui separates the transaction sender from the gas owner. These are evidence of the need, not evidence that any EastSea implementation is already better. [ERC-4337, created 2021-09-29](https://eips.ethereum.org/EIPS/eip-4337), [Sui sponsorship documentation, accessed 2026-10-06](https://docs.sui.io/develop/transaction-payment/sponsor-txn).

Best layer: **wallet + account relay now; protocol fee-payer hook + open budget escrow later**. A contract alone cannot fix the ordinary sender's pre-execution balance check. [ES1, ES2, ES6](../SOURCES.md#es6)

## Why another EntryPoint is the wrong default

ERC-4337 reserves payment before execution, validates a paymaster, and charges reverted operations too. Its bundler simulation and reputation machinery address risks created by that deployment model. EastSea already authenticates P-256 transactions and batches account calls; an extra UserOperation network is a possible compatibility path, not a necessary native design. The proposed smaller surface is a hypothesis to benchmark. [ERC-4337 payment and paymaster specification](https://eips.ethereum.org/EIPS/eip-4337).

Sui already supports sponsorship at the transaction layer and documents input-object conflicts and sponsor withholding. It wins on delivered capability. This design retains refusal and censorship risk even if it removes a per-transaction sponsor signature. [Sui risks and signing flow](https://docs.sui.io/develop/transaction-payment/sponsor-txn).

## Track A: an honest product with today's account

1. A funded owner authorizes the account delegation and adds the intended P-256 owner key; count this setup separately.
2. That owner signs `ownerDigest(calls, ownerNonce)`, binding chain, account, nonce and every call.
3. Any funded relayer submits `ownerExecute`; the relayer pays its own canonical transaction fee.
4. The batch either succeeds atomically or rolls back, including the account's owner nonce on failure. [ES2](../SOURCES.md#es2)

There is **no escrow reimbursement** in this track. A caller cannot submit a copied success receipt to get paid twice, and a reverting authorization cannot repeatedly drain a shared reimbursement pool. The relayer still loses its fee on failure and may refuse to relay. A successful account nonce prevents replay; a failed, withheld authorization can remain valid until the account nonce/key or an app-specific expiry condition changes. The present digest has no generic expiry or relayer-fee cap. [ES2](../SOURCES.md#es2)

Product: show “App pays this network fee” only after a relayer has offered to pay; show “This app cannot cover it; pay X DBLN” on refusal. No payment session grants arbitrary app calls, and no ERC-1271 assumption is needed for `ownerExecute`. Initial zero-balance setup remains a release gate. [ES2, ES3, ES6](../SOURCES.md#es6)

## Track B: immutable, openly funded campaigns

Each escrow instance pins an app target and runtime hash, admitted call shape, maximum value, start/end finalized heights, per-address fixed-height-window budget, maximum charged fee vector, and refund policy. Any person can fund it during its public funding window. No founder whitelist, signature server, mutable eligibility list, fee recipient or proxy exists.

Funding closes before sponsored execution opens. Later contributions use a new permissionless instance, preventing deposits made after earlier spending from diluting refunds. Plain native transfers outside `fund()` are explicitly uncredited donations, never evidence of an entitlement.

State machine: `Funding → Active → Closed → Refunded`; deterministic `EntryBraked` can stop new reservations during Active. Deadlines are finalized-height comparisons, not promises about elapsed seconds. Any caller may close the campaign after its fixed end.

Validation accepts a bounded public policy, not arbitrary callbacks: at most eight decoded account calls, all matching the pinned action grammar and fee/value limits. Per-address quotas bound one authorization stream, **not unique people**; Sybil drain remains possible. DeviceCheck is not permissionless humanity. [ES6](../SOURCES.md#es6)

The one-word quota uses `window=floor(finalizedHeight/windowSpan)` and resets its spending counter at a new fixed window while preserving the monotonic nonce. It does not implement a sliding 24-hour cap: two adjacent windows can spend twice the per-window limit near their boundary. A sliding cap needs additional history/state and a separate measured layout.

The user signs the whole native envelope, including sponsor instance, policy hash, account/delegation identity, call hash, sponsor nonce, expiry and exec/prove/state fee caps. Existing payment sessions do not authorize this operation. App price/recipient/asset checks remain inside the signed action.

## Missing protocol settlement contract

Required consensus interface, **not implemented**:

- Before EVM execution, validate the sender and bounded policy; reserve the signed maximum fee from the escrow, including validation and settlement overhead.
- Bind the reservation to canonical transaction hash and `(escrow, account, sponsorNonce)`; require the expected nonce and available per-window balance.
- During one atomic transaction application, execute, calculate all three fee dimensions, charge the escrow once and release the unused reservation.
- On an admitted EVM revert, persist fee/quota settlement and the consumed sponsor nonce while reverting application state; rejected or invalid authorizations create no payable reservation.
- No reservation survives into another block. Temporary reservation words disappear before the final committed diff; there is no durable mapping per transaction.
- Only the runtime can invoke reserve/settle. An ordinary EVM call, forged system sender, arbitrary receipt or app callback must never invoke settlement.

Specify transaction replacement, duplicate admission, restart, state-budget rejection, concurrent reservations, fee-cap exceedance and canonical sender nonce behavior before implementation. A reserve rejected by B5 must not consume budget or nonce. Quota accounting includes the charged cost of successful **and reverted admitted** attempts, within the signed cap.

Existing execution is insufficient: changing a payer inside `fund`, `ownerExecute` or an app call happens after ordinary fee reservation. A burn-funded shared pool and token fee swaps are separate missing mechanisms, not assumptions of this design. [ES1, ES6](../SOURCES.md#es6)

## Storage and rights

Planned layout; bounds reject amounts that do not fit. Compiler packing and actual occupied words must be verified.

| Word | Fields | First occupation / owner |
|---|---|---|
| T0 | `uint128 fundedTotal; uint128 chargedTotal` | First funding, 100 u; fixed refund denominator, aggregate charge |
| T1 | `uint128 remainingAtClose; uint128 refundsPaid` | Close with nonzero unused budget, 100 u |
| T2 | `uint128 remainingCredit; uint64 brakeSince; uint8 brakeFlags; uint56 layoutTag` | Nonzero layout tag at deployment, 100 u; no later new-word charge |
| `credits[funder]` | `uint256 contribution` | 100 u per distinct credited funder; maximum total funding is `<2^128` |
| `quota[account]` | `uint64 window; uint64 nextNonce; uint128 chargedInWindow` | 100 u at first admitted sponsorship; update in place, never delete while Active |

Constants and policy bytes are runtime code, priced byte for byte. No token balance/allowance is created by native funding itself. A first canonical sender account adds 100 u; first delegation persists its actual code bytes; account owner setup adds its own words. The target app's claim bitmap, token holder/allowance, and events are **additional**, not free because sponsorship pays them.

After close, a funder burns its credit and claims `floor(credit * remainingAtClose / fundedTotal)`. The last outstanding credit receives remaining rounding dust, at most `F-1` native base units for `F` funders. Transfer failure rolls back credit consumption. Anyone can relay a refund **to its recorded funder**, without changing the recipient. A fresh native recipient adds 100 u. Abandoned credits remain claimable; there is no sweep key or expiry that confiscates them.

## Paid-state action ledger

Let `H=ceil((E+128+O+L)/32)`. The illustrative simple signed envelope is **E=512 B**, output O=0; `Executed` adds 128 B where account batching is used. Native budget principal is not a network fee. For an actual sponsored app action, count `Δtarget = 100*newTargetWords + 100*newTargetAccounts + newTargetCodeBytes`, then compute **one** `H_combined` from the complete sponsored envelope, one base receipt, one account event and all target/sponsor output/events. Never add another item's whole standalone U, which would duplicate its envelope/base/account event. [ES1, ES2](../SOURCES.md#es1)

| Action | New words | Receipt event bytes L | Estimated U |
|---|---:|---:|---:|
| First funder, first funding | T0 + credit = 2 | Funding 160 + account 128 = 288 | 229 |
| Another distinct funder | credit = 1 | 288 | 129 |
| Same funder top-up before start | 0 | 288 | 29 |
| First sponsorship of initialized account | quota = 1, plus target words | Charged 192 + account 128 = 320, plus target events | 100 + Δtarget + H_combined; 130 for isolated control |
| Repeat sponsorship | target words only | 320, plus target events | Δtarget + H_combined; 30 for isolated control |
| Admitted app revert | 0 or first quota = 1 | Charged 192; O=128, no reverted app logs | 30 or 130 + surviving protocol additions |
| Campaign close with unused budget | T1 = 1 | Closed 160 + account 128 = 288 | 129 |
| Funder refund | 0; credit may clear | Refund 160 + account 128 = 288 | 29; +100 for fresh recipient |
| Trip deterministic brake | 0; T2 already nonzero | Brake 160 + account 128 = 288 | 29 |

Failed target state writes roll back; archive bytes, any admitted nonce account creation and protocol settlement still require accounting. Pre-admission rejection is a distinct outcome, not a free successful transaction.

Deployment illustration: **C=6,000 persisted runtime B**, one contract account, T2, `E_deploy=8,192 B`, O=0 and L=192 B → `6,000+100+100+266 = 6,466 u`. This is an explicit planning input, not a code-size claim. A separate factory and each instance's code cost must be added if used.

Complete escrow-lifecycle illustration: ten already-funded funders; 1,000 already-initialized accounts receiving one sponsorship each; one close; ten refunds; a no-new-state/no-event target used to isolate fee settlement. `U=6,466+229+9*129+1,000*130+129+10*29 = 138,275 u`, or **138.275 u per sponsored operation**, including campaign code. Actual app actions add their incremental words/accounts/code and change each combined H; cold onboarding adds account/delegation/setup costs and is unpriced until its protocol path exists.

At 1 s/height, the isolated shared-refill ceiling is `floor(2,764,800 / 138.275) = 19,994` operations/day; 50%/10% allocations give 9,997/1,999. Whole campaigns and failures lower realized output. Floor state fee for this campaign is **0.138275 DBLN**, plus exec/prove fees and tips; fees consume the sponsor budget, not a hidden user reimbursement.

The lifecycle exceeds a fresh 100,000 u burst and needs at least `ceil((138,275-100,000)/32)=1,197` additional finalized heights of refill. A warm 30 u sponsorship has a 92,160/day state-only ceiling; E=512 B implies an archive upper bound of eight operations/height before system traffic. All other [measurement limits](../MEASUREMENTS.md) still apply.

Current Track A has its own control ledger: for an already-delegated funded account, adding the first owner key creates array length plus two key words (300 u); E=512 B and OwnerAdded 160 B + Executed 128 B produce 29 archive u, **329 u setup**. A direct funded relay with E=768 B, OwnerExecuted 160 B and no target logs costs **133 u first success** (new ownerNonce) or **33 u warm**; an admitted revert with O=128 B costs 32 archive u and rolls back ownerNonce. Setup plus 100 successful isolated relays is **3,729 u**, before app deltas, account-code amortization or fresh senders. The original owner pays setup; the relayer pays attempts. This is a currently supported donation by the relayer, not an operational open escrow reimbursement product. [ES2](../SOURCES.md#es2)

## Brake, failure and trust

`brakeState()` reports escrow-wide campaign end, accounting shortfall or pinned-target identity mismatch, with guardian `address(0)`; no founder/controller pause exists. A permanent shortfall/hash mismatch can be latched by a permissionless, nonreverting `tripBrake`; admission also recomputes it, so it need not wait for that transaction. An individual account's exhausted window cap is a reversible refusal exposed through a separate account-capacity view, never an escrow-wide pause affecting other users.

Closing and valid funder refunds remain callable during a brake, **subject to actual remaining funds and transfer success**. A shortfall does not create repayment money. Users retain their own assets and may choose another campaign/relayer or pay normally if funded. No ordinary zero-balance fallback is promised.

Any funder can stop contributing; relayers and committee inclusion can censor; a token issuer or target app can fail its own action. A malicious sender can consume public funds within an address cap using permitted failing attempts. Price caps prevent unlimited charges, not Sybil spam or pre-inclusion reordering. Sponsor quota/balance contention can serialize the optimistic executor. Timelock encryption does not solve sponsorship liveness. [ES1, ES4, ES6, ES11](../SOURCES.md#es11)

## Better, worse and proof before release

Potential win: one approval with a visible app-paid fee; any budget funder and submitter; no sponsor custody, server-held approval key or reimbursement claim. Existing account batching is credited equally to originals. Worse: public subsidy abuse, campaign funding windows, quota storage and a missing protocol upgrade. Sui and ERC-4337 win whenever a delivered sponsorship stack is required now. [Sui](https://docs.sui.io/develop/transaction-payment/sponsor-txn), [ERC-4337](https://eips.ethereum.org/EIPS/eip-4337).

Benchmarks compare pinned EntryPoint/paymaster and Sui flows with identical user tasks, first funded setup, warm relay, zero balance, sponsor absent and failed app action. No published unverified UserOperation count is used as evidence. Pin upstream licenses/versions before execution.

Required tests: reserve/settle conservation; duplicate success/failure/restart; simultaneous sponsor nonce contention; stale quota window; failed refund; last-claim dust; malicious policy/app; fee cap overflow; rejected B5 reservation; zero-balance setup; no callable runtime impersonation. Measure all exec/prove/state dimensions, envelope/event bytes, account setup and target growth for ≥10,000 finalized heights. No fee or throughput improvement is measured in this revision.

Release gates: funded relay wallet flow first; native sponsor field and atomic settlement next; full initial-account sponsorship only after a specified payer/setup path. ERC-1271 and arbitrary-call sessions are not dependencies for the current relay and must not be silently enabled.
