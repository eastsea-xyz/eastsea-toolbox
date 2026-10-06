# Get the required asset without exceeding a spending cap

Status: design proposal, 2026-10-06; wallet + minimal settlement contract; lane C, priority P2; both RFQ modes gated on deployed ERC-1271.
Inherits [verified primitives](../PRIMITIVES.md), [measurements](../MEASUREMENTS.md), and [problem catalog](../PROBLEMS.md).

## Problem before mechanism

A user needs a particular amount of B—for a payment, collateral repayment or purchase—and wants the least A spent without learning routes or exposing unbounded execution authority. Aggregation and solver systems address routing and price competition on the user's behalf. CoW formalizes user acceptance sets, solver routing and competing solutions; the need is satisfying a price constraint, not owning an on-chain order book. [CoW solving specification, accessed 2026-10-06](https://docs.cow.fi/cow-protocol/reference/core/auctions/the-problem).

## Original constraints and EastSea opportunity

CoW already supports ERC-1271 orders and chain/deployment-bound digests. Its documented solver competition requires whitelisted settlement senders and combines contract, infrastructure and governance-enforced rules. This is an actual coordination and monitoring design, not proof that every solver can steal funds. [CoW signing schemes](https://docs.cow.fi/cow-protocol/reference/core/signing-schemes), [solver competition rules, accessed 2026-10-06](https://docs.cow.fi/cow-protocol/reference/core/auctions/competition-rules).

The proposed EastSea difference is unrestricted exact-output settlement without protocol/operator fees, custodial inventory, stored order rows or a chosen settlement sequencer. It forgoes CoW's uniform-price auction and best-execution coordination. A spending cap proves an acceptable fill; it does **not** prove the best available price. Quote selection belongs in the wallet and any solver can compete.

Atomic P-256 batching benefits both this design and a compatible original. ERC-1271 is **PENDING** in the inspected account; no general signed-order verifier can be inferred from `onlySelf`. Current payment sessions do not authorize arbitrary exchange calls. [ES2](../SOURCES.md#es2).

## Two explicit execution modes

**Direct mode, maker-1271 gate:** wallet gathers maker-authenticated quotes; the user calls `acceptExactOutput(quote,makerSignature,maxA)` from their own account. The quote binds maker, buyer, recipient, A, B, exact A/B amounts, maker window/bit, expiry and deployment/chain domain. Validate the maker's ERC-1271 signature and consume the maker's replay bit. The maker must also have a bounded B allowance and inventory; an allowance by itself is **never price consent**. Settlement transfers exact B from maker to recipient and exact A from caller to maker atomically, provided `exactA <= maxA`. Buyer authority comes from its account transaction. A withdrawn maker allowance reverts everything. No taker application nonce or order row is stored, but maker replay rights remain on-chain.

**Delegated mode, dependency gate:** after a wallet verifies deployed ERC-1271, the user signs an account-bound intent and any solver pays to `fill(intent,signature,actualA)`. The intent contains chain ID, verifying contract/code domain, owner, recipient, A, B, exact B, maximum A inclusive of the quoted solver charge, window ID, bit index, `validAfter`, `validUntil`, and optional solver binding. Partial fills are unsupported. Use a tighter cap to negotiate surplus; otherwise the solver may spend the whole cap.

`fill` validates the account signature, active window and unconsumed bit, sets the bit, and performs exact balance-delta transfers. Its B source and A recipient are **the actual caller**, optionally checked against the signed solver binding; caller consent supplies the maker side without another signature. It cannot name a third party's B allowance. Failed transfers revert the bit too. No arbitrary solver call into a user's account and no route callback is permitted. Solvers can source inventory through their own independently authorized transactions; that whole route's cost is added to a route benchmark.

There is no central solver list, compulsory auction API, settlement toll, perpetual user approval recommendation or claimed global best price. A solver's explicitly quoted charge remunerates a counterparty; the user sees it and can choose another solver. Settlement retains no principal or solver deposits.

## Bounded replay and storage lifetime

Each owner has **one active window**, at most 256 intents, and an immutable maximum validity of 300 finalized heights. This is a storage bound, not a promise of five wall-clock minutes during a halt.

| Field | Layout | Newly occupied slots |
|---|---|---:|
| Owner window | `uint64 id; uint64 beginsAt; uint64 expiresAt; uint64 flags` in `control[owner]` | 1 on first activation; stays nonzero forever; owner is maker in direct mode and buyer in delegated mode |
| Owner replay bits | `uint256 used[owner]` | 1 on first consumed/cancelled bit after each reset |
| Token pair, maximum TTL, verifier domain | Runtime immutables per instance | Code bytes; no mutable allowlist |
| Local brake | `uint64 latchedAt; uint8 reason` | 1 on first monotonic latch; zero at deployment |
| Reentrancy guard | Set and cleared within one transaction | 0 final occupied slots |

Only the owner's account can activate/advance windows, invalidate bits or close the window. IDs strictly increase; overflow ends that address's use of this instance. Advancing changes the signed domain and clears `used`, making old signatures invalid even if their bit memory disappears. A close flag rejects fills before a subsequent activation. A window cannot be reopened with the same ID. Copies of intents for different owners/instances/chains do not match.

Invalidation races with settlement; whichever is finalized first wins. Window expiry requires no expiry transaction, but allowance revocation remains the wallet's offered cleanup action. A missing wallet/archive cannot resurrect an old window. The two mappings hold current rights; logs are not replay protection. [ES7](../SOURCES.md#es7).

At most two occupied settlement slots exist per owner, but each later bitmap reset/refill can incur another 100 u. No historical refund is credited. Amortizing a filled word across 256 orders yields `100/256=0.390625 u/fill`; sparse windows cost the full 100 u per first fill. Sparse user arrivals still add the permanent control slot.

## Full state and receipt estimates

`H(E,O,L)=ceil((E+128+O+L)/32)` and `U=100*A+100*S+C+H`. `E` includes the full account envelope or solver transaction plus submitted signature bytes. Illustrations set `O=0`. Topic counts include signature topics. [ES1](../SOURCES.md#es1).

Standard Transfer/Approval events each contribute 192 bytes. Account `Executed` contributes 128 bytes. Proposed `Filled(owner indexed,solver indexed,in,out,window)` has three topics/96 data bytes = 256 bytes; `Window(owner indexed,id,expiry)` has two topics/64 data bytes = 192 bytes.

| Action | New final occupied slots | Illustrative H | U |
|---|---:|---|---:|
| Direct approve/fill/reset, nonzero destination holdings and previously used maker bitmap | 0 | `H(1024,0,2*192+2*192+256+128)` | 72 |
| First direct fill in maker window | 1 maker bitmap | Same | 172 |
| Direct fill with recipient B balance zero | +1 external token slot | Add to applicable direct row | +100 |
| Delegated setup: activate + one bounded persistent A allowance | 2: control + external allowance | `H(768,0,192+192+128)` | 244 |
| First delegated fill in a window, solver uses own account batch | 1 bitmap | `H(768,0,2*192+256+128)` | 152 |
| Further fill into same nonzero bitmap | 0 | Same | 52 |
| Close window + revoke A allowance | 0; zeroing yields no state-fee refund | `H(512,0,192+192+128)` | 36 |
| Cancel first bit in an otherwise unused window | 1 bitmap | `H(512,0,160+128)` | 126 |
| First brake latch | 1 metadata slot | `H(384,0,160+128)` | 125 |

These envelope lengths are fixtures to replace with actual canonical bytes; an ERC-1271 payload or route can make them longer. Add 100 u per zero-to-nonzero token balance, allowance or first sender nonce account. “Existing address” does not make a zero token balance free. Solver allowance setup/revocation costs are separate and must be allocated to its fill cohort.

Direct taker A allowance is created and cleared in the same transaction: zero final occupied slots, with its events still priced. Direct maker setup/close uses the same 244/36 u illustrations as delegated buyer setup/close, with B replacing A. Delegated buyer A allowance persists across transactions: 100 u on creation. A delegated solver B allowance also costs 100 u on its first persisted creation; it is not paid afresh on every fill if it remains nonzero.

Deployment `D=100+runtime_bytes+H(E_deploy,O_deploy,L_deploy)` initializes no mapping slots. Quotes never submitted on-chain cost no chain state; accepted signatures, ciphertexts and calldata are envelope bytes, not free off-chain history.

## Signature sequence and UX

Direct first use: maker activates its window and bounded B approval with one setup transaction, then signs one quote through ERC-1271. Wallet presents exact B, all-in maximum A, counterparty and deadline; one taker P-256 transaction signature authorizes `[approve(A), acceptExactOutput, approve(0)]`. The taker needs no separate message signature or replay setup; maker setup, quote signature and eventual cleanup are counted in the total. A compatible original through the same account receives the same batching comparison.

Delegated first use: one P-256 setup transaction, one later typed intent signature; solver submits its own fee-paying transaction. Repeated fills need one user message signature each, plus solver submission. Close/revoke adds one owner transaction signature. Count these separately; do not call setup or cancellation “gasless.” An already added owner can relay current self-call batches via `ownerExecute`; account-owner setup costs still apply. [ES2](../SOURCES.md#es2), [ES6](../SOURCES.md#es6).

**What the user never needs to understand:** routing hops, solver allowance, EIP-712, nonce windows or bitmap packing. They see exact received amount, maximum spent, solver charge, expiry, and whether a chosen quote can fail.

## MEV, failure and deterministic entry brake

An on-chain fill has no partial state: both legs and replay changes succeed or revert. It remains reorderable. A copy of a public intent can fill only its signed recipient/price, but can select the whole allowed spend; optional solver binding prevents a different filler at the cost of counterparty availability. Direct-mode copied calldata cannot authorize spending from the original user's account or change the maker-signed buyer/recipient/price.

No hidden-order claim is made. Draw timelock encryption needs the SDK, raw signature authentication and pre-signing boundary in [ES4](../SOURCES.md#es4); it is an optional later channel, not one-second sealed RFQ. The `Randomness` hash word is not a ciphertext key, and zero does not prove a seed is unknown. No encrypted mempool exists. [ES5](../SOURCES.md#es5).

Local `brakeState()` is deterministic and scoped to the instance's immutable tokens. If a token's live code hash no longer matches its constructor pin, state is entry-braked, guardian zero, since the permissionless latch height. `pokeBrake()` records a monotonic latch; fills check the live predicate before a latch. Stable proxy code does **not** pin implementation behavior: proxy/issuer assets require a separately visible trust assumption and may fail delta checks.

Closing windows, revoking allowances and retiring expired replay words stay callable in the latched instance. No funds are trapped in settlement; token issuers may still freeze account assets. A changed token, missing solver inventory, expired quote, invalid signature or replay causes a visible failure, not an operator override.

All matching/replay rules, TTL, token pair and code-domain rules are immutable. There is no owner, pause authority, privileged solver or fee recipient. A signer/account key can steal its own account's assets; a committee can censor; a solver can refuse or fill at the cap; a frontend can hide better quotes. Users can self-host and settle directly, but cannot conjure missing inventory.

## Workflow throughput and comparison gate

One delegated lifecycle with exactly one fill is `244+152+36=432 u`, plus both users' token freshness, solver setup and deployment share. Two fresh receiving balances add 200 u, yielding 632 u. A direct maker lifecycle with exactly one fill is `244+172+36=452 u`; subsequent fills in that window cost 72 u each. A zero-fill expiry still costs `244+36=280 u` if setup/cleanup occurs. A full 256-fill delegated window costs `244+152+255*52+36=13,692 u` (53.484375 u/fill), not 52 u for every cold customer.

At 100% shared B5 refill, direct fills with existing bitmaps have a generous state-only bound `32/72=0.444/s`, or 38,400/day, before maker setup amortization. Single-fill delegated lifecycles have at most `2,764,800/432=6,400/day`; fresh-destination lifecycles at most 4,374/day. Single-fill direct maker lifecycles have at most 6,116/day. Canonical byte ceilings, verifier gas, route costs, conflicts and system traffic can bind first. At 10% refill, scale these down by ten. [ES1](../SOURCES.md#es1).

Floor state-only fees are 0.000072 DBLN/direct fill with existing bitmap, 0.000452 DBLN/single direct maker lifecycle and 0.000432 DBLN/single delegated lifecycle. Execution/proving gas, signed-message verification, relayer charges and solver inventory/routing costs are **UNKNOWN—TO MEASURE** and separately displayed. Price improvement is measured against simultaneous executable quotes, not assumed from zero protocol toll.

Pin gate: select exact `cowprotocol/contracts` GPv2 settlement commit/deployment, signing scheme, authorization settings and licence; pin an original aggregator/router route for the same pair. Compare originals on their own chains, originals with EastSea batching, and this same restricted task through [MEASUREMENTS.md](../MEASUREMENTS.md). Do not score unsupported partial fills or multi-party uniform-price auctions as equivalent functionality.

Tests: cross-chain/account replay; window reset/expiry/cancel races; 256-bit boundaries; partial-fill rejection; actual-spend cap and recipient; arbitrary solver entry; token failures; no retained balances; ERC-1271 invalid/changed owner behavior after A4; matching when all APIs disappear; cold allowances; sequential/parallel agreement; failed relayer fees; and B5 sustained load. Include solver-price/quote-failure distribution, censorship timeout and signed-vs-direct user steps.

Original wins to publish: mature auctions, partial orders, routing depth, coordinated best-execution checks and established solver inventory can give better prices or reliability than this unrestricted narrow matcher. Fewer controls are not automatically a better trade.
