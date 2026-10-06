# Escrow: agree first, hold funds, then release them

A buyer paying a stranger risks losing payment before useful delivery; a seller working first risks never being paid. Before escrow they had to trust the other person or give custody and dispute power to an intermediary. Kleros Escrow addresses this with locked payment, settlement negotiation and a court; its documentation explicitly includes freelance work and physical goods. EastSea can remove a compulsory custodian and make the agreement easy to accept, but cannot prove that a parcel arrived or that work was satisfactory. [Kleros Escrow](https://docs.kleros.io/products/escrow) (read 2026-10-06).

**Status / priority:** proposed, unimplemented; Lane B / P1. Exact-transfer assets only. Inherits [verified primitives](../PRIMITIVES.md) and [measurement rules](../MEASUREMENTS.md); quantities below are layout estimates, not measured gas or results.

## Why another layer helps

Seaport already solves atomic exchange of on-chain assets through offers and consideration; a delayed goods escrow would make that task worse. Use the originals track for that task. This design is for delivery that cannot occur atomically on-chain. Seaport also supports on-chain validation, so native batching is not uniquely our contract's advantage. [Seaport overview](https://docs.opensea.io/docs/seaport), [order models](https://docs.opensea.io/docs/seaport-models) (read 2026-10-06).

Kleros already has zero platform fees, negotiated splits and permissionless deadline execution; claim no fee-removal advantage over it. Its documented arbitration requires fees and evidence, and failure to pay within the fee timeout can determine the outcome. The native answer offers a smaller bilateral contract or an instance with an **explicitly chosen immutable arbiter**; it trades court procedures for simpler, narrower rights. [Kleros resolution and costs](https://docs.kleros.io/products/escrow) (read 2026-10-06).

The wallet shows “Hold 100 for Sam until 12 October”, the exact terms, who receives the money on silence, and any named dispute decision maker. It resolves names to an address once and shows the pinned address; it never hides timeout loss or arbitral authority. No NFT receipt, token permit or generic application session is needed. [Account/name boundaries](../PRIMITIVES.md#capability-and-dependency-register).

## Immutable instance and state machine

One `EscrowBook` instance has immutable asset address (zero for DBLN), exact-transfer policy, optional arbiter address, fixed ruling duration and public specification hash. Users choose the instance; there is no network-selected mediator, mutable arbiter list, protocol-fee recipient, owner, proxy or rescue key. A selected arbiter may award funds only to the two fixed parties and charges no fee through this template; external agreed fees are a separate disclosed payment.

1. Buyer funds `create(seller, amount, acceptBy, deliverBy, timeoutPolicy, termsHash)`. Require distinct nonzero parties, `0 < amount <= 2^128-1`, `totalLiability + amount <= 2^128-1`, `now < acceptBy < deliverBy`, nonzero terms hash and exact custody increase.
2. Seller accepts the exact record before `acceptBy`; acceptance is a transaction, not a receiver hook. Buyer can cancel while unaccepted; anyone can make an unaccepted record refundable after `acceptBy`. A competing acceptance/cancellation is decided by finalized ordering.
3. Once accepted, buyer can release all to seller; seller can refund all to buyer. Either can propose a split, and only the other party can accept that current proposal, checking its round and award. These voluntary paths also resolve a disputed record and invalidate later rulings; no action may resolve twice. Neither proposal nor evidence upload moves funds.
4. With arbiter zero, anyone resolves at `deliverBy` using the recorded `BuyerRefund` or `SellerPayment` default. Both parties accepted that choice: refund-on-silence lets a dishonest buyer keep delivered work; pay-on-silence lets a dishonest seller be paid without delivery. No permissionless timeout can solve both risks.
5. With a selected arbiter, either party may dispute **before** `deliverBy`; a disputed record instead expires at `rulingBy = now + immutableRulingDuration`. Only the arbiter may choose a split before `rulingBy`; after it, anyone applies the recorded default. The arbiter cannot extend the deadline, change parties or redirect payment to itself. Collusion can still award the victim's payment to its counterparty.
6. Resolution records seller award `s` and buyer award `amount-s`. Each payout is a separate pull to its fixed party; anyone may trigger it. Zero awards are marked consumed immediately. Delete live record/proposal only after both awards are consumed. No automatic transaction occurs when a deadline passes.

The public terms hash pins agreement bytes, not their availability or truth. Both wallets export the complete terms and receipts. An unavailable archive cannot erase live payout rights; certified receipt inclusion is not proof of delivery. [Receipt and availability limits](../PRIMITIVES.md#capability-and-dependency-register).

## Packed live rights and replay memory

| Storage word | Fields / initial occupancy | Retirement |
|---|---|---|
| Global G | `totalLiability:uint128`, `nextId:uint64`, `brakeSince:uint56`, `latched:uint8`; `nextId=1` makes it nonzero at deployment | Counter and brake retained forever; never reset/wrap IDs |
| Record S0 | `buyer:160`, `clock:64`, `phase:8`, `paidFlags:8`, spare:16; clock starts as `acceptBy`, becomes `rulingBy` only on dispute | Delete after both payouts |
| Record S1 | `seller:160`, `deliverBy:64`, `timeoutPolicy:8`, spare:24 | Same |
| Record S2 | `amount:uint128`, `sellerAward:uint128`; amount makes word nonzero immediately, award initially zero | Same |
| Record S3 | `termsHash:256`, required nonzero | Same |
| Optional S4 | `proposedSellerAward:uint128`, `proposalRound:uint64`, `proposerRole:uint8`, flags:8, spare:48; absent at create | First proposal adds one occupied slot even when award is zero; delete at completion |

No authorizations remain valid off-chain: calls require `msg.sender` to be the relevant account, and the account transaction nonce is enforced. Deleted IDs reject as empty and can never be recreated because G's high-water counter remains. This is the retained replay boundary; adding signed agreements later requires separately priced, persistent nonce/bitmap memory and an ERC-1271/domain audit. Receipt logs cannot replace it. Abandoned unresolved records remain live until their timeout; permissionless payout can then retire them if the asset transfer succeeds.

## Meter every action, including conditional first writes

Use `H = ceil((E + 128 + O + Σ(64 + 32*t + d))/32)` from design 27; `E` is the complete canonical signed envelope, `O` receipt output, `t` includes the event-signature topic, and `d` is event data bytes. A self batch's `Executed(uint256)` adds 128 metered bytes. An ERC-20 `Transfer` or ordinary `Approval` adds 192. Tables include them; actual tokens/account paths can emit more events. [Meter and account source](../PRIMITIVES.md#exact-paid-state-interpretation), [ES2](../SOURCES.md#es2).

| Action | New record slots | Other new persistence | Illustrative E / O / total event bytes | Illustrative H / U before other freshness |
|---|---:|---|---|---:|
| Create, ERC-20 three-call approve/fund/reset batch | 4 | Book token balance +1 if zero; allowance ends zero, so +0 new allowance slots | 768 / 0 / 1,056: Funded 352 + Transfer 192 + two Approvals 384 + Executed 128 | 61 / 461 |
| Seller accept | 0 | S0 updates an occupied word | 320 / 0 / 288: Accepted 160 + Executed 128 | 23 / 23 |
| First / later split proposal | 1 / 0 | Role and round make S4 nonzero even for a zero seller award | 384 / 0 / 352: Proposed 224 + Executed 128 | 27 / 127 or 27 |
| Direct release, refund, accepted split or timeout resolution | 0 | Nonzero seller award shares occupied S2; zero-award flags share S0 | 352 / 0 / 288: Resolved 160 + Executed 128 | 24 / 24 |
| Dispute, optional arbiter instance | 0 | Ruling deadline reuses S0; no unpriced dispute slot | 352 / 0 / 320: Disputed 192 + Executed 128 | 25 / 25 |
| Pull one nonzero payout | 0 | Recipient ERC-20 balance +1 if zero; final record deletion refunds no burned units | 352 / 0 / 512: Paid 192 + Transfer 192 + Executed 128 | 31 / 31 |
| Latch brake | 0 | Nonzero timestamp/flag share G | Measure E/O/events; do not assume a free transaction | H / H |

Each newly occupied slot adds **100 u**; each actually created sender/native-recipient account adds another **100 u**. A buyer that funded its entire ERC-20 balance may have a zero balance before refund and pay +100 u on receiving again. A zero-to-nonzero recipient balance costs +100 even if that person's account already exists. DBLN paths remove ERC-20 balance/approval slots and their logs but can create native recipient accounts. Existing nonzero updates cost no new-slot units; all calls still pay H and measured exec/prove fees. Separate direct-call, self-batch and added-owner relay envelopes; cold account provisioning is additional measured setup, not included here.

Deployment costs `D = 100 book-account u + 100 G-slot u + actual persisted code bytes + H_deploy`, plus constructor effects and factory counter/code if used. Immutable values occupy paid code bytes. Do not multiply a guessed runtime by transactions or call factory deployment free. Amortize the measured D over the actual completed cohort, including abandoned records; no periodic rent or deletion burn refund exists.

## Lifetime example and B5 ceiling

For create → accept → full release → seller pull, with existing nonzero token balances and a warm book, the above illustrative bytes give `461+23+24+31 = 539 u`. A cold book adds 100 for its token balance; a seller with zero token balance adds 100, making that first workflow 739 u. The account's `execute` returns no top-level output even if its inner create call returns an id; the Funded event identifies the record. New account creation, setup, extra token logs, retries or split/dispute legs add their own costs.

For 1,000 completed workflows with fresh seller **token balances**, existing accounts, no failures, and a hypothetical fully metered `D=8,000 u`, lifetime growth is `1,000*(539+100) + 100 + 8,000 = 647,100 u`, or 647.1 u/workflow. This cohort keeps the book token balance nonzero between deposits/payouts until the final settlement; fully emptying it between each deal would add 100 u for every reoccupation. Floor state fee averages **0.0006471 DBLN**; principal is separate, and total fees also include `G_exec*p_exec + G_prove*p_prove + tip`. With no refill during the initial sequence, deployment plus 143 such workflows uses 99,477 u; a 144th exceeds the 100,000 u bucket at 100,116 u. [B5 rules](../PRIMITIVES.md#b5-is-shared-bursty-and-finite).

State-only ceilings at 1 s/finalized height are about **427 / 2,136 / 4,272 workflows/day** at 10% / 50% / 100% of shared refill. Processing the full cohort from an empty debt bucket needs at least `ceil((647,100-100,000)/32)=17,097` refill heights. These are ceilings, not achieved throughput; token custody and G writes contend, and payload, exec, prove, per-block slot and transaction limits can bind first. Added proposals, unsuccessful calls and offline/non-claiming parties count in lifetime results. [Benchmark method](../MEASUREMENTS.md#throughput-and-latency).

## Signature and consumer sequence

Funded, provisioned users: buyer reviews and signs one P-256 create batch; seller reviews and signs one acceptance; buyer signs one release; seller signs one withdrawal, or any willing caller pays to trigger the fixed payout. That is three party decisions and up to four submitted transactions, not one signature per lifetime. A split adds one proposal signature plus the other party's acceptance; disputes add the initiating signature and an arbiter ruling transaction. No typed-message signatures are required.

The buyer's ERC-20 approval/action/reset shares one atomic `execute(Call[])`. Give Kleros and other originals the **same batch benefit** when benchmarking on EastSea. Existing added-owner relay can pay for an already configured owner's signed batch; it is not native fee sponsorship, free initial owner setup or arbitrary app-session support. Show a funded fallback if the relay disappears. ERC-1271 and receiver hooks are pending and not prerequisites for this bilateral flow. [A1–A4 / F2 boundaries](../PRIMITIVES.md#capability-and-dependency-register).

## Failure, MEV, brake and economic trust

- Conservation: custody backs total liability; each resolution has `0 <= s <= amount`; paid flags prohibit a second payout; liabilities fall only after successful exact payment. Check-effects-interactions plus a bounded reentrancy guard must cover token/native callbacks and proposal/dispute interleavings; transient-guard compatibility must be probed rather than assumed.
- The deterministic local entry brake is `latched || custody < totalLiability || nextId == maxUint64`; anyone can latch an observed predicate, and `brakeState()` reports guardian zero. Entry performs the same predicate check. A revert cannot persist its latch, so report effective state from the predicate and provide a separate latch call; timestamp/flag updates use G. Only new funding is stopped.
- Acceptance, negotiation, ruling, timeout and withdrawal remain callable under a brake with their ordinary authorization/deadline checks. Withdrawal requires full liability backing and a functioning recipient transfer; a frozen or confiscating issuer can block every exit. Donation can cure shortage but gives no claim or rescue discretion. No brake permits early confiscation, deadline extension or arbitrary distribution.
- One-second finality does not prevent deadline censorship or acceptance/cancel races. A malicious buyer/seller may watch ordering and use the accepted timeout against the other; a proposer cannot redirect payout, but can block inclusion until a deadline if it controls ordering. Payout callers cannot front-run funds to themselves. [Consensus limits](../MEASUREMENTS.md#user-and-trust-record).
- The selected arbiter can make a dishonest split, omit a ruling or collude; it cannot seize unrelated records. Committee threshold can censor/finalize dishonestly, token issuers can freeze, hosted wallets/relayers can refuse service, and stolen account authority can authorize release. Recovery does not revoke a stolen original key. [Trust boundaries](../PRIMITIVES.md#capability-and-dependency-register).

## What wins, what loses, and proof before release

Expected advantage: fewer live words than general order/dispute machinery, no compulsory dispute provider, pinned rights, and a wallet agreement/receipt flow that never asks users to understand approvals, BLS or Merkle roots. These are hypotheses; Kleros already supplies fee-free escrow and negotiated settlement. Kleros wins for people needing its juror selection, evidence and appeal system; Seaport wins for immediate digital-asset exchange. Bilateral silence policies provide weaker stranger protection, and this immutable instance cannot patch mistakes or guarantee refund during token failure. [Kleros capabilities](https://docs.kleros.io/products/escrow), [Seaport](https://docs.opensea.io/docs/seaport).

Pin licensed Kleros V1/V2 escrow and Seaport 1.6 behavior before implementation; compare escrow tasks to Kleros and atomic NFT tasks to Seaport without pretending they are the same task. Follow all three paths in [MEASUREMENTS](../MEASUREMENTS.md): original native chain, fidelity-checked original on EastSea, native on the same EastSea genesis. Publish original wins and every unsupported outcome.

Test conservation/rounding, every timestamp equality, both timeout policies, seller nonacceptance, proposed zero/full/interior splits, repeated/stale proposal acceptance, absent/late/dishonest arbiter, payout replay after deletion, max-ID brake, zero-field writes, exact-transfer failures, callbacks, blocked recipients, donor repair and unavailable terms/frontend. Verify P-256 sequences, real storage diffs, logs/envelopes, cold/warm holders, sequential/parallel roots and conflict re-execution. Benchmark full successful and disputed lifetimes, deployment amortization, failed retries and abandoned deals for ≥10,000 finalized heights; record p50/p95/p99 over ≥100 completed samples. Do not release until exit/accounting invariants and measured signed exec/prove/state limits pass.
