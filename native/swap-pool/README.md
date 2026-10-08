# C1 Swap pool: exchange now, at a price limit you chose

Status: **implementation, unaudited, not deployed, not measured on the EastSea executor.** The design is in [DESIGN.md](DESIGN.md). The rules from [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md) apply. This code is provided AS IS for testing and benchmarking, like the rest of this repository. Whoever deploys or uses it is responsible for doing so. No asset, liquidity, price or market on EastSea is implied: gate G8 (real exact assets and prices) is **not** established, and the C0 [token probes](../probes/README.md) have not been run against any real asset.

## The person's problem

Someone holding asset A wants asset B now, without finding a counterparty or handing custody to a venue. The wallet should say "spend 1 A, receive at least 1.99 B, valid for 60 s", and the chain should enforce exactly that. An AMM supplies an executable price from pooled inventory; it does not supply liquidity, a fair price or protection from reordering.

## What this contract does

`SwapPool` ([src](src/SwapPool.sol)) is one immutable constant-product pair: two exact-transfer ERC-20s and an LP fee fixed at deployment (0–100 bps). There is no owner, factory allowlist, protocol fee, proxy, hook, callback, flash swap, embedded price oracle, `skim` or rescue key. Anyone may deploy a pair; a different fee or token is a different address.

| Call | Who | Rule |
|---|---|---|
| `swapExactInput(tokenIn, amountIn, minOut, recipient, deadline)` | anyone | Pulls exactly `amountIn` (balance delta), output by floor division of the fee-adjusted curve, pushes to `recipient` with exact deltas. Reverts below `minOut`, after `deadline`, on zero output or above the `uint112` reserve bound. |
| `swapExactOutput(tokenIn, amountOut, maxIn, recipient, deadline)` | anyone | Input by ceiling division, reverts above `maxIn`; cannot take the whole reserve. |
| `quoteExactInput` / `quoteExactOutput` | view | Same arithmetic as execution, at current reserves. |
| `add(max0, max1, minShares, deadline)` | anyone | First call fixes the ratio (not a certified price), mints `sqrt(x*y)` and locks `MIN_LOCKED_SHARES = 1000` inside `totalShares`. Later calls take the proportional part of `(max0, max1)`, rounded **up** in the pool's favour, and leave the rest with the caller. |
| `remove(shares, min0, min1, recipient, deadline)` | the LP's own account | Pro rata of the pool's **actual** balances to any receiver it names. Never checks the brake. `min0/min1` bound what actually left the pool. |
| `tripBrake()` | anyone, only while the predicate holds | Permanently closes `add` and both swaps. |

LP shares are a nontransferable `shares[owner]` mapping. A stolen account key controls its shares; a portable LP token is a separately priced future feature.

**No oracle dependency.** Neither swap reads any feed. The only "price" the pool knows is its reserves; the wallet shows the quote and the person signs the limit.

**Donations and rebases.** Before pricing or minting, every entry folds any surplus balance into reserves, so it belongs to the current LPs and a later joiner cannot capture it. There is no `skim` for a racing caller.

## Brake and exits

`brakeState()` returns `(state, guardian = 0, sinceHeight)`. Predicate bits: `1` a token's code hash changed, `2` a token balance is below its recorded reserve (issuer seizure, negative rebase), `8` shares and reserves disagree. While any bit holds, or once latched, `add` and both swaps revert. `tripBrake()` latches permanently and only while the predicate holds; recapitalising does not reopen entry. Details: [SECURITY.md#brake](SECURITY.md#brake).

`remove` stays callable in every brake state. It first latches a live predicate itself (so syncing the books to actual balances cannot erase the evidence), then pays each LP its share of what is actually there and recalculates against the remaining supply at each exit. The exit leg requires the token call to succeed but not exact transfer, so a token that later starts charging a fee, or rounds like a rebasing token, still lets LPs out. A paused or blocklisting issuer can still block an exit to a given receiver ("exit callable" cannot create issuer cooperation); the LP can name another receiver.

## Wallet flow (P-256 account, existing A1 batch)

One account transaction signature authorises `[approve(pool, exact input), swapExactInput(..., minOut, me, deadline), approve(pool, 0)]` through `execute(Call[])`. A moved price or a passed deadline rolls the whole batch back, including the approval, and the person sees the failed attempt's cost. No ERC-1271, session, typed signature or sponsor is involved. A bounded two-hop route A → B → C is six calls with an explicit bound on every leg; any B above the hop-2 input stays in the wallet, visible. Route search is off-chain; the chain only enforces bounds. Tests: [AccountBatch.t.sol](test/AccountBatch.t.sol) uses a **test-only mirror** of `EastSeaAccount.execute` (same `Call` struct, self-only rule and `CallFailed` revert), not the deployed delegated runtime.

What the person never needs to learn: reserve packing, allowance plumbing, delegation. What the wallet must still show: receive-at-least / spend-at-most, recipient, expiry, LP fee, price impact, and that a public swap can be reordered before inclusion.

## Deviations from DESIGN.md (all deliberate)

