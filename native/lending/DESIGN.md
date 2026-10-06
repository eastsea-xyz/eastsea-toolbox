# Obtain liquidity without selling the asset you want to keep

Status: design proposal, 2026-10-06; isolated contract + wallet; lane C, priority P2; economic deployment gated on oracle and liquidation liquidity.
Inherits [verified primitives](../PRIMITIVES.md), [measurements](../MEASUREMENTS.md), and [problem catalog](../PROBLEMS.md).

## Problem before mechanism

An asset holder needs working capital while keeping exposure to an asset they would otherwise sell; a saver wants compensation for supplying that capital. Aave names unexpected expenses, investment and leverage as borrowing uses and describes this liquidity-without-sale motivation. The consumer task is “borrow L against C, understand the repayment and loss boundary,” not “receive a debt token.” [Aave FAQ, accessed 2026-10-06](https://aave.com/faq).

The person still needs actual L inventory and a way to liquidate C. Fast blocks, passkeys and small contracts do not create either market.

## What survives from originals, and what changes

Aave V3 provides broad asset support and governance/risk administration, including reserve pause and adjustable risk controls. Its documentation describes oracle failure, collateral liquidity and withdrawal-cash risks. These are real limits, not a claim that an administrator can arbitrarily withdraw a user's position. [Aave V3 configurator](https://aave.com/docs/aave-v3/smart-contracts/pool-configurator), [Aave FAQ](https://aave.com/faq).

Morpho Blue is a closer structural control: isolated immutable markets, supply/borrow shares and liquidity-limited exits. Its architecture must receive the same EastSea batching benefit. The native idea is not to claim invention of isolation. [Morpho Blue concepts, accessed 2026-10-06](https://docs.morpho.org/learn/concepts/blue/).

Morpho governance retains fee-switch and enabled LLTV/IRM powers. Here each instance fixes its own curve and risk policy with no shared market allowlist or fee recipient. That removes those powers but loses adaptive risk management; it does not establish superior solvency. [Morpho governance documentation](https://docs.morpho.org/learn/governance/organization/).

## Native market

- Anyone deploys one immutable `loanToken L != collateralToken C`, feed policy, maximum age, borrow LLTV, liquidation LLTV, liquidation incentive, borrow ceiling, minimum debt and utilization curve.
- Loan liquidity comes only from actual lender transfers. No validator reward, native staking return, reserve bailout or bridge is assumed. The loan asset is not automatically USD-stable.
- Suppliers receive internal nontransferable shares; borrowers keep one collateral/debt-share position. A later ERC-4626 wrapper is separately specified and charged.
- `supply(amount,minShares)` creates shares using virtual-share/assets constants fixed in code; `withdraw(shares,minAssets,recipient)` requires actual cash. Nontransferability narrows composition and is a disclosed tradeoff.
- `open(collateralIn,borrowOut,maxDebtAfter)` combines collateral deposit and borrowing. The caller is the position owner; no arbitrary “on behalf of” debt creation exists.
- `repayAndWithdraw(maxRepay,collateralOut,minRemainingHealth)` accrues first, rounds debt repayment up, pulls no more than the signed cap, and releases collateral only if remaining debt passes the current fresh-price check.
- Full repayment permits collateral exit without a price feed. Adding collateral and debt repayment stay available through a stale-feed brake; they cannot bypass token failures.
- Interest accrues lazily from an immutable bounded piecewise utilization curve. `lastAccrual` is a Unix-second timestamp: use `block.timestamp` elapsed seconds and an explicit 31,536,000-second annualization convention, never an Ethereum blocks-per-year constant. Equal timestamps accrue zero; long gaps, compounding and rounding are checked against a reference model. Accrued interest increases loan debt and supplier assets equally; all paid interest belongs to lenders, with no protocol spread.
- Checked 128-bit aggregates impose hard market capacity. Overflow causes rejection, never wraparound or silently truncated obligations. The exact rounding/virtual constants need a conservation proof before code is funded.

Risk gate: borrow only with positive, properly denominated fresh feed observations, no feed brake, `borrowAssets <= ceiling`, and post-borrow utilization at most the instance's immutable cap (illustrative 90%). A cash buffer is an entry rule, not a guarantee that all suppliers can exit together.

Price is C in units of L, including token decimal normalization. A USD feed cannot be treated as C/L without a defined conversion. The [oracle design](../oracle/DESIGN.md) authenticates chosen reporters, not objective truth; no deployed EastSea feed is established by this document.

## Liquidation and bad debt

Anyone may repay an unhealthy position and receive collateral under the fixed incentive, with repay/seize caps and a caller-signed minimum. No callback or flash loan is supplied by this core. Wallets/keepers may compose independently funded account batches; availability is a market prerequisite.

Collateral exhaustion closes remaining borrower debt into an explicit lender loss: decrement total borrow assets/shares and supplier assets by the deficit; do not leave suppliers with an uncollectible asset claim at par. Zero supplier assets with outstanding supply shares latches entry shut. Losses are pro rata; no treasury, admin or token holder silently receives a repayment priority.

Stale data prevents price-based liquidation too. Leaving it callable with an invented price would be worse than exposing the outage. This may allow debt to become bad while the feed is unavailable; repayment remains possible. The release gate measures liquidator profitability after network and state costs at minimum debt, extreme volatility and thin collateral depth.

## Proposed storage and new occupied state

| Field | Packed target | Occupation rule |
|---|---|---|
| Supply totals | `uint128 supplyAssets; uint128 supplyShares` | 1 slot on first lender funding |
| Debt totals | `uint128 borrowAssets; uint128 borrowShares` | 1 slot on first borrow after an empty debt pool |
| Collateral/brake/accrual | `uint128 totalCollateral; uint64 lastAccrual; uint56 latchedAt; uint8 reason` | 1 slot at deployment via nonzero `lastAccrual` |
| Supplier right | `mapping(address=>uint128) supplySharesOf` | 1 newly nonzero slot per supplier |
| Borrower right | `mapping(address=>Position)` with `uint128 collateral; uint128 debtShares` | 1 newly nonzero slot per borrower |
| Tokens, feed, thresholds, curve | Runtime immutables | Actual persisted code bytes |
| Reentrancy guard | Set/clear within each transaction | 0 final new slots; gas still applies |

Shared suppliers and borrowers are independent maps: an address doing both occupies two slots. Packed nonzero collateral means its first debt-share update creates no extra borrower slot. Clearing then reopening a position in a later transaction pays 100 u again; deletion never refunds burned state fees. Feed state, token balance and allowance slots remain additional. [ES1](../SOURCES.md#es1).

`cash = supplyAssets - borrowAssets`; check actual loan-token balance is at least cash and actual collateral-token balance at least total collateral. Every payout must preserve those inequalities **after** its recorded liabilities and exact transferred amount change. A balance shortfall does not grant the first exiting supplier/borrower priority over the others; this design has no implicit haircut policy. Voluntary recapitalization may restore backing. Donations are surplus, not silently credited supplier shares or an oracle. State tracks obligations, not off-chain receipt reconstruction. Receipt history can aid the wallet but cannot replace position rights. [ES7](../SOURCES.md#es7).

## Quantitative action ledger

Let `H(E,O,L)=ceil((E+128+O+L)/32)`; `U=100*A+100*S+C+H`, with top-level `O=0` in this batch fixture. Transfer/Approval events are 192 B; account `Executed` 128 B. `Position(owner indexed,collateral,debtShares,action)` is two topics/96 data bytes = 224 B. All values are layout/envelope estimates, not measurements.

| Action, already initialized market | New slots in core | Envelope + priced logs | U before external freshness |
|---|---:|---|---:|
| New borrower, collateral deposit + borrow + reset allowance | 1 | `H(1024,0,2*192+2*192+224+128)` | 171 |
| Existing nonzero borrower increases | 0 | Same | 71 |
| Repay all + withdraw + reset loan allowance | 0 | Same; both token legs included | 71 |
| New supplier, exact approve/supply/reset | 1 | `H(768,0,2*192+192+224+128)` | 157 |
| Supplier withdraws all | 0 | `H(512,0,192+224+128)` | 37 |
| Funded liquidator, repay/seize/reset | 0 unless new totals reoccupy | `H(1024,0,2*192+2*192+224+128)` | 71 |
| First structural brake latch | 0, metadata already occupied | `H(384,0,160+128)` | 25 |

Add 100 u per zero-to-nonzero external holder balance, persisted allowance or first sender nonce account. Exact approval/reset in one successful batch has zero final allowance slots. Supply adds 100 u whenever supply totals reoccupy a zero pre-state word, and 100 u if market L balance was zero; borrow likewise adds 100 u whenever debt totals reoccupy zero, and possibly 100 u for a zero market C balance. These apply both at bootstrap **and after the previous pool/positions emptied**; deployment or prior use does not waive reoccupation.

If a borrower deposits their entire C holding, its external balance becomes zero. Receiving C on later exit costs 100 u even though the account is old. A first-time L holder pays another 100 u when borrowing. A lender who supplies their entire L holding pays 100 u when withdrawing into that zero balance. Token metadata/code are outside these action rows.

Deployment is `D=200+runtime_bytes+H(E_deploy,O_deploy,L_deploy)` for one account and the preoccupied accrual slot. Runtime/initcode and execution/proving gas are **UNKNOWN—TO MEASURE**. A rollback preserves no app slots but still pays the actual envelope/receipt and execution/proving dimensions.

## User sequence and trust

Open: one P-256 transaction signature for exact C approval, `open`, approval reset. Close: one for exact L approval, repayment/collateral exit, reset. Supplier entry/exit similarly each need one transaction signature. Atomic account batching applies equally to compatible Aave/Morpho controls; current payment sessions do not authorize these calls. ERC-1271 is not needed for owner-called positions. [ES2](../SOURCES.md#es2).

An already added owner can sign `ownerExecute` for a funded relayer; added-owner setup, owner nonce occupation and relayer event/envelope changes are separate. No native sponsor fee-payer field is implemented. [ES6](../SOURCES.md#es6).

**What the user never needs to understand:** approval plumbing, debt shares, virtual offsets or proving. They still see borrowed asset, rate curve/current rate, accrued repayment, collateral loss threshold, feed/source trust, available withdrawal cash and loss-sharing rule.

Report who can stop/censor/steal: a feed quorum can lie or stop, causing incorrect liquidation or a freeze of risk actions; issuers/bridges can freeze or impair assets; liquidators can disappear; committees can censor; owners can authorize bad trades. No market administrator changes risk or withdraws assets, but no administrator can rescue a bad immutable policy either.

## Local deterministic brake and MEV

`brakeState()` reports stale-feed entry brake since the observation's valid-until boundary, guardian zero; fresh accepted data can resolve that **non-latched predicate**. Borrow/remove-collateral actions check this predicate themselves. New supplier exposure is rejected while feed validity is unavailable; repayment and full-debt collateral exit remain possible.

Actual-token deficits, exhausted supplier assets with live shares or a latched upstream feed trust failure are structural predicates. `pokeBrake()` writes the first reason/time without reverting; risk entries check the predicate even before a poke. A structural latch is monotonic, with no clear/admin function. Withdrawals require available cash; repayment is open; frozen tokens or insolvency may still prevent exit.

Liquidations remain a public competition with ordering and price-update exposure. Finality does not prevent a stale observation or same-block racing. No random winner, secret liquidation auction, dense CLOB or general historical-receipt verifier is assumed. Conservative caps can reduce exposure while rejecting otherwise useful borrowing.

## Lifecycle benchmark and gates

A warm-holder borrower lifecycle is `171+71=242 u`; cold L issuance plus full-C restoration gives 442 u. An already initialized market's new-supplier supply/withdraw lifecycle is `157+37=194 u`. These fixtures require **nonzero pre-state supply totals, debt totals and market token holdings**, with other active participants preserving them between lifecycles. A thin market emptied between each borrower needs repeated +100 u debt-total occupation and any emptied holding/supply-total charges. The **combined lender + borrower** task costs `194+242=436 u` under that declared warm-market condition, plus oracle reports, reoccupation/bootstrap/deployment share, failed liquidations and idle abandoned positions.

At full shared refill, state-only upper bounds are `32/242=0.132 borrower lifecycles/s` (11,424/day), or `2,764,800/436=6,341 combined lifecycles/day`. A cold borrower-only cohort is at most 6,255/day. At 10% refill, divide by ten. Include encoded-payload, cash availability, conflict repair, execution/prove and transaction limits before reporting achieved throughput. One fresh 47 u oracle report per combined task makes it 483 u, at most 5,724/day. [ES1](../SOURCES.md#es1).

Floor state-only fees: 0.000242 DBLN/warm borrower lifecycle and 0.000436 DBLN/combined lifecycle. Interest is lender compensation, not a platform toll. Total fees include measured exec/prove gas and explicitly quoted relayer costs; no USD saving is asserted.

Version-pin gate: select Aave V3 pool/configuration bytecode and exact repository commit, plus Morpho Blue market/IRM/oracle and exact commit; record licence, compiler and deployed settings. Equalize C/L, price path, LLTV, rate and liquidity; score broad multi-asset/rebalancing features separately. Follow [MEASUREMENTS.md](../MEASUREMENTS.md), including sustained B5 genesis and consumer-Mac conflict/prove measurements.

Tests: asset/share conservation and rounding; zero supply/debt; virtual offsets and donations; debt cap/utilization; stale/negative/misdenominated prices; collateral crash and lender loss; minimum economically liquidatable debt; exact transfer and issuer freezes; no borrowed-on-behalf authority; complete vs partial repayment; brake transitions; no unbounded loops; fresh holder/position recreation; funded owner relay; and sequential/parallel roots. Launch needs real feed availability, liquidator depth and tested bad-debt outcomes; none is delivered by this design.

Original wins to publish: Aave's adaptive governance/risk services and breadth, Morpho's mature isolated implementation, liquidity, integrations and audit record may dominate a smaller native layout. Immutability is a trust choice with operational costs, not automatic safety.
