# Receive already-funded pay when it becomes earned

Status: design, 2026-10-06; **Lane B, P1**. Best layer: account/wallet for ordinary payments and capped recurring transfers; a contract for a funded time-dependent entitlement. No Solidity or measured results. Inherits [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md).

## The person's problem

A contributor wants predictable access to earned pay instead of waiting for the next spreadsheet reconciliation and multisig payroll run; a grant recipient wants a vesting promise that the grantor cannot quietly revoke. Sablier describes manual payroll as its prior workflow and reports Flow exceeding $2.3M cumulative stablecoin volume in its 2025-08-15 article. The user task is knowing what money is available and receiving it, not generating a payment transaction every second. [Payroll need and dated activity](https://blog.sablier.com/how-to-automate-crypto-payroll-in-your-dao-or-startup-without-a-cfo).

## Original answer and EastSea opportunity

Sablier Lockup fixes amount and duration; Flow already supports open-ended streams. Restricting this design to a funded finite grant sacrifices Flow's flexibility. Sablier distinguishes protocol fees from its UI withdrawal/claim fee, so zero operator toll alone is not a new contract advantage. [Flow, 2024-12-12](https://blog.sablier.com/introducing-sablier-flow), [fee distinction](https://sablier.com/organizations).

EastSea already supplies ordinary token/native payment sessions, atomic owner batches and portable finalized receipts. The proposed contract advantage is shared code for many finite grants, explicit non-revocation and retirement of completed records. Compare it with originals that receive the same account batching. The toolbox's existing [single-grant vesting](../../contracts/src/lock/LinearVesting.sol) is another control: its separate runtime per grant and retained claimed word are measurable costs, not an excuse to replace a correct payout rule.

## Native funded-grant ledger

An immutable instance pins **one exact-transfer ERC-20**, expected code identity, maximum grant count per call (eight), non-revocation policy and arithmetic widths. Anyone can create a grant; there is no approved employer, operator fee recipient, mutable schedule, proxy or admin. Unrelated assets use separate instances.

`create(beneficiary,total,start,cliff,end)` pulls exact funds and creates a unique increasing grant id. Reject zero beneficiary/amount, overflow and any ordering other than `start <= cliff < end`. All three dates must fit `uint32` Unix seconds (through 2106-02-07); claims compare the full current timestamp without wrapping it into 32 bits. After that limit new grants need a separate new instance/version, while old fully earned rights still work. The creator chooses future dates explicitly; `block.timestamp` determines accrual. Equal timestamps produce equal vesting; confirmation cadence is not an accelerated salary clock. At/after end the full amount is earned. Before or at cliff it is zero; between cliff and end it is `floor(total*(now-cliff)/(end-cliff))`.

`claim(id)` can be paid for by anyone, but always transfers to the stored beneficiary. Pay `vested-released`, update released/outstanding before transfer, verify exact recipient delta and roll back all effects on failure. No-op claims revert before emitting a misleading successful payment. After the final payout, delete the two grant words. Metadata's id high-water mark never decreases/reuses an id, so a cleared grant cannot be recreated by replaying old calldata.

There is **no cancellation or depositor clawback** in this instance. A salary arrangement needing termination is a different product: existing payment sessions or another finite grant, not an unadvertised employer veto over this money. Never infer the released amount from token balance; donations do not undo prior withdrawals or create extra entitlements.

No claim expiry confiscates vested money. Abandoned unpaid grants retain their claim rights and occupied words indefinitely. A contract cannot erase those rights simply because an indexer has lost history. The wallet exports id, schedule, funding evidence and beneficiary. Asset issuer freezes or a lost unrecoverable beneficiary can leave money inaccessible; no founder rescue key exists.

## Storage, lifetime and state units

All amounts and aggregate outstanding fit `uint128`; timestamps fit `uint32`; grant id is `uint64`, with overflow permanently ending new grants while preserving old claims. Proposed packing must be verified with compiler output.

| Word | Fields | Newly occupied words |
|---|---|---:|
| M0 | `uint64 nextId; uint64 brakeSince; uint128 outstanding` | 1 at deployment, nextId starts at one; updates remain occupied |
| Grant S0 | `address beneficiary; uint32 start; uint32 cliff; uint32 end` | 1 per live grant |
| Grant S1 | `uint128 total; uint128 released` | 1 per live grant; total makes it nonzero before first payout |
| Token state | Instance/beneficiary balances; any retained allowance | 100 u per newly occupied external word |

`brakeSince==0` means not latched; a latched height remains nonzero. Creator/history belongs in the creation event because the creator has no later authority. A transaction-scoped reentrancy lock clears before the final diff; a persistent guard used instead must add its actual deployment word and gas. No persistent locked flag is silently assumed free.

Funded outstanding equals the sum of unpaid valid grant entitlements. The token's actual instance balance must cover it; unsolicited surplus is excluded from grant accounting. No on-chain participant list, cumulative payroll history or per-claim record is stored. Final deletion frees words but refunds **no burned state fee**. A previously emptied token balance reoccupied later costs 100 u again. [ES1](../SOURCES.md#es1).

## Signatures and the product

Creation: a funded employer approves exactly the deposit, creates the grant and resets allowance in one P-256 account batch/signature. Final allowance zero means no newly occupied allowance word, although events are priced. Recipient claim: one funded P-256 batch/signature; a third party may also pay a direct claim transaction to the fixed beneficiary without receiving their authority. No ERC-1271, NFT hook or arbitrary-call session is needed.

An already-added owner may use existing funded `ownerExecute`; initial owner/delegation setup and the actual relayer's nonce/event bytes are additional. A payment session can transfer a limited amount but cannot call `claim` today. A promised app-paid claim requires a real willing funded relayer; native sponsor escrow is gated on protocol fee settlement. [ES2](../SOURCES.md#es2), [sponsor boundary](../sponsorship/DESIGN.md).

The wallet displays “Available now”, “Fully available on…”, beneficiary and “This grant cannot be recalled.” The user need not understand token approvals, delegation, vesting slots or receipt Merkle trees. They still see claim fee, irreversible funding, issuer risk and the remaining waiting period. Automatic UI accrual is not automatic on-chain payment.

## Exact illustrative action ledger

`H(E,O,L)=ceil((E+128+O+L)/32)`; all values below are **layout/byte estimates**, not benchmark outputs. ERC-20 Transfer/Approval each contribute 192 B; account `Executed` contributes 128 B. `Created(id indexed,creator indexed,beneficiary indexed,total,start,cliff,end)` has four topics/128 data B = 320 B. `Claimed(id indexed,beneficiary indexed,amount)` has three topics/32 data B = 192 B.

| Action / cohort condition | Newly occupied final words | Chosen E / O / L | Estimated U |
|---|---:|---|---:|
| Create while instance token balance is already nonzero | 2 grant words | 768 / 0 / 1,024 | 260 |
| First create after instance balance is zero | 2 grant + 1 token holder | same | 360 |
| Claim to beneficiary with nonzero token balance | 0 | 512 / 0 / 512 | 36 |
| Claim to zero beneficiary balance | 1 token holder | same | 136 |
| Final claim to warm holder | 0; two grant words clear | same | 36 |
| Rejected/no-op claim | 0 app words | 512 / 128 / 0 | 24 |
| Permissionless brake latch | 0; M0 remains occupied | 512 / 0 / 288 | 29 |

Add 100 u for a first sender nonce account; no fresh native recipient is created in this ERC-20-only fixture. Token implementations emitting extra Approval on allowance spend add their actual event bytes. A third-party claim omits the account event only when it is truly a direct transaction; recompute its actual envelope once.

Deployment illustration: C=6,000 persisted runtime bytes, one contract account, M0 and E=8,192/O=0/L=160: **6,465 u**. The code size, deployment envelope and event are chosen planning inputs. A factory or account deployment wrapper adds its own code, events and actual shared transaction bytes.

Complete cohort: 100 grants are funded before any withdrawal, first creation 360 u and 99 at 260 u, then four claims per grant including the final deletion. All callers/accounts and beneficiary token balances already exist; funder balances remain nonzero. `6,465+360+99*260+400*36 = 46,965 u`, **469.65 u per four-claim grant**. One newly receiving token-holder word per beneficiary raises the total to **56,965 u / 569.65 u per grant**. If deposits are interleaved after an emptied pool or funders later receive tokens back in a different product, price those reoccupations separately.

At full shared B5 refill, compute the state-only ceilings as `floor(2,764,800/469.65)` warm or `floor(2,764,800/569.65)` fresh-holder completed grants/day, before other limits and deployment amortization changes. At 10% refill, divide refill by ten before flooring. The first cohort burns **0.046965 DBLN** at the state floor and occupies at least `ceil(46,965/32)=1,468` refill heights of capacity; exec/prove gas, achieved throughput and actual bytes remain **TO MEASURE**. Waiting for vesting is a separate latency constraint; throughput is not a claim that four earned withdrawals happen in a day.

## Failure, MEV, immutability and brake

No price auction or random seed is needed. Ordering can move a claim across its timestamp threshold but cannot redirect it or pay more than funded earned value. Public payroll reveals amounts/timing. A withheld relayer, committee inclusion, frozen token or missing native fee funding can delay withdrawal; receipt inclusion authenticates paid bytes, not employment facts. [ES4](../SOURCES.md#es4), [ES7](../SOURCES.md#es7).

`brakeState()` has guardian zero; new grants stop on an actual balance deficit or pinned code mismatch. Anyone may latch a permanent entry brake in a successful `tripBrake` call; each entry checks the live predicate before latching. Normal claims remain callable during a brake only if exact funds can be delivered **without taking another grant's backing**. On a deficit, payouts require post-transfer balance >= post-transfer outstanding; this may make all claims fail until someone voluntarily restores backing. No pro-rata haircut, automatic bailout or privileged sweep is implied. Proxy behavior is not pinned by its facade code hash; admit such assets only with an explicit additional issuer trust model.

Token, schedules, recipient, non-revocation rule, high-water ids and brake logic are immutable. A new version is a separate address with separately authorized funding; the creator has no admin power over old grants.

## Tests and neutral benchmark

Pin Sablier Lockup and Flow versions/licences separately and the toolbox single-grant control. Use identical funded amount, cliff/term, recipient freshness, four-withdrawal trace and EastSea account batching. This instance accrues **cliff-to-end without catch-up at the cliff**; start-to-end accrual with an initial withdrawal lock is a different schedule. Match actual payout curves, and report any original that lacks this curve as a capability difference rather than changing its promised cash flow to make a cost comparison. Compare open-ended Flow only with its removed capabilities plainly listed. Measure code amortization at 1/100/1,000 grants, abandoned grants and full-balance holder reoccupation.

Tests: earned-value/remaining-backing conservation; first/last-second, cliff and equal-timestamp boundaries; rounding; no-op failure; donation invariance; partial/final claims; id overflow/replay; receiver transfer failure/reentrancy; fixed recipient under relay; token freeze/deficit and brake exit conditions; exact unit diff and sequential/parallel agreement. Execute the complete plan in [MEASUREMENTS](../MEASUREMENTS.md), including failed-attempt costs and archive capacity.

Potential win: one shared immutable grant ledger with clear non-revocation and local funding evidence. Worse: irreversible deposits, no open-ended payroll/termination, nontransferable rights and indefinitely retained abandoned grants. Sablier's richer stream types, transferred positions and mature tooling may solve the user's actual task better; no superiority is measured here.