- The latch call is the shared `tripBrake()` from `common/` rather than a separate `pokeBrake()`; `remove` also latches a live predicate itself.
- Exits pay pro rata of **actual balances** (donations included, deficits shared) and re-sync the books; the design's "redeem pro rata against actual balances in the latched instance" applies in every state.
- The exit leg checks the pool's own debit, not exact delivery, to keep exits open for tokens that turn inexact after deployment.
- `Swap(sender indexed, int256 delta0, int256 delta1)` carries direction in the signed pool-side deltas (two topics, 64 data bytes, as the design budgets). Liquidity uses `Added`/`Removed` (two topics, 96 data bytes each) instead of one `Share` event.
- Predicate bit `8` (supply inconsistency) is pool-specific; bit `4` keeps its common meaning and is unused.

## Head-to-head plan vs Uniswap V2 (to run with the executor recorder)

Controls: `Uniswap/v2-core` and `v2-periphery` at a **pinned commit and licence check** (not vendored or pinned in this revision), deployed unchanged on the same B5 benchmark genesis, with the **same P-256 batch wallet** (`approve → router swap → approve(0)`). The batch is an account benefit and counts in both columns. `contracts/src/amm` in this repository is a V2-style published example, useful as a smoke control but **not** a substitute for the pinned original. V3 is the capital-efficiency control, compared on the same price path and LP budget, not folded into the V2 table.

| # | Scenario | Record for both |
|---|---|---|
| H1 | Deploy pair (native: one contract; V2: factory + createPair) | runtime/initcode bytes, deployment u, prove gas |
| H2 | First liquidity | new slots (native checked: 3 in pool), u, envelope/receipt bytes |
| H3 | New LP / existing LP add | native: 1 / 0 new pool slots; V2: LP token balance + allowance slots |
| H4 | Warm exact-input swap, 3-call batch | exec/prove gas, U (design estimate 62 u), events |
| H5 | Swap to a zero output balance | +100 u per fresh holder, both |
| H6 | Exact-output swap | input rounding, U |
| H7 | Full exit, LP removes all | cleared slots (no refund), U |
| H8 | Price moved past cap / expired | failed-attempt cost (archive + exec), rollback |
| H9 | Two-hop route vs V2 router multi-hop | calls, U, bound semantics |
| H10 | Donation; negative rebase / seizure | native: absorbed / brake + pro-rata exits; V2: `sync`/`skim` race |
| H11 | 1,000 swaps contending on one pool, sequential vs parallel executor | conflict re-executions, roots/receipts agree |
| H12 | Public-inclusion sandwich at 10/50/100 bps tolerance | victim shortfall, attacker profit; same for both (no MEV protection claimed) |
| H13 | Sustained cohort ≥ 10,000 heights at 10/50/100% of shared refill | completed swaps/day, binding limit |

**Where V2 still wins:** flash swaps; a transferable ERC-20 LP token that composes with other protocols; the TWAP accumulator that other contracts read (this pool has no oracle by design, so it cannot serve one); a canonical factory address, so integrators and routers find pairs without a registry; years of production use, audits and integrations. **Where V3/V4 win:** concentrated liquidity gives much better depth per unit of capital and lower slippage for the same LP budget; multiple fee tiers; V4 hooks and singleton accounting. **Where StableSwap wins:** pegged-asset pairs. **Ties:** the account batch, exact approval reset and failed-attempt rollback are equally available to the V2 router on EastSea. **Possibly better here (unmeasured):** fewer persistent fields and no LP-token allowance state; no owner-switchable protocol fee; explicit deficit brake with exits that stay open. None of this creates liquidity or users.

## Files

- `src/SwapPool.sol`
- `test/`: unit (`SwapPool.t.sol`), fuzz (`SwapPoolFuzz.t.sol`), invariants (`SwapPoolInvariant.t.sol`), wallet batch (`AccountBatch.t.sol`), C0 economic simulation (`sim/PoolSimulation.t.sol` with the **test-only** `sim/MockReferencePrice.sol`).
- [SECURITY.md](SECURITY.md), [GAS.md](GAS.md). C0 probes: [../probes](../probes/README.md).

```bash
cd native && forge test --match-path 'swap-pool/*'
cd native && forge test --match-path 'swap-pool/test/sim/*' -vv   # prints the simulation numbers
```

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps -->

Testnet permits shared demonstrations with test coins. Mainnet permits only
your own private, allowlisted, capped instance: deploy from your EIP-1193
wallet through `PersonalTestDeployer`, whose constructor fixes your native
and aggregate token caps. Its `deploy(bytes,bytes32)` atomically initializes
this contract's existing constructor ABI and marks it `personal-test`.
Only the deploying wallet starts allowed. Add only other accounts you own,
and use those accounts for every party, beneficiary, signer and recipient.
Personal mode charges no protocol fee and adds no administrative withdrawal.

The 17-app publisher does not invent a deployment recipe or shared frontend
for this native example. Use the
[generic native deployment interface](../../docs/personal-mainnet-testing.md#native-contracts)
with its locally built creation bytecode, own test assets, fixed caps and
wallet-approved calls. Run `cd native && forge test` locally before doing so.
Do not deploy from a company key or host a shared mainnet interface. Caps
are raw asset base units, not a dollar valuation; unsolicited external
transfers cannot be prevented at the receiving contract. The [policy](../../docs/personal-mainnet-testing.md)
describes exits and those limits. Stable [English translation keys](../../docs/i18n/personal-test.en.json)
are ready for the language pack.
