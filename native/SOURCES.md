# Evidence ledger

Accessed 2026-10-06. This ledger distinguishes locally inspected EastSea specifications from primary public evidence about originals. Team-reported metrics establish observed demand, not independent audit, unique humans, consumer retention, or demand on EastSea. Historical figures remain historical; they are not extrapolated to today's market.

## ES0

`aether-node`, inspected `lead` worktree, HEAD `f92c839e9b2cc41b3f19c0b25ae42f1b4b1738bf`, `docs/research/clone-catalog-2026-10-06.md`, particularly §0 B1–B6, §1 H1–H14, §5 methodology. Root research paths supplied in the brief were absent; lead copies were used. Available copies contain §0–§7 and **no §8**. The explicit founder brief supplies the two-track requirement, not an invented quotation from §8.

The catalog's DefiLlama 2026-10-06 usage figures were not independently reproducible from a retained raw API response in this task. They are discovery leads, **not promoted here into verified usage measurements**. Licence assertions likewise require the exact original pin before implementation.

## ES1

`docs/design/27-state-fee.md`: authoritative persistence inventory, final-state accounting, transaction/receipt byte formula, B5 state and independent encoded-payload rolling budgets, congestion pricing and legacy-7780 separation. Exact units and floor in [PRIMITIVES.md](PRIMITIVES.md). The generic state fee is growth pricing, not recurring rent; no burned-state-fee deletion refund is specified.

## ES2

`contracts/src/EastSeaAccount.sol`: P-256 atomic self batches, independently authorized added owners, guardians/delayed recovery, restricted payment sessions, original-key revocation limitation. `isValidSignature` and NFT receiver functions absent in the inspected source; other engineers are adding them. Presence in a roadmap is not deployed support.

## ES3

`crates/execution/src/account.rs`: exact encoded account calls, SHA-256 owner/recovery/session messages and namespaced storage accessors. Sessions have eight slots of struct stride plus dynamic recipient entries and per-token mapping records; zero-valued fields do not automatically incur occupied-slot units.

## ES4

`contracts/src/Randomness.sol`; `crates/node/src/handoff.rs`, especially `seed_message`, `verify_seed`, `tick`: system randomness word versus raw seed signature, epoch/draw distinction, threshold namespace, signing when the pool is frozen, pre-epoch predictability. No safe cutoff follows from a zero randomness storage word.

## ES5

`docs/research/nextgen-ideas-2026-10-06.md`: §2 ideas #2 sponsor, #6 sub-accounts, #9 synced-passkey recovery, #20 draw timelock encryption, #21 encrypted mempool; §§3–4 roadmap and assumptions. Survey statements about existing ERC-1271/static DAG/free fees are superseded by the inspected source and newer design-27 boundaries. Several vendor metrics are labeled unverified in that survey and are not used as adoption proof here.

## ES6

`docs/design/22-gas-pool.md`: its leading 2026-10-05 A6 correction withdraws zero-balance ordinary transactions on new genesis and marks tier-3 sponsorship unimplemented. A proposed envelope sponsor field, device eligibility and burn-funded pool are not present contract APIs. New open app-funded sponsorship is distinct from that proposed protocol-subsidized pool.

## ES7

`docs/design/04-execution.md`; `crates/execution/src/receipt.rs`; `crates/light/src/lib.rs`: ordered canonical receipt commitments, committee-certified verification, lagged state proofs and explicit exclusion of receipts from the current guest execution-proof statement. A certified receipt does not verify off-chain delivery, an oracle observation's truth, or permanent archive availability.

## ES8

`docs/design/26-name-service.md`: existing immutable names, fixed burn fees, commit bond and 60 s/24 h commit window, 365-day renewal, 30-day grace, two-step owner transfer, bounded text fields, forward-checked reverse resolution. This is not a human-identity primitive.

## ES9

`docs/design/16-vault.md`: existing P-256 treasury, 1–8 owners, queue/delayed configuration, native-only small spending, default 48 h/minimum 24 h delay, invalidated older-era proposals and deterministic factory-address caveat. A separate native account's recovery guardians are not a treasury quorum.

## ES10

`docs/design/31-app-registry.md`: §2 immutable non-custodial registry; §4 manifest; §8.2 proposed brake interface; §8.3/§15 financial-app discovery/execution boundaries; isolated app origins and hash verification. Brake interface is explicitly proposed, not a network-admin brake. Publisher release/cancel authority concerns their own manifests, not custody of users' contract funds.

## ES11

`docs/design/04-execution.md`: its 2026-09-26 implemented-parallelism section supersedes its earlier static-DAG plan. Optimistic speculative execution with serial conflict repair is the observed design. Opcode/precompile/gas probes in ES0 remain required because the spec whitelist differs from the stock Osaka executor described by that catalog.

## EastSea source fingerprints

Repository-relative paths below refer to the sibling node `lead` checkout; they are not bundled node code. SHA-256 fingerprints identify the files actually reviewed, including any working changes, rather than implying every reviewed byte is in the listed HEAD. Public verification of unreleased node code remains a limitation of this design record.

