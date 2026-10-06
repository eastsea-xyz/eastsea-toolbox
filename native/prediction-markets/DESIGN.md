# Prediction markets: buy a bounded claim on an explicit question

Status: design, 2026-10-06; **Lane B, P3, optional**. **A real-world truth/arbitration source is not supplied by EastSea.** ERC-1155 receiver hooks are pending; signed trading also depends on pending ERC-1271. Inherits [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md).

## The user's problem

A person wants to express a forecast or hedge a specific outcome with a known maximum loss, rather than accept an informal bookmaker's promise. Tradable conditional claims let counterparties take opposite views while collateral is held for settlement. Gnosis Conditional Tokens provides collateral splitting, merging and oracle-set payout vectors; its positions are ERC-1155 tokens. The need is a credible claim and clear resolution, not a particular collection-ID algorithm. [Gnosis Conditional Tokens developer guide, accessed 2026-10-06](https://conditional-tokens.readthedocs.io/en/latest/developer-guide.html).

Best layer: **contract for collateral/position conservation; chosen resolver for external truth; wallet for question, loss cap and settlement explanation**. There is no chain-native answer to elections, weather, litigation or ambiguous language. A BLS seed answers a randomness question, not a real-world question. [ES4, ES5](../SOURCES.md#es5)

## Where the original remains strong

CTF supports arbitrary partitions and nested conditions; its oracle calls `reportPayouts`, after which holders redeem according to that vector. That composability is valuable. This native instance intentionally restricts itself to one binary question, two top-level positions and three final results: Yes, No or Void. Smaller scope must be disclosed in every comparison. [Gnosis CTF splitting and payout specification](https://conditional-tokens.readthedocs.io/en/latest/developer-guide.html).

Polymarket documentation describes binary Yes/No positions and different current position ledgers; integrations must select the exact CTF version/pin, rather than assuming every current market uses the old ledger. Its deployed venue also has resolution/trading integration that EastSea lacks. No unverified volume or user count is asserted here. [Polymarket position systems, accessed 2026-10-06](https://docs.polymarket.com/trading/positions/how-positions-work).

One-second finality does not fix ambiguous questions, dishonest reports, resolver censorship, token issuer freezes or insider information. The native improvement hypothesis is bounded state and an understandable immutable timeout—not a better truth oracle.

## Native solution: binary collateral hub

An immutable `BinaryClaims` hub hosts permissionlessly created market records. Each market pins its exact-transfer collateral, question/rules hash, chosen resolver address and code-identity tuple, trade cutoff, final resolution deadline, supply ceiling and payout semantics. Creation does not place it in a founder-curated discovery list.

The question manifest includes the exact observation source, observation date/cutoff, handling of postponement/correction/ambiguity, resolver's powers, evidence format and timeout treatment. Wallet approval binds its hash. Users save the text/evidence locally and to independent archives; a hash alone does not provide availability. [ES7](../SOURCES.md#es7)

State machine: `Trading → AwaitingResult → Yes | No | Void`; final results cannot change. A selected resolver reports only after trade cutoff and at or before the fixed resolution deadline. After that deadline, anyone may finalize Void. The deadline inequalities make resolver report and timeout mutually exclusive at each finalized height.

There is **no default Pipln judge or appeals key**. V1's direct selected resolver has final authority to choose Yes/No/Void within its window. A separately deployed resolver could have immutable arbitration rules, but neither that tribunal nor a permissionless external observation feed is currently supplied. A P-256 account can report by an ordinary on-chain call; no generic off-chain signature verifier is assumed.

For collateral amount q, `split(q)` receives exactly q underlying units and mints q Yes plus q No units to the designated receiver. `merge(q)` burns q of each and returns q collateral before or after resolution. Both verify actual transfer balance deltas and make all state changes atomically.

Final payout vectors are Yes `(1,0)/1`, No `(0,1)/1`, or Void `(1,1)/2`. `redeemAll` burns the caller's selected-market holdings and pays the combined integer-floor entitlement, subject to signed minimum payout and transfer success. These claims survive missing websites/market creators; only the stored outcome/deadline and asset behavior matter.

**Void is not a reversal of trades.** A Yes token bought for 0.9 collateral receives 0.5 under Void; its holder does not regain the purchase price. A holder of a complete Yes/No pair may instead merge for full collateral. Rounding dust remains in the market reserve with no sweep recipient; bound it by less than one underlying base unit per full-holding redemption. Repeatedly fragmented holdings can increase aggregate dust, so the wallet consolidates and shows rounding.

Trades use a separately verified ERC-1155 adapter/order settlement path, with recipient, price cap, expiry and actual delivery checks. The hub does not invent a privileged matching engine, curated maker set or default price feed. This trading integration is a release dependency, not an already-working native exchange. The lifecycle below isolates collateral/position settlement; executable buy/sell workflows must add their incremental settlement state and bytes.

## Packed position and market layout

All collateral reserve and position quantities are bounded below `2^128`; arithmetic uses wider intermediates. Two ERC-1155 token ids derive from a monotonic market sequence; ids are never reused. `balanceOf` selects the appropriate half of the packed word. Compiler/accessor correctness is a critical gate.

| Word | Fields | First occupation |
|---|---|---|
| H0 | `uint64 nextMarket; uint64 brakeSince; uint8 brakeFlags; uint120 layoutTag` | 100 u at hub deployment, nonzero tag |
| M0 | `bytes32 questionRulesHash` | 100 u at market creation |
| M1 | `address collateral; uint64 tradeEnd; uint32 marketFlags` | 100 u at creation |
| M2 | `address resolver; uint64 resolutionDeadline; uint32 status` | 100 u at creation |
| M3 | `uint128 reservedCollateral; uint128 reserved` | 100 u at first nonzero collateral deposit |
| M4 | `uint128 yesSupply; uint128 noSupply` | 100 u at first split |
| M5 | `uint64 resolvedHeight; uint64 brakeSince; uint8 brakeFlags; uint8 payoutCode; uint112 layoutTag` | 100 u at creation, nonzero tag |
| M6 | `bytes32 evidenceHash` | 100 u at first resolution; timeout uses a deterministic nonzero deadline marker |
| M7 | `bytes32 identityHash` of collateral/resolver code identities | 100 u at creation |
| `holding[market][account]` | `uint128 yes; uint128 no` | 100 u per newly nonzero market holder, rather than separate words per outcome |
| `operatorApproval[owner][operator]` | Retained ERC-1155 approval word | 100 u per newly retained approval |
| `reserveByAsset[asset]` | `uint256 sumOfMarketReserves` | 100 u when an asset first backs any market |

Source/token code identity does not prove truthful balances or reports, and a proxy's outer code hash does not pin its implementation. Admissible markets must expose that limitation; a mutable identity requiring hidden admin trust is not marketed as immutable.

A first collateral holder word at the hub adds 100 u in the token contract. An underlying recipient balance that was zero adds another 100 u on payout, even for an old account. Cleared positions/approvals/reserves never refund burned state fees, and later reoccupation is priced again. Distinct market/user combinations grow state despite packing.

Outcome/resolution and outstanding rights remain on-chain. Market metadata cannot be deleted while any position supply or reserved entitlement exists. After complete settlement, retained dust is not redirected to a publisher, resolver or founder. No event root substitutes for a holder's live balance. [ES1, ES7](../SOURCES.md#es1)

## User approval sequence and gates

Split: one P-256 `execute` batch for exact approval plus split; safe ERC-1155 receipt must succeed. A user buying one outcome needs a separately signed bounded trade; maker signatures using ERC-1271 are enabled only after that account capability exists. The receiver hooks are a hard gate even for the ordinary split into an EastSea delegated account. [ES2, ES3](../SOURCES.md#es2)

Merge or redeem: one P-256 transaction, with minimum collateral output and deadline. Anyone may submit timeout finalization; the user need not obtain the creator's signature. Existing payment sessions do not grant position trades, operator approvals, splitting or redemption.

The user sees “What must happen”, “Who decides”, “Most you can lose”, “Last decision date estimate”, and “If no answer: your Yes/No unit pays 0.5”. They never need to learn condition ids, BLS signatures or ERC-1155, but resolution trust and Void losses remain visible.

## Paid-state ledger and lifecycle

Design estimates only. `H=ceil((E+128+O+L)/32)`; ordinary account batch E=512 B, O=0 and account event=128 B. Transfer/Approval ERC-20 events are 192 B. A two-id ERC-1155 TransferBatch has four topics and 256 B ABI data: **448 B total**, not two unpriced receipt entries. [ES1, ES2](../SOURCES.md#es1)

| Action | Newly occupied words | L with account event | Estimated U |
|---|---|---:|---:|
| Create market, E=2,048 B | M0/M1/M2/M5/M7 = 5 | Created 288 + account 128 = 416 B | 581 |
| First-ever collateral split into first holder | M3/M4/holding/reserveByAsset/token hub holder = 5 | Approval 192 + asset Transfer 192 + batch 448 + Split 192 + account 128 = 1,152 B | 556 |
| First split in another market using initialized asset | M3/M4/holding = 3 | 1,152 B | 356 |
| Another holder splits in active market | holding = 1 | 1,152 B | 156 |
| Existing holder adds pairs | 0 | 1,152 B | 56 |
| Merge / positive combined redemption | 0 when recipient's token balance stays nonzero | Batch burn 448 + asset Transfer 192 + result 192 + account 128 = 960 B | 50; +100 for zero/fresh token recipient |
| Redeem losing-only position, no asset transfer | 0 | 768 B | 44 |
| Resolve, E=1,024 B | M6 = 1 | Resolution 192 + account 128 = 320 B | 146 |
| Permissionless timeout | M6 = 1 | 320 B | 130 |
| Outcome transfer into a new holder | holding = 1 | TransferSingle 256 + account 128 = 384 B | 132 |
| Retained operator approval | approval = 1 | ApprovalForAll 192 + account 128 = 320 B | 130 |
| Brake latch | M5 update only | Brake 160 + account 128 = 288 B | 29 |

An exact approval consumed and cleared within the split transaction adds no final allowance word; its event still costs units. Failed calls at E=512 B/O=128 B have 24 archive u before surviving protocol/account additions. Safe-receiver failure rolls back mint, asset transfer and app logs. Do not count a rolled-back holder as paid occupied state.

Planning hub deployment: **C=10,000 runtime B**, E=16,384 B, L=192 B, one account and H0 → `10,000+100+100+522 = 10,722 u`. Instance reuse shares this hub code; a separate deployment per question would cost it again. No code-size result is asserted.

Complete collateral/position lifecycle: one new hub and market, one collateral asset, 100 already-funded users each splitting a pair, one resolver report, and all 100 redeeming complete holdings into still-nonzero underlying balances: `10,722+581+556+99*156+146+100*50 = 32,449 u`, or **324.49 u/user lifecycle**. This is a conservation/settlement cohort, not 100 directional bets or a liquid order book.

At 100% shared B5 refill, that is approximately **8,520 completed settlement lifecycles/day**; 50%/10% give approximately 4,260/852. Floor state fee is **0.032449 DBLN for the cohort**, plus exec/prove/tips and any explicitly chosen resolution cost. All-zero withdrawal recipient balances add 10,000 u. Actual directional trades add their incremental words/bytes/events and recompute one combined H per transaction, never sum two standalone action totals.

The cohort takes at least `ceil(32,449/32)=1,015` finalized heights of refill. A 100-user pair split creates at most 105 distinct new words in this illustration; it is not assumed to fit one transaction or avoid the 512/block slot cap. Two 512 B user envelopes give a generous archive ceiling of four lifecycles/height before question/evidence bytes and system traffic. Shared asset-reserve/market supply words cause contention; measure optimistic conflict repair. [ES1, ES11](../SOURCES.md#es11)

## Deterministic brake and honest refunds

The standard no-argument `brakeState()` reports **hub-wide** sequence/layout invariant faults with guardian zero; it does not iterate all markets or turn one bad market into a global pause. The wallet additionally queries `marketBrakeState(marketId)`, also guardian zero. New splits/trades in that market stop after tradeEnd, on pinned identity mismatch, or when actual collateral balance is below that asset's `reserveByAsset`. Permanent market identity/asset-shortfall faults may be latched by permissionless nonreverting `tripMarketBrake(marketId)`; each entry also checks the predicate. An immutable supply ceiling is a reversible capacity refusal. Other healthy assets/markets remain independently usable; no extra per-market facade deployment is assumed.

Merges, resolver report, timeout and valid redemption remain callable under an entry brake **subject to outcome rules, owned balances, actual collateral and successful token transfers**. Each collateral payout requires full pre-transfer aggregate backing for that asset and post-transfer balance at least the updated `reserveByAsset`, including all other markets and retained dust. A shortfall stops payouts until backing is restored; this design has no first-exit priority or implicit cross-market haircut. A frozen issuer can still defeat payout with adequate backing. No bailout key or unconditional refund promise exists; a merge cannot transfer another market's backing merely because it is an exit.

The chosen resolver can lie or withhold; timeout removes indefinite waiting but can deliberately force Void. Arbitration, observation availability and slashing are not delivered primitives. The committee can censor reports/trades before deadlines, and a token issuer can freeze collateral. These powers are shown to users and in comparisons; there is no central native curator that promises to make a market safe.

## MEV, original wins and verification

Public positions and deadlines permit information advantages, price reordering and last-moment liquidity changes. Trade caps/expiry bound authorized price loss, not fair price. Draw-based timelock encryption has early-signing and SDK gates and does not replace the resolver; no encrypted order book or secret/private bet is claimed. [ES4, ES5](../SOURCES.md#es5)

Potential win: packed binary holdings, deterministic timeout and direct wallet explanation of Void. Worse: limited questions/partitions, dust, missing live resolver/trading stack and no appeals in v1. CTF wins on combinatorial composition; a working original venue wins on liquidity, resolver integration and deployed tooling. [Gnosis CTF](https://conditional-tokens.readthedocs.io/en/latest/developer-guide.html), [Polymarket positions](https://docs.polymarket.com/trading/positions/how-positions-work).

Benchmark pinned binary CTF/CTF Exchange against the same question, collateral, oracle/deadline trust and P-256 user flows. Separately label native-only timeout behavior and removed combinatorial features. Add full maker/taker buying, selling and failed-order cohorts only after the ERC-1155 settlement adapter exists.

Tests: split/merge conservation; packed half isolation and supply limits; unauthorized/double resolution; cutoff/deadline edges; withheld resolver→Void; Yes/No/Void payout and rounding; buying above 0.5 then Void loss; missing evidence; issuer freeze/short delivery; receiver failure/reentrancy; cross-market approvals/ids; all exits under brake; abandoned market/holders; identical sequential/parallel roots. Measure code, storage, signatures, source/trade costs and sustained ≥10,000-height cohorts before any superiority claim.

Release gates: real user-selected observation/resolver and any arbitration policy; receiver hooks; ERC-1271 for signed trading; tested position-settlement adapter; explicit app-registry treatment. Registry design classifies prediction-market discovery as gambling-like; this template does not imply a beta wallet listing or founder-run venue. [ES10](../SOURCES.md#es10)
