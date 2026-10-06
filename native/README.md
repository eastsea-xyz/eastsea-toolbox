# EastSea native: solve the problem again

People wanted to exchange assets, get liquidity without selling, pay collaborators, share control of money, distribute scarce goods fairly, and recover from a lost device. Ethereum and Solana applications are evidence that those needs exist. Their contracts are answers to those needs under particular constraints. The task here is to find a better EastSea answer, including a wallet feature, an existing account feature, or no additional contract.

Founder direction, 2026-10-06: **“그 계약들이 뭘 해결하려고 했는지에 보다 집중해줘.”** Start with the person and the problem, then select the layer. A new mechanism is useful only if it improves the completed user task.

These began as **design documents only**. Lane B0–B2 now have unaudited Foundry implementations in [claims](claims/README.md), [streams](streams/README.md) and [escrow](escrow/README.md), with shared pieces in [common](common/README.md). Lane C0–C1 add [token probes](probes/README.md), a seeded pool simulation with a test-only reference price, and the [swap pool](swap-pool/README.md). Build them with `cd native && forge test`. They are provided AS IS for testing and benchmarking. No measured EastSea performance results, deployments or superiority claims are supplied: each item's GAS.md is a placeholder until the executor recorder runs. The original-compatibility track remains a separate control: an original running unchanged does not prove this native design is good. [Source boundary](PRIMITIVES.md#source-boundary).

## What EastSea changes

Atomic P-256 account batches can reduce prompts; existing guardians, payment sessions, treasury and names can remove duplicate application systems. Committee-certified receipt proofs can support portable evidence without a hosted explorer. Nominal one-second finalized heights shorten ordinary confirmation, but not contract deadlines, collateral risk, recovery delay or draw cadence. [Observed capabilities](PRIMITIVES.md).