| Path in node checkout | SHA-256 at inspection |
|---|---|
| `docs/research/clone-catalog-2026-10-06.md` | `976f2f205ffa90e4264f5c03b56402532bc617f706b2a279006dea1dce73a5a1` |
| `docs/design/27-state-fee.md` | `78a8ae53b4283acd540831f9962ee6f100ec56a35b8553acb4162710f0dae7d5` |
| `contracts/src/EastSeaAccount.sol` | `e29622132f727a630debe0ced25106753c84e8a0e1caf2b9e27302d827092278` |
| `crates/execution/src/account.rs` | `d535fd067fbb1d1115501c076f63a67165975be2f4bef374db2f3aa2f7648d1e` |
| `contracts/src/Randomness.sol` | `838ce3f8156d987e54a07e7a0692ccd5e8a2a379bd9562d2c21a1ba0b4ed0a5e` |
| `crates/node/src/handoff.rs` | `be669440688755fa100ffb5ee68c964ed5e86e2cf47397a8d4bbb04f1215f5e0` |
| `docs/research/nextgen-ideas-2026-10-06.md` | `43892ff1a6d55715bb960cf922029ad0ad3fedd4977aa3d1ef95275fbedc5f64` |
| `docs/design/22-gas-pool.md` | `fa5b34c0bf6dc6c7fdb0db468af411916fbdf7795970835835278bbaa68008c5` |
| `docs/design/04-execution.md` | `0266fbc912a71978347d2afd54f540a180edd930dc859ff07442bb2d0233c7e6` |
| `crates/execution/src/receipt.rs` | `5b4c7c89160c06c6002b7d184521141a8141a6c943e12b2c6ba8d6f9e672ee1c` |
| `crates/light/src/lib.rs` | `25cd1741fdb6e9a3b2a4b8862f5bb37ecbab87cc40a1bec74cf98700cc2afc84` |
| `docs/design/26-name-service.md` | `f3e35b6e3b672d4132dbdb57a31d2d90a283a26f0ef05109bc8b89811f062b63` |
| `docs/design/16-vault.md` | `b01b9e41fb00669afdbf4073ee33e3d794b44b6dda09e891f1191e3e44694430` |
| `docs/design/31-app-registry.md` | `7ea5af003ea8c6bfb8c5b388796aeda7b8a8cd551d47fe7249824763fda23b50` |

## Public primary evidence: exchange, credit, money and prices

| Key | Source, date, and supported claim | Interpretation limits |
|---|---|---|
| EX1 | [Uniswap Foundation roadmap](https://www.uniswapfoundation.org/blog/a-roadmap-for-programmable-liquidity), 2025-05-14: protocol crossed $3T cumulative swap volume the previous week. | Team-reported aggregate volume, not number of people or a native-design benchmark. |
| EX2 | [Introducing UniswapX](https://blog.uniswap.org/uniswapx-protocol), 2023-07-17: fragmented routing; signed orders, filler-paid gas; initial approvals still cost gas; inventory fills avoid sandwich exposure; protocol fee switch exists. | This original already solves much of “hide gas / route for me”; native work must beat that baseline. |
| EX3 | [CoW MEV protection](https://docs.cow.fi/cow-protocol/concepts/benefits/mev-protection), live documentation read 2026-10-06: directed uniform clearing, solver execution and peer matching. | Mechanism explanation is not a guarantee that all oracle/inclusion/solver risks vanish. |
| CR1 | [Aave 2025 recap](https://aave.com/blog/aave-2025-recap), 2026-01-29, describing 2025: $950B all-time loans created and $55B year-end deposits. | Team reported; repeated borrowing is not new borrowers. No claim that this liquidity exists on EastSea. |
| CR2 | [Aave health factor/liquidations](https://aave.com/help/borrowing/liquidations), documentation read 2026-10-06: collateral-price monitoring, permissionless liquidation and competitive execution. | Version/configuration pin still required; use as documented loss/UX exposure, not an alleged exploit. |
| ST1 | [Circle 2024 milestones](https://www.circle.com/blog/shaping-the-future-of-money), 2025-01-15: over $45B USDC circulation entering 2025. | Issuer reported; stablecoin supply is not end-user count or payment-only usage. |
| ST2 | [Circle SVB reserve update](https://www.circle.com/pressroom/3-3-billion-of-usdc-reserve-risk-removed-dollar-de-peg-closes), published 2023-03-13, statement dated 2023-03-12: $3.3B held at SVB and depeg/banking-reserve exposure. | Describes an event, not persistent current insolvency. |
| ST3 | [Liquity V1 borrowing](https://docs.liquity.org/liquity-v1/faq/borrowing), documentation read 2026-10-06: ETH collateral, 2,000 LUSD minimum debt, redemption/liquidation and repayment premium. | Existing immutable designs already exist; removing an admin is not itself a new advantage. |
| OR1 | [Pyth pull architecture](https://www.pyth.network/blog/pyth-a-new-model-to-the-price-oracle), 2022-12-13: demand-driven updates, signed data and push-update tradeoffs. | Historical architecture; do not assume a free or authorized 2026 deployment. |
| OR2 | [Pyth Core upgrade](https://www.pyth.network/blog/the-pyth-core-upgrade), 2026-05-26: proposed July 31 commercial change, API plans from $500/month and network-support boundaries. | Data access/verification availability must be checked for the exact current version and EastSea. |
| OR3 | [Pyth update requirements](https://docs.pyth.network/price-feeds/core/why-update-prices), documentation read 2026-10-06: caller-paid updates and stale-price errors. | A signature establishes attribution, not an independently true price. |

Each item design cites additional primary mechanism/security documents directly. [PROBLEMS.md](PROBLEMS.md) cites the dated adoption and limitation evidence adjacent to each family; its sources are not hidden behind this ledger.
