# Exchange an asset now, at a visible price limit

Status: design proposal, 2026-10-06; contract + wallet; lane C, priority P2.
Inherits [verified primitives](../PRIMITIVES.md), [measurements](../MEASUREMENTS.md), and [problem catalog](../PROBLEMS.md).

## Problem before mechanism

A person holding asset A wants asset B immediately without finding a counterparty or entrusting a trading venue with custody. An AMM supplies an executable price from pooled inventory; Uniswap documents this distinction from an order book. The need is immediate exchange, not a particular reserve formula. On EastSea the wallet should show “receive at least B; spend A; expires at time T.” It must still expose liquidity risk and price impact. [Uniswap v2 swapping documentation, accessed 2026-10-06](https://developers.uniswap.org/docs/protocols/v2/concepts/swapping).

## What the original answer gets right, and what changes

Uniswap v2 provides arbitrary ERC-20 pairs, immutable core contracts, LP compensation, flash swaps and cumulative prices. Its factory can enable a protocol fee. The March 2020 paper is a specification baseline, not a claim that today's entire Uniswap product has these constraints. [Uniswap v2 paper, March 2020](https://app.uniswap.org/whitepaper.pdf).

EastSea's atomic account batch can combine exact approval, exchange and approval reset. It can do that for a faithfully ported original too; this is an **account advantage in both controls**. P-256 does not make a secp256k1 permit usable. New occupied state and archived envelopes cost B5 capacity even when execution is cheap. [ES1](../SOURCES.md#es1), [ES2](../SOURCES.md#es2).

The native experiment removes features that this narrow task does not need: no hook, callback, embedded price oracle, mutable protocol fee or default routing intermediary. This reduces the proposed core's obligations and persistent fields; an actual gas/proving advantage is unmeasured. It cannot replace advanced LP strategies. Uniswap v3 explicitly improves capital efficiency with bounded price ranges; that is an original win for concentrated liquidity. [Uniswap v3 paper, March 2021](https://uniswap.org/whitepaper-v3.pdf).

## Native contract and wallet path

- Anyone deploys a pair with two distinct exact-transfer ERC-20 addresses and an immutable LP fee `f`, bounded at deployment to 0–100 bps.
- No canonical factory allowlist, asset endorsement, protocol-fee recipient, proxy, operator toll or owner exists. The entire fee stays in reserves for liquidity holders; `f=0` is permitted, not promised to attract liquidity.
- `swapExactInput(amountIn,minOut,recipient,deadline)` pulls input from the caller, checks balance deltas, computes output using floor division and the fee-adjusted constant-product invariant, and sends output directly to the named recipient.
- A separate exact-output entry quotes with upward input rounding and checks `maxIn`; both paths forbid zero output and values above the `uint112` reserve bound.
- `add(amount0,amount1,minShares,deadline)` accepts only proportional deposits after initialization; initialization fixes the ratio chosen by the first LP, not a certified fair price.
- Initial shares use a geometric-mean rule with an immutable minimum permanently locked **inside the supply field**, not credited to a new sink mapping entry. Donation and first-depositor attacks remain test obligations.
- LP rights are nontransferable `shares[owner]` in this minimal instance. Only the owner's account can remove them to an explicit receiver. ERC-20 wrappers are a separately priced future feature, not silently included.
- Arbitrary tokens can be named, but successful entry requires exact sender/pool/recipient balance deltas. Rebase, fee-on-transfer, ERC-777-style callbacks, issuer freezing and upgradeable token behavior are unsupported risk cases.
- The wallet compares this pool with [direct RFQ settlement](../intent-exchange/DESIGN.md); quote collection and route search remain off-chain. A multi-pool route is separately measured, not billed as one swap.

No API availability is needed after a user has the pair address and assets. Indexing receipts can reconstruct activity; on-chain shares and reserves retain live rights. There is no historical receipt proof used as authorization. [ES7](../SOURCES.md#es7).

## Proposed storage and persistence meter

This is an explicit layout target, not a compiler-layout measurement.

| Field | Packed layout | Newly occupied slots |
|---|---|---:|
| Reserves | `uint112 reserve0; uint112 reserve1; uint32 lastHeightLow` | 1 on first liquidity; 0 on ordinary updates |
| Supply | `uint128 totalShares; uint128 lockedShares` | 1 on first liquidity |
| Local brake metadata | `uint64 createdAt; uint64 latchedAt; uint8 reason` | 1 at deployment because `createdAt != 0` |
| LP claim | `mapping(address => uint128) shares` | 1 per newly nonzero LP; 0 for a still-nonzero LP |
| Pair, fee and bounds | Runtime immutables | Persisted code bytes, not free constants |
| Reentrancy guard | Set then cleared during the transaction | 0 final occupied slots; exec/prove gas still applies |

Use `H(E,O,L)=ceil((E+128+O+L)/32)`. Then `U=100*A+100*S+C+H` under [ES1](../SOURCES.md#es1). `E` is the **entire canonical signed envelope**, including account-batch calldata; `O=0` for these account entry points. `C` applies to deployment. All token holdings and allowances are counted outside this core.

Receipt fixture: ERC-20 `Transfer` or `Approval`, three topics plus 32 data bytes, costs 192 bytes each; account `Executed`, one topic plus 32 data bytes, costs 128 bytes. Proposed `Swap(owner indexed,in,out)` has two topics/64 data bytes = 192 bytes; `Share(owner indexed,a0,a1,shares)` has two topics/96 data bytes = 224 bytes. Topic counts include the event signature.

| Complete action | New occupied slots, excluding sender account | Receipt/envelope illustration | Estimated U |
|---|---|---|---:|
| Warm swap, exact approve/swap/reset | 0, with pool/input/output balances already nonzero | `H(768,0,2*192+2*192+192+128)` | 62 |
| Swap to zero output-token balance | Above + 1 ERC-20 balance slot | Same bytes | 162 |
| First liquidity after deployment | 2 global + 1 LP + 2 pool token-balance slots | `H(1024,0,4*192+2*192+224+128)` | 583 |
| New LP into funded pool | 1 LP; existing pool token balances | Same add bytes | 183 |
| Existing LP adds | 0 if LP shares stay nonzero | Same add bytes | 83 |
| Remove all shares to existing nonzero token holders | 0; later deletion refunds no burned state fee | `H(512,0,2*192+224+128)` | 43 |
| Permissionless brake latch | 0 because metadata slot is occupied | `H(384,0,160+128)` | 25 |

These chosen envelope lengths and event-emitting exact-transfer tokens are an **illustrative fixture**, not a transaction-size guarantee. Approval implementations can emit different logs; publish the actual bytes. Add 100 u if a previously absent sender account gets its first nonce; add 100 u for each recipient token balance that is zero in pre-state, even if that address held the token previously. Native recipients are absent from this two-ERC-20 fixture.

The allowance ends at zero in the same successful batch, so it creates zero *final* occupied slots. A separate approval transaction creates a persistent allowance and adds 100 u, plus its own envelope/receipt. A failed swap rolls the whole batch back; it still pays archive and execution/proving costs. Clearing old LP/holder slots produces no state-fee refund.

Deployment is `D=200+runtime_bytes+H(E_deploy,O_deploy,L_deploy)` here: one account, one metadata slot, plus all actual persisted code. Compiler/initcode and receipt bytes are pending measurement; initialization's other slots are separately charged in the first-liquidity row.

## Signatures and consumer flow

1. Wallet loads pair state and shows recipient, minimum received, LP fee, price impact and expiry; user selects “Exchange.”
2. One funded P-256 transaction signature authorizes `[approve(exact input), swap, approve(0)]` through `execute(Call[])`; one biometric prompt is the UI target, not a protocol fact about every device.
3. Wallet waits for finalized receipt and verifies amounts. A changed price beyond the cap reverts all calls; the user sees the cost of the failed attempt.

No ERC-1271 dependency exists for this self-authorized batch. A funded third party can relay a signature from an **already added owner** via `ownerExecute`; owner setup and relayer nonce/event costs must be added. Payment sessions cannot authorize this swap today. A sponsor contract cannot change the EVM transaction's fee payer. [ES2](../SOURCES.md#es2), [ES6](../SOURCES.md#es6).

The original v2 router can use the same approve/router/reset batch on EastSea. Compare core state, code and failure cost after granting both paths the same account benefit.

**What the user never needs to understand:** reserve packing, delegation, proving gas, allowance plumbing or receipt trees. They still see the receive/spend limit, expiry, liquidity-provider fee and possibility of failed exchange or LP loss.

## Failure, ordering and local brake

- A public swap remains reorderable before inclusion. One-second finality does not eliminate sandwiches, arbitrage or execution at the user's worst permitted price. Keep narrow caps and compare RFQ; do not label this pool MEV-proof. No timelock SDK or encrypted mempool is assumed. [ES4](../SOURCES.md#es4), [ES5](../SOURCES.md#es5).
- Pool contention serializes reserve changes; optimistic conflict repair can add proving/execution work even for disjoint users. [ES11](../SOURCES.md#es11).
- Every entry checks actual balances against recorded reserves. A deficit or inconsistent supply enables deterministic `pokeBrake()` to latch the first reason/time; the function returns successfully after recording it so a revert does not erase the brake.
- `brakeState()` returns entry-braked on a visible deficit even before anyone latches it; guardian is zero. After latching, no new LP deposit or swap is allowed and no caller can clear the latch.
- Remaining LPs can redeem pro rata against actual balances in the latched instance, with no privileged sweep. Recalculate against remaining supply at each exit. Frozen tokens can still block transfers; “exit callable” cannot create solvency or issuer cooperation.
- Donations benefit remaining LPs under this rule; there is no permissionless `skim` that gives unaccounted tokens to a racing caller.
- A malicious token issuer can freeze, tax or replace token behavior; a committee can censor; a relayer/frontend can refuse service. None has a pool withdrawal key. A stolen account key still controls its LP shares. [ES2](../SOURCES.md#es2).

Pair, arithmetic, fee, bounds, locked-share policy and brake are immutable. A new version means a new address and owner-authorized movement, not a platform upgrade.

## Quantitative benchmark and release gate

A full illustrative pool cohort—first LP adds, ten warm swaps, LP removes—costs `583+10*62+43=1,246 u`, plus `D`. It has twelve transactions and at least twelve account signatures across all actors. Zero output balances for all ten trades add 1,000 u; restoring both LP token balances after fully depositing them adds another 200 u. These are workload choices, not free “existing account” cases.

At 100% of shared B5 refill, the state-only upper bounds are `32/62=0.516 warm swaps/s` (44,593/day) or `2,764,800/1,246=2,218 full cohorts/day` before deployment amortization. The canonical-payload bound for 768-byte swap envelopes alone is `4096/768=5.33/s`; BAL/control traffic makes it lower. Take the minimum with execution/prove limits, conflicts, 512-new-slot and transaction caps. At 10% refill these bounds divide by ten. [ES1](../SOURCES.md#es1).

Floor state fees are 0.000062 DBLN/warm swap and 0.001246 DBLN/cohort; **total** fees also contain measured execution/proving dimensions and any relayer charge. LP fees compensate counterparties and are separately disclosed. `G_exec`, `G_prove`, code bytes and achieved throughput are **UNKNOWN—TO MEASURE**.

Benchmark gate: pin exact `Uniswap/v2-core` and `v2-periphery` commits, deployed bytecode/factory settings, compiler and licence; use v3 as the explicitly more-capital-efficient capability control, not a fabricated v2-only market. No pin or vendoring approval is inferred from a project name.

Required tests: fee-adjusted conservation; round-up/down boundaries; minimum LP and donation adversaries; deadline/recipient authorization; exact-transfer adapters; reentrancy; deficit latching and pro-rata exits; abandoned LPs; owner relay; zero-balance reoccupancy; and sequential/parallel root/receipt agreement. Run every success/revert path on B5 genesis, ≥100 latency samples and ≥10,000 finalized heights per sustained cohort as specified in [MEASUREMENTS.md](../MEASUREMENTS.md).

Publish original wins: concentrated capital efficiency, flash liquidity, portable LP claims, established integrations and measured maturity may outweigh this core's narrower state surface. Native superiority remains unproven.