EastSea also introduces a hard constraint the designs must earn their way through: **100 u per fresh account/occupied slot, 1 u per persisted code byte, priced envelope/receipt bytes, a shared 100,000 u burst replenished by only 32 u/finalized height**. There is a separate canonical archive budget. Updating an occupied slot is not another 100 u; deleting it does not refund the original burn. No recurring rent is specified. [Exact accounting and B5](PRIMITIVES.md#exact-paid-state-interpretation).

Some attractive changes remain absent: ERC-1271 and NFT receiver hooks are pending; app-bound sub-accounts and arbitrary-call sessions are proposals; a native fee-payer sponsor field is not implemented; draw timelock encryption requires an SDK and an enforceable pre-signing cutoff; per-height encryption and an encrypted mempool require protocol work. [Dependency register](PRIMITIVES.md#capability-and-dependency-register). Designs explicitly gate these rather than treating the roadmap as a working API.

## Start reading with needs

[PROBLEMS.md](PROBLEMS.md) covers sixteen original application families, their documented demand and shortcomings, the EastSea primitives that matter, and the selected layer. [PLAN.md](PLAN.md) turns those decisions into three coder lanes. [SOURCES.md](SOURCES.md) records dated external evidence and fingerprints the EastSea files reviewed. [MEASUREMENTS.md](MEASUREMENTS.md) is the shared test and benchmark contract.

| User problem | EastSea answer | Detailed design / boundary |
|---|---|---|
| Buy one asset with another; keep an always-available pool | Minimal immutable pool; bounded atomic routing in wallet | [Swap pool](swap-pool/DESIGN.md) ([implementation](swap-pool/README.md)); liquidity and sandwich exposure remain |
| Find a better quote or leave a limit order without a permanent order book | Exact constraints in expiring signed intent, anyone can settle | [Intent exchange](intent-exchange/DESIGN.md); 1271 gate; no privileged solver |
| Borrow against assets without selling them | Isolated immutable lending market with explicit feed/asset trust | [Lending](lending/DESIGN.md); collateral, liquidity, feed and liquidation gates |
| Hold a useful stable unit | Existing external stable asset if independently supported; experimental collateral debt only after economic validation | [Stable value](stable-value/DESIGN.md); no promise that new debt units become dollars |
| Pay someone / release already-funded pay over time | Payment is an account/wallet task; funded stream is a contract | [Streams and vesting](streams/DESIGN.md); no transaction every second |
| Keep collective treasury funds from one person's mistake | Reuse `EastSeaVault`, improve bounded proposal lifecycle and wallet approvals | [Treasury](treasury/DESIGN.md); account guardians are not ordinary spend quorum |
| Distribute scarce NFTs without a bot race | Capped deterministic distribution now; random assignment remains gated | [Fair distribution](fair-distribution/DESIGN.md); names/accounts are not unique people |
| Raise initial liquidity without insider execution advantage | Bounded sale and refunds; sealed uniform clearing only with verified prerequisites | [Fair launch](fair-launch/DESIGN.md); public fixed-price sale does not solve Sybil fairness |
| Try an app without obtaining a separate gas coin | Funded relays for configured owners first; on-chain sponsor-budget escrow needs protocol fee settlement | [Sponsorship](sponsorship/DESIGN.md); initial setup/funding and sponsor refusal are visible |
| Trade positions in an uncertain outcome | Bounded binary positions, user-chosen immutable resolver and void rule | [Prediction markets](prediction-markets/DESIGN.md); real-world truth remains external |
| Pool funded earnings / redeem a savings position | Minimal ERC-4626 wrapper over an explicit asset and fixed source | [Yield vault](yield-vault/DESIGN.md); no native liquid staking without a staking interface |
| Make a shared decision that can execute correctly | Bounded on-chain votes with authenticated historical weight | [Governance](governance/DESIGN.md); snapshot-token checkpoints must exist and be priced |
| Address a person or business reliably | Existing `EastSeaNames` and forward/reverse-checked wallet UI | [Names catalog decision](PROBLEMS.md#identity-and-names); no second registry |
| Receive an allocation without trusting a batch sender | Immutable Merkle entitlement, retained replay bitmap and funded claims | [Claims](claims/DESIGN.md); proof distribution and fresh-holder costs remain |
| Use real-world prices safely | Immutable user-selected feed trust and on-demand authenticated report | [Oracle](oracle/DESIGN.md); beacon randomness cannot tell the price |
| Buy something without trusting the other party with all the money | Bounded escrow with explicit delivery/acceptance/deadline policy | [Escrow](escrow/DESIGN.md); receipt inclusion does not prove goods arrived |
| Recover money access after losing a device | Existing delayed guardian recovery plus wallet recovery rehearsal | [Recovery catalog decision](PROBLEMS.md#account-recovery); stolen original key still works |

## Head-to-head method

The question is **“Did this person's problem get solved better?”** Compare the native design with the pinned original on its original chain and with that same original on EastSea. Give both EastSea paths the same P-256 batch wallet, funding and holder freshness. Report the unfamiliarity the wallet removes separately from the contract improvements. The full reproducible procedure is in [MEASUREMENTS.md](MEASUREMENTS.md).

| Dimension | What must be published | A win cannot mean |
|---|---|---|
| User effort | Cold/warm steps, biometric prompts, transaction and typed-message signatures; owner/session/guardian provisioning | Ignoring setup, approvals, counterparties or the second settlement leg |
| Cost | Exec gas, prove gas, actual paid-state u, new accounts/slots/code, envelope/receipt bytes; floor fee vector and congestion cases | Converting SSTORE gas into state u, counting a deletion burn refund, or hiding relayer/filler costs |
| B5 throughput | Whole-workflow units; burst/recovery and sustained ceilings at 10/50/100% of shared refill; measured binding limit | Calling the 100,000 u burst a per-second capacity or quoting CPU-only TPS as chain TPS |
| Exposure | Slippage/price quality; failed-attempt fees; deadline misses; inclusion reordering; partial/abandoned claims and unavailable data | Equating 1 s confirmation with MEV protection or calling a hash proof of auction correctness |
| Trust | Exactly who can stop, censor, misreport, change policy, withhold data or steal; useful exits after each disappearance | “No admin” as shorthand for trustworthy issuers, independent truth or available liquidity |
| Hidden complexity | Whether the person must learn approvals, fee tokens, chain identifiers, proof formats, draw numbers or session addresses | Hiding the final price, recipient, spending cap, waiting period, loss/refund rule or selected oracle/arbiter |

An illustrative 500 u action burns **0.000500 DBLN** in state fees at the floor and has a state-only ceiling of **5,529 completed actions/day** if it consumes the entire chain refill. Ten thousand such actions consume 5 M u; even an initially full empty-chain state bucket requires at least `ceil((5,000,000-100,000)/32)=153,125` subsequent refill heights (about 42.5 h at 1 s), before execution, proving and archive limits. This is arithmetic, **not a measured design result**. Congestion pricing and other users can make both cost and completion time worse. [Accounting](PRIMITIVES.md#b5-is-shared-bursty-and-finite).

## Founder-compatible trust

No design gives Pipln, a founder key, a curator, a registry publisher, or a privileged solver the ability to upgrade custody logic, levy an operator toll, select approved users, or seize funds. Liquidity-provider compensation and user-selected counterparties are disclosed economics, not a founder protocol fee. Immutable deployment parameters are chosen by users of an instance; a different instance is a different product choice.

Each contract reports a deterministic **local** entry brake with no discretionary guardian. Predicates, latch behavior and exits are defined per item. A halted market cannot mint liquidity; repayment, refund and withdrawal retain their conservation, collateral and token-transfer preconditions. Manifest/brake evidence describes behavior; it is not curation or a safety certificate. [Registry/brake boundary](PRIMITIVES.md#capability-and-dependency-register).

The consumer sees “Pay”, “Request”, “Release”, “Receive” and a clear amount/deadline/limit. The wallet handles technical preparation and verifies its evidence. A useful product still shows “This sponsor cannot pay now”, “This price is stale”, “This money is not yet withdrawable”, or “A recovery waits 48 hours” when that fact changes the user's choice.

## Publish where the originals win

UniswapX already offers filler-paid signed swaps and handles failed-trade cost; CoW already uses solver execution and uniform clearing. These are baselines to beat, not missing features invented here. [UniswapX](https://blog.uniswap.org/uniswapx-protocol), [CoW](https://docs.cow.fi/cow-protocol/concepts/benefits/mev-protection).

Original concentrated-liquidity systems, established lending markets and stable assets may win on capital efficiency, depth, data access, integrations, track record and useful counterparties. Safer-looking small code with no users cannot replace those networks. Sablier/Seaport/Safe and Solana's applications supply real product baselines in their individual designs. Source completeness, fair-launch liveness, native staking, theft recovery and oracle truth remain explicit limits.

The deliverable is a reviewable design and falsifiable comparison plan. Implementation priority follows the [problem catalog](PROBLEMS.md), dependency gates follow [PLAN.md](PLAN.md), and superiority stays unproven until measured.
