# Act on external facts while showing who attested to them

Status: design proposal, 2026-10-06; immutable feed contract + data/consumer integration; lane C, priority P2; real-data deployment **GATED**.
Inherits [verified primitives](../PRIMITIVES.md), [measurements](../MEASUREMENTS.md), and [problem catalog](../PROBLEMS.md).

## Problem before mechanism

A lending contract must know collateral value; a prediction market must know an outcome; a wallet must know whether the fact used to take its money is recent and attributable. Block execution alone cannot observe these external facts. Chainlink's OCR aggregates signed reports off-chain and checks a quorum on-chain; the need is trustworthy, available observations without every observer writing every sample into consensus. [Chainlink OCR documentation, accessed 2026-10-06](https://docs.chain.link/architecture-overview/off-chain-reporting).

This design's promise is attribution and bounded validity, **not proof that the world agrees with the report**.

## Original lessons and changed constraints

Chainlink's feed guidance identifies market liquidity/concentration, upstream-provider availability, outage and application-specific risk; it explicitly leaves risk configuration with consumers. Redundant signatures over a shared wrong source are still shared wrong data. [Chainlink feed selection/risk guidance](https://docs.chain.link/data-feeds/selecting-data-feeds).

Pyth's official May 26, 2026 update says that the July 31 upgrade requires API plans starting at $500/month and limits default on-chain support to its stated ecosystems. EastSea support and verification must be checked, not inferred from EVM compatibility or historical free Hermes access. Its reported 700+ integrations and $3.1T+ cumulative volume are dated project claims of oracle demand, not EastSea adoption. [Pyth Core upgrade, May 26, 2026](https://www.pyth.network/blog/the-pyth-core-upgrade).

