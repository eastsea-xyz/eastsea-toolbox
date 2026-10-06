# Keep a useful spending unit without pretending collateral creates a dollar peg

Status: experimental design, 2026-10-06; lane C; collateral debt-unit research P2, production USD stability P3/**GATED**.
Inherits [verified primitives](../PRIMITIVES.md), [measurements](../MEASUREMENTS.md), and [problem catalog](../PROBLEMS.md).

## Problem before mechanism

A consumer wants wages, prices, savings and repayments to remain understandable while a volatile token changes value. A collateral-debt system creates a spendable unit without first selling collateral, but minting permission is not the same as predictable purchasing power. Sky's Dai documentation describes the external token as the user-facing counterpart of its internal debt unit; its wider system also includes collateral liquidation and peg-stability infrastructure. [Dai documentation](https://developers.skyeco.com/protocol/tokens/dai/), [Sky collateral liquidation](https://developers.skyeco.com/protocol/vaults/collateral-liquidation/), [LitePSM](https://developers.skyeco.com/protocol/liquidity/litepsm/), accessed 2026-10-06.

**Best consumer layer today: wallet asset selection and honest issuer/bridge disclosure.** If a credible redeemable stable asset becomes available, show balances/payments in that asset. This document instead specifies a bounded experiment in collateralized debt issuance. It must not be called an EastSea dollar, savings guarantee or delivered peg.

## Why copying a CDP is insufficient

Sky's core uses collateral types, normalized debt, safety prices and ceilings, with authorized modules that can modify accounting. Liquidation documentation includes governance parameters, circuit breakers and front-running risks. Those powers and modules answer an evolving collateral/risk problem; deleting them also deletes ways to adapt. [Vat core accounting](https://developers.skyeco.com/protocol/core/vat/), [collateral liquidation documentation](https://developers.skyeco.com/protocol/vaults/collateral-liquidation/).

EastSea removes neither market-data trust nor external redemption/bridge risk. The current primitives establish no USD collateral, no issuer commitment to redeem at $1, no bridge-backed stable market and no liquidator inventory. A BLS beacon authenticates a draw message; it supplies no USD price. [ES4](../SOURCES.md#es4).

The native experiment combines a single collateral engine and debt-unit ERC-20 in one immutable instance, with owner-called batched actions and no governance mint/fee/upgrade key. Fewer components and live slots are testable advantages; stability and economic safety are unproven. A useful standalone peg may be **not achievable** under the presently available economic inputs.

## Experimental issuance rules

- Anyone deploys a named `DebtUnit` instance with one exact-transfer collateral C, immutable C/reference-unit feed policy, decimal conversion, collateral ratio, liquidation ratio/bonus, debt ceiling and minimum debt.
- The reference unit is explicitly declared. A USD-named policy needs an actual C/USD feed and market; no source type is selected by this design. A C/L rate produces debt denominated in L, not automatically dollars.
- `open(collateralIn,mintUnits,minRemainingRatio)` pulls C and mints to the owner's address, only with fresh valid feed data and sufficient coverage under the ceiling.
- `repayAndWithdraw(burnUnits,collateralOut)` burns only the caller's units and updates their position. Full repayment exits without an oracle; partial debt plus withdrawal needs fresh valuation.
- This first experiment charges zero interest, zero origination fee and zero operator spread. There is no reward/savings yield. These choices simplify supply conservation; they do not solve demand or price stability.
- The ERC-20 has ordinary transfer/approve; burns occur **only through repayment or liquidation that simultaneously updates debt accounting**. There is no standalone `ERC20Burnable`-style holder burn that could break `totalSupply == liveDebt + badDebt`. No unlimited mint role, issuer freeze, admin confiscation, proxy, interest-fee recipient or changeable collateral list exists inside this instance.
- Anyone can liquidate unhealthy collateral by burning their own debt units for collateral under the immutable ratio/bonus, with a caller-set minimum collateral received.
- Paying a merchant transfers ownership of units; it does not give the merchant a right to seize another person's CDP or redeem one unit for $1.
- There is no holder-at-par redemption, peg-stability module, sorted redemption queue, backstop treasury or recapitalization token in this core. Those would be separate economic designs, not hidden assumptions.

When collateral is exhausted, remaining position debt becomes explicit `badDebt`; its already issued tokens remain outstanding. Latch new minting shut. Token holders may suffer impaired backing and a discount; no founder can mint rescue collateral, socialize an undisclosed levy or promise full redemption.

`totalSupply == liveDebt + badDebt` is the proposed zero-interest invariant. Burning for voluntary full repayment or liquidation reduces supply and live debt together. Bad-debt classification changes live debt into bad debt without burning anyone else's holdings. No fee collector or reserve liability is omitted.

## Proposed storage and occupation

| Field | Packed target | New occupation |
|---|---|---:|
| Collateral/live debt totals | `uint128 totalCollateral; uint128 liveDebt` | 1 on first mint |
| Unit supply/loss | `uint128 totalSupply; uint128 badDebt` | 1 on first mint; later bad debt shares this slot |
| Deterministic brake metadata | `uint64 createdAt; uint64 latchedAt; uint8 reason` | 1 at deployment |
| Owner CDP | `uint128 collateral; uint128 debt` | 1 per newly nonzero position |
| Unit holder | `mapping(address=>uint128) balance` | 1 per zero-to-nonzero holder balance |
| Unit allowance | `mapping(address=>mapping(address=>uint128)) allowance` | 1 when persistent nonzero allowance is first created |
| Names/policy/ratios | Runtime immutables, short fixed metadata | All persisted code bytes |

Collateral balance and allowance slots belong to C's contract and are additional. Internal unit balances and allowances above are **already counted**; do not charge them a second time as an external debt token. No permit nonce is introduced; P-256 self batches use ordinary approval. Reentrancy flags set/cleared within a transaction have no final occupied-slot cost.

Clearing positions/balances later refunds no burned state fee. Reoccupied balances/positions cost again. A abandoned CDP cannot disappear from consensus just because its receipt archive disappears; a debt-unit holder's live claim is not a Merkle-log entitlement. [ES1](../SOURCES.md#es1), [ES7](../SOURCES.md#es7).

## Action and receipt ledger

`H(E,O,L)=ceil((E+128+O+L)/32)`; `U=100*A+100*S+C+H`. Illustrative account entry points have `O=0`. Transfer/Approval = 192 B; account `Executed` = 128 B. `CDP(owner indexed,collateral,debt,action)` has two topics/96 data bytes = 224 B.

| Action in initialized instance | Newly occupied core/external slots | Envelope + logs | U |
|---|---:|---|---:|
| First CDP and first unit holding for this owner | 1 position + 1 unit balance | `H(1024,0,2*192+2*192+224+128)` | 271 |
| First CDP for existing nonzero unit holder | 1 position | Same | 171 |
| Existing live CDP increases, unit balance nonzero | 0 | Same | 71 |
| Burn all + return C, recipient C balance already nonzero | 0 | `H(512,0,2*192+224+128)` | 43 |
| Pay existing nonzero unit holder | 0 | `H(384,0,192+128)` | 26 |
| Pay zero unit holder | 1 unit balance | Same | 126 |
| Liquidate with own units, recipient C balance nonzero | 0 | `H(512,0,2*192+224+128)` | 43 |
| First brake latch | 0, metadata already occupied | `H(384,0,160+128)` | 25 |

These are full-envelope/event fixture lengths, not measured serialization. The opening row includes exact C approval/reset, collateral Transfer and unit mint Transfer. Owner repayment burns directly and needs **no unit allowance**; its row includes unit burn and collateral Transfer. If token implementation emits additional logs, charge them.

Whenever minting encounters zero pre-state totals, it additionally occupies both totals slots (+200 u) and C's balance for this instance if zero (+100 u). This includes first-ever mint **and reopening after a previous fully repaid/emptied pool**. Warm fixtures retain other active debt/collateral so these words stay occupied. Deployment is `D=200+runtime_bytes+H(E_deploy,O_deploy,L_deploy)` for account and metadata, plus actual initcode/receipt. Sender nonce accounts and newly restored C balances add 100 u each. Actual code, `G_exec`, `G_prove` and achieved throughput are **UNKNOWN—TO MEASURE**.

## Consumer signatures and accounting

Opening needs one P-256 transaction signature for `[approve(C), open, approve(C,0)]`. Paying requires one transfer transaction signature; close one owner-called burn/withdraw signature. There is no generic debt-unit session integration until its ERC-20 address is explicitly provisioned under the current payment-session limits. No session can open or liquidate CDPs today. [ES2](../SOURCES.md#es2).

Existing added-owner signatures can be relayed with `ownerExecute`; count setup, owner nonce/event and relayer fees. Current ordinary execution cannot select a sponsor fee payer. A compatible CDP original gets the same atomic EastSea batch control. [ES6](../SOURCES.md#es6).

**What the user never needs to understand:** internal debt units, approval calls, accounting widths or proofs. They must see “experimental collateral debt unit,” current market exchange value, **no promised $1 redemption**, liquidation threshold, impaired-backing status and the cost to reacquire units for repayment.

## MEV, brakes and who can cause losses

Public mint/withdraw/liquidation transactions expose price-update and ordering races. Timelock encryption is not present price privacy, and one-second finality does not stabilize collateral or unit demand. [ES4](../SOURCES.md#es4), [ES5](../SOURCES.md#es5).

Stale/invalid feed observations deterministically brake new minting and collateral removal with remaining debt; the reported `since` is the feed's validity boundary, guardian zero. Full repayment, adding collateral and unit transfers remain callable. Price-based liquidations require fresh valid data, so an outage can worsen backing.

`badDebt>0`, a C balance deficit or upstream feed trust latch permanently brakes issuance through permissionless `pokeBrake()`. Entry checks the live predicate before a latch. Latching records success without reverting it; no admin clear function exists. CDP repayment/valid liquidation remains callable, but every collateral payout must keep actual post-transfer C balance at least the remaining recorded totalCollateral. A shortfall therefore prevents ordinary payouts until backing is restored; no first-exit priority or unstated haircut transfers another CDP's collateral. Repayment plus failed exit rolls back atomically, and frozen collateral can prevent withdrawal even when backing is adequate.

Feed signers can invent valuation or withhold reports; C issuers/bridges can freeze or fail; liquidators can disappear; committees can censor; markets can price units below or above their reference. Owner keys can authorize losing transactions. The immutable contract has no custody bypass, but cannot repay a token holder with nonexistent collateral or external dollars.

All issuance/burn/transfer rules, ceilings, collateral/feed and brake policy are immutable. Migrating collateral needs the owner's authority and a new deployment. Wallet metadata cannot silently change a debt unit into a dollar promise.

## Whole workflow, not just cheap minting

A new CDP/unit-holder open→repay/exit lifecycle is `271+43=314 u` before token reoccupancy, feed/deployment and market bootstrap. If all C was initially deposited, exit adds 100 u: 414 u. This task only returns units already retained; it does not demonstrate a spending ecosystem.

A spending cohort is open→pay a new merchant→reacquire units by direct RFQ→repay/exit. Using the exchange's 72 u existing-maker-bitmap fixture, a now-zero owner unit balance makes reacquisition 172 u; a now-zero C balance makes exit 143 u. Total `271+126+172+143=712 u`, plus maker window/setup share, feed, first-market totals and code. RFQ is **1271 + inventory GATED**; include actual exchange spread/solver compensation separately. No model assumes merchants give units back at par.

At 100% B5 refill, state-only upper bounds are `2,764,800/314=8,805 simple lifecycles/day` or `2,764,800/712=3,883 spending cohorts/day`; at 10%, divide by ten. The latter upper bound says nothing about peg quality. Payload, proving/execution, conflicting totals, issuer transfer behavior and actual market depth can bind first. [ES1](../SOURCES.md#es1).

Floor state-only fee is 0.000314 DBLN/simple lifecycle and 0.000712 DBLN/spending cohort. Add exec/prove fees, relayer charges and spreads. Collateral lockup, liquidation loss and unit-price risk matter far more than proving a cheaper mint call.

Pin gate: choose exact Maker/Sky Vat, Join, Dai, liquidation and peg-support deployments/commits and licence; label the economic support retained in each control. Compare a restricted single-collateral/zero-interest task fairly, then publish the unsupported stability/redemption and governance capabilities. A production original with peg infrastructure is not comparable to a mock unit trading at hard-coded $1.

Tests/benchmarks: issuance/burn conservation; bad-debt invariant; decimal/rounding caps; wrong-feed denomination; extreme price moves; no-feed repayment; token freeze; collateral exhaustion; refusal/ordering of liquidation; minimum economic debt; abandoned CDPs; restored holder slots; concurrent mint/payment/liquidation; and the full spending cohort through [MEASUREMENTS.md](../MEASUREMENTS.md). Peg tests must measure observable exchange price/depth and redemption, not arithmetic coverage alone.

Production gate remains closed until collateral, licensed/authenticated price sources, external redemption/bridge commitments where claimed, liquidator inventory and sustained demand are evidenced. Original wins include actual dollar redemption or mature peg-support markets, adaptive collateral management and established liquidity. This experiment may lose the user's central stable-value task despite having cleaner contracts.