EastSea can verify P-256 signatures and charge bounded current-state writes, while avoiding a platform-controlled feed allowlist. Its BLS beacon signs draw-domain messages; it does not authenticate USD prices, TLS responses or arbitrary reporter membership. General EVM verification of historical receipts and deployed external feed/bridge verifiers are not established. [ES2](../SOURCES.md#es2), [ES4](../SOURCES.md#es4), [ES7](../SOURCES.md#es7).

## Native feed template

- Anyone deploys a feed with immutable subject/reference-unit identifiers, decimals, source-policy content hash, 1–8 pinned P-256 public keys, quorum, positive-value bounds and maximum age.
- An illustrative deployment uses five-of-seven keys. This is an explicitly chosen signer trust set, not permissionless truth or proof of seven independent institutions.
- Feed creation is permissionless; **report acceptance is intentionally permissioned by the immutable signers**. There is no founder list, mandatory curator, update admin, protocol toll or signer replacement key.
- Any proposer/relayer submits a bounded report and the quorum's signatures. Reports bind chain ID, feed address, source-policy hash, sequence, value, observed-at time and valid-until time under a fixed domain.
- The template verifies P-256 directly through the existing precompile; it does not require account ERC-1271 or secp256k1 recovery. Signature encoding, canonical scalar handling and precompile failure must be executor-tested.
- Reports have strictly increasing 64-bit sequence numbers and bounded validity. Reject duplicates/reordering, future timestamps beyond the immutable tolerance, expired observations, zero/negative prices and wrong domains.
- Reporters sign an aggregate under the published source policy. The consumer can verify who agreed; signatures do not prove inputs, median correctness, economic independence, source access or price truth.
- `read()` returns value, source/domain identity, sequence, observed time, valid-until time and brake state. No getter masks staleness by returning an apparently current value.
- External signed-feed adapters, authenticated web data proofs and outcome-dispute resolvers are **separate integrations, not implemented protocol support**. Each needs exact verifier/source/availability/licence pins and its own paid-state/gas ledger.

Signer rotation means deploying another immutable feed and obtaining user-authorized adoption in a new consumer instance. Existing markets cannot silently switch their oracle. This removes an update key while making permanent signer failure an operational dead end.

Source manifests are independently retrievable content with hashes; hashes alone do not ensure availability. Include how data is obtained, access fees/licence, reference-unit definition, aggregation policy, reporting schedule, signer affiliations and evidence retention. A consumer's own wallet can choose a local trust policy; the platform does not certify truth by listing a feed.

## Proposed state and cost

| Field | Packed target | New occupation |
|---|---|---:|
| Current accepted observation | `int128 value; uint64 observedAt; uint64 validUntil` | 1 on first accepted report |
| Ordering/entry brake | `uint64 sequence; uint64 acceptedAt; uint64 latchedAt; uint8 reason` | 1 on first report, or an earlier justified latch |
| Keys, quorum, subject, policy and bounds | Runtime immutables | Actual code bytes; seven raw P-256 keys contribute 448 bytes before encoding overhead |
| Full report history | Events + externally retained evidence | No unbounded on-chain round mapping; receipt/envelope bytes still priced |

There is no per-reporter storage bitmap: key indexes are bounded and unique within submitted calldata, and each report verifies a quorum over the same digest. Replay is blocked by the current sequence. Retaining only current state sacrifices historical on-chain reads; consumers requiring past rounds must fund a separate bounded history policy, not trust unavailable logs.

`H(E,O,L)=ceil((E+128+O+L)/32)` and `U=100*A+100*S+C+H`. In the account-batch fixture `O=0`. Proposed `Reported(value,observedAt,validUntil,sequence)` has one topic/128 ABI data bytes = 224 B; account `Executed` = 128 B. Topic counts include event signature. [ES1](../SOURCES.md#es1).

| Action | New occupied slots | Envelope + logs illustration | U |
|---|---:|---|---:|
| First valid report | 2 | `H(1024,0,224+128)` | 247 |
| Subsequent valid report, existing sender | 0 | Same | 47 |
| Read by an off-chain client | 0 | No transaction; provider service policy separate | 0 chain u |
| Read inside a loan transaction | 0 in this feed | Parent envelope/receipt + exec/prove gas | Measured in caller |
| Proven signer-policy failure latch after initialization | 0 | `H(2048,0,160+128)` | 77 |
| Invalid report reverted, fixture 32-byte output | 0 | `H(1024,32,0)` | 37 |

The last row does not promise every revert is 32 bytes; record actual output. Report envelopes include signature and report calldata. Changing five-of-seven to a different quorum changes bytes and proving work. A direct EOA submission without account logs is a different fixture, not a hidden discount.

Deployment `D=100+runtime_bytes+H(E_deploy,O_deploy,L_deploy)` initializes no observation slots. First sender nonce accounts add 100 u. Metadata/source documents stored only by hash are off-chain availability responsibilities; placing them on-chain adds code/storage/envelope units. No occupied-slot update is billed as a new slot, and no deleted history refunds past burned fees.

## Freshness and deterministic brake

`brakeState()` returns stale-entry state once `now > min(validUntil, observedAt+maxAge)`, with `since` equal to that boundary, guardian zero. A new valid report can clear this **computed non-latched condition**; that is not a discretionary pause/resume operation.

A permanent signer-trust latch can be triggered permissionlessly by two quorum-signed conflicting values with the same domain/sequence, or a quorum-signed report violating immutable value bounds under otherwise valid report time/domain rules. Both reports are verified; invalid signatures, an arbitrary caller's assertion or merely a large unendorsed price move cannot latch the feed.

`provePolicyFailure()` records reason/time successfully and blocks future acceptance; it does not revert away its latch. No key can clear it. Values remain readable as explicitly braked/stale data. Two historical conflicting signed reports are enough evidence without an EVM historical receipt verifier or stored old-round map.

Bounds and double-sign evidence can detect defined violations; a quorum can still agree on a plausible false price or stop signing. There is no claim that the brake detects all lies. The immutable key set makes that quorum an explicit trust assumption rather than an administrator pretending to be decentralization.

Consumers specify which actions require an unbraked fresh observation. Lending must preserve debt repayment and zero-debt collateral exit during a price outage. Prediction outcomes require a different signed statement/domain and dispute policy; this price template alone does not settle ambiguous sports/news outcomes.

## Signatures, MEV and human experience

Five reporters sign the same report digest off-chain; any funded submitter can send one account transaction containing it. No consumer signature is needed for an already published observation. A user opening a loan signs its ordinary atomic batch; an update can precede it or be composed in the same batch with separately measured bytes.

An already added account owner may relay the submitter's batch via `ownerExecute`, priced separately. Reporter keys are explicit P-256 feed keys; they are not automatically account owners, consensus committee keys or guardians. No native fee-payer sponsorship change is assumed. [ES2](../SOURCES.md#es2), [ES6](../SOURCES.md#es6).

**What the user never needs to understand:** quorum signature encoding, report sequence packing or data-feed ABI. They see source/signer trust, last observed time, freshness warning and the exact economic action that stops when the observation expires.

Report copying/front-running cannot change the signed value or divert consumer assets, but public updates reveal liquidation opportunities. Inclusion censorship and delayed/withheld publication can still cause stale prices or unfair ordering. Threshold reporters can censor or lie; external providers can revoke access or publish bad data; the committee can censor submissions; a relayer can refuse. This oracle holds no principal, yet its false answer can let a dependent contract seize collateral.

## Full workload and comparison gates

One feed bootstrap plus N later observations costs `247+47*N+D`, not 47 u total. At a five-second reporting cadence, 17,280 observations/day cost 812,160 u/day after bootstrap: **29.375% of all shared B5 refill**, before code/system load. Seven such feeds require 65.8 u/s, above the 32 u/s sustained shared refill. A one-second update of this fixture costs 47 u/s and cannot sustain alone under B5.

The report-only state ceiling is `32/47=0.681 reports/s`, or 58,825/day, before other apps. A report→new-borrower open→repay/exit lifecycle costs `47+171+71=289 u` with warm token holdings, plus first-feed slots, market initialization/deployment, reporter-source access and any failed attempts. Its state-only ceiling is 9,566 completed lifecycles/day. Amortizing one report across ten independent loans gives 4.7 u/loan, but report availability and freshness remain shared obligations.

The canonical envelope-only ceiling is `4096/1024=4 reports/s`; BAL and committee/control traffic lower it. Take the minimum with execution/prove/signature verification, state, transaction caps and conflicted updates. At 10% shared B5 allocation, state ceilings divide by ten. [ES1](../SOURCES.md#es1).

Floor state fee: 0.000047 DBLN/report, 0.812160 DBLN/day at that five-second fixture, and 0.000289 DBLN/report-plus-borrower lifecycle. External data fees are real costs and remain separate; Pyth's quoted subscription does not vanish when the settlement chain changes. `G_exec`, `G_prove`, code bytes, consumer-Mac throughput and actual update availability are **UNKNOWN—TO MEASURE**.

Version/source gate: pin exact Chainlink OCR aggregator/signers/configuration and Pyth post-July-31-2026 feed/verifier/API policy if used. Confirm EastSea-verifier compatibility, source access/licence and support before any real-data comparison. Benchmark the same fact quality, timestamp, quorum and outage trace; a mock five-key answer is not an equivalent production oracle.

Tests: report/domain replay; duplicate indexes; missing quorum; invalid P-256 scalar/encoding; future/expired times; monotonic sequence/overflow; wrong quote units; accepted plausible lies; double-sign proof; non-discretionary latch; offline reporters/data sources; copied reports; historical evidence availability; consumer repay/exit during outage; and ≥10,000-height shared workloads under [MEASUREMENTS.md](../MEASUREMENTS.md). Publish observed price error and outage duration as well as state/gas savings.

Original wins to publish: established data-source breadth, signer operations, production aggregation, commercial availability and existing verification/audit infrastructure can outweigh this template's smaller live state and lack of update keys. Permissionless deployment cannot make licensed real-world data or trusted observation permissionless.
