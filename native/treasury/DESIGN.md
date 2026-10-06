# Treasury: share money without sharing one person's private key

Status: reuse/adaptation design, 2026-10-06; **Lane A, P1**. Reuse the existing `EastSeaVault`; do not deploy another parallel treasury custodian. Wallet work is the first implementation. Optional queue/brake improvements require a separately deployed immutable version. Inherits [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md).

## The user's problem

A family or small organization needs more than one person to approve a large payment, while routine purchases should not require a meeting. Sharing one key makes responsibility and revocation unclear. Safe addresses that need through an owner threshold, relayed signatures and configurable modules. The native answer is an understandable joint-account experience using EastSea's existing P-256 vault—not another copy of Safe's entire extension framework. [Safe owners, threshold and transaction concepts, accessed 2026-10-06](https://docs.safe.global/advanced/smart-account-concepts), [Safe modules](https://docs.safe.global/advanced/smart-account-modules).

Best layer: **existing contract + wallet**. An EastSeaAccount guardian threshold authorizes delayed recovery; its added owners independently authorize batches. Neither is a substitute for m-of-n spending approval. The joint vault stores P-256 public keys and enforces its own threshold. [ES2, ES9](../SOURCES.md#es9)

## Baseline to reuse, not reinvent

The inspected `EastSeaVault` has one to eight P-256 owner keys; a chosen threshold; a native-DBLN small-spend ceiling shared by all owners; and a large/token withdrawal queue. One owner may make a native transfer within the ceiling. Other transfers need distinct-owner approvals and a delay of **at least 24 hours**, default 48 hours. Any one vault owner can cancel a pending proposal. [ES9](../SOURCES.md#es9)

That veto is an explicit power of the joint account's chosen participants, not a Pipln admin key. The wallet describes it as “Any joint owner can stop this before it pays.” Do not market it as a pure threshold wallet with no minority censorship.

Configuration changes use the same threshold/delay. A successful owner/threshold/limit/delay change increments `queueEra`, making old proposals invalid. It does **not physically delete every old mapping record**. The old queue can leave paid occupied slots behind, so “queue reset” is not cleanup or a state-fee refund. [ES9](../SOURCES.md#es9)

The contract has no fee recipient, admin, proxy or arbitrary delegatecall/module installation. Direct native deposits and exact-delivery ERC-20 withdrawals are supported. Small immediate spends are native-only. The minimum vault delay differs from account recovery's minimum; one-second finality cannot shorten it. [ES2, ES9](../SOURCES.md#es9)

## Product adaptation

The wallet has four ordinary actions: create a joint account, pay within its budget, request a larger payment, and approve/cancel a request. Show remaining shared spending capacity, which people must approve, and the time after the final required approval before execution. Never label a requested transfer paid until the receipt and actual asset delivery verify.

Keys are participants' device P-256 keys, not Ethereum address signatures. Display human names through the existing name registry only after forward/reverse checks; a name is not proof of identity or credit. Save the vault address, owner configuration, proposal bytes and receipts on each participant's device. No hosted coordinator gets signing authority. [ES8, ES9](../SOURCES.md#es8)

`spend` uses today's plus yesterday's spending, so it conservatively bounds every 24-hour span. It can remain stricter than a smooth rolling window after a UTC-day boundary; display the real available amount instead of advertising exactly renewed capacity every 24 hours. [ES9](../SOURCES.md#es9)

Current large-transfer sequence: first owner signs the vault withdrawal digest; a funded relayer proposes it; each other required owner signs the **same** digest and a funded relayer records that approval; after the threshold timestamp plus delay, anyone executes. Proposal ids are monotonic and the digest binds chain, vault, id, asset, recipient and amount. The last needed approval starts the timer; later approvals do not extend it. [ES9](../SOURCES.md#es9)

Count owner authorization signatures and canonical relayer signatures separately. A self-relaying owner signs both the vault digest and transaction envelope; using a third-party relayer moves the latter signature/fee to that relayer. A two-owner queued payment still needs two owner signatures and, today, proposal/approval/execution payer transactions. A single biometric interaction must not be reported as one cryptographic signature if it authorizes both domains.

An owner signs a configuration replacement over the complete new key/threshold/limit/delay set; existing owners approve it. The new device joins only after that replacement executes. Owner keys, spend/cancel nonces and proposal ids remain authorization state; a receipt is not a substitute for them.

## Optional immutable next version: only bounded improvements

Release the wallet using the baseline first. A later immutable version may add these narrowly scoped features after comparison:

- `retireStale(id)`: permissionless deletion of one old-era proposal, only when its kind exists and its era is older; iterate at most eight stored keys. Never treat a current unexecuted proposal as stale.
- An active-proposal counter/cap of 64, decreasing on cancellation/execution and resetting its current-era count on configuration replacement. Capacity refusal affects **new proposals**, not existing approvals, cancellations or executions.
- `brakeState/brakeSpec` reporting this local deterministic entry condition with guardian zero. Full capacity is reversible; no owner or founder can set an arbitrary pause bit. A version-specific invariant failure may latch only on a specified verifiable predicate.
- Optional `proposeAndApprove` accepting all distinct P-256 owner approvals in one funded relay transaction, with bounded eight-key verification and the same delay. This changes no threshold or veto semantics.

None of these methods/counters is present in the baseline. No wrapper can enforce them against direct calls to an old vault. Adoption requires explicit owners moving funds into a new vault or continuing with the old one; there is no invisible upgrade or account-redelegation substitute.

Current `brakeState`/manifest integration is therefore a **new-version gate**. Baseline spending limits and authorization/delay checks are deterministic action preconditions, but they are not an implemented registry brake interface. Registry integration is itself a design/deployment gate. [ES9, ES10](../SOURCES.md#es10)

A batched-approval version can reduce relayer transactions without reducing the number of owners' approvals. Compare actual envelope/proving cost before claiming savings; a larger signature array and extra code consume B5 too. Never silently assume ERC-1271 or a session grants treasury approval.

## Baseline storage packing and units

Derived from the inspected Solidity declaration order, **not compiler-measured yet**. Each newly nonzero word costs 100 u; mapping roots and zero fields are not paid occupied words. [ES1, ES9](../SOURCES.md#es1)

| Contract word | Packing / occupation |
|---|---|
| owners array root + elements | One length word, plus two 32-byte coordinates per nonzero valid key: up to `1+2N` words |
| configuration word | `uint8 threshold; uint64 delay; uint128 dailyLimit` fit 25 bytes; one nonzero word at construction |
| daily word | `uint64 spendDay; uint128 spentToday` fit 24 bytes; first valid spend occupies it |
| previous-day word | `uint128 spentPrev`; first rollover with prior spend occupies it |
| spend/cancel counters | Separate `uint256 spendNonce`, `cancelNonce`; 100 u each when first nonzero |
| proposal/era counters | Separate `uint256 proposalCount`, `queueEra`; 100 u each when first nonzero |

Proposal struct allocation:

| Relative word | Fields | When it becomes nonzero |
|---|---|---|
| p0 | `Kind` enum | Every proposal |
| p1 | `uint256 epoch` | Proposals after the first configuration change; initial era is zero |
| p2 | `uint256 approvals` | First owner approval, included in proposal creation |
| p3 | `uint64 readyAt; address token` | ERC-20 proposal immediately, or native proposal when threshold is reached |
| p4 | `address to` | Withdrawal proposal |
| p5 | `uint256 amount` | Positive withdrawal proposal |
| p6 + dynamic elements | Replacement owner-array length and two words/key | Settings proposal |
| p7 | `uint8 newThreshold; uint128 newDailyLimit; uint64 newDelay` | Settings proposal; 25-byte packing |

For a native withdrawal in initial era with threshold two, proposal creation occupies p0/p2/p4/p5; its later threshold approval occupies p3. An ERC-20 proposal already occupies p3 through its token address, so threshold approval adds no word. First proposal also occupies proposalCount; a post-rotation proposal adds p1. Amount zero and threshold-one paths must be measured separately.

Retiring/executing/canceling a proposal clears its words but replenishes neither burned fees nor the B5 bucket. Owner rotation to the same key count generally overwrites existing coordinates; adding more keys occupies two extra words/key. Old-era proposal owners remain until genuinely cleared; expose abandoned-record growth in benchmarks. [ES1, ES9](../SOURCES.md#es9)

## Action cost ledger

Illustrative **direct funded relayer** envelopes E=512 B, O=0 except proposal output O=32 B. There is no extra account `Executed` event on this direct call path. `H=ceil((E+128+O+L)/32)`. Costs exclude a newly created canonical relayer account, which adds 100 u. Exec/prove gas is to measure. [ES1, ES9](../SOURCES.md#es1)

| Baseline action | Newly occupied words | Metered event bytes L | Estimated U |
|---|---:|---:|---:|
| First positive small native spend to existing recipient | daily word + spendNonce = 2 | Spent 256 B | 228 |
| Repeat same-day small spend | 0 | 256 B | 28 |
| First next-day spend with prior spend | spentPrev = 1 | 256 B | 128 |
| First native withdrawal proposal, era zero/threshold two | Four proposal words + proposalCount = 5 | Proposed 224 + Approved 224 = 448 B; O=32 | 535 |
| Further native proposal, era zero | Four proposal words = 4 | 448 B; O=32 | 435 |
| Approval that reaches native threshold | readyAt word = 1 | Approved 224 B | 127 |
| Extra already-ready approval | 0 | 224 B | 27 |
| Execute native withdrawal, existing recipient | 0; proposal clears | Executed 224 B | 27 |
| First ERC-20 proposal, era zero | Five proposal words + proposalCount = 6 | 448 B; O=32 | 635 |
| ERC-20 threshold approval | 0 | 224 B | 27 |
| Execute ERC-20 withdrawal, nonzero token recipient | 0 | Executed 224 + Transfer 192 = 416 B | 33 |
| First cancellation | cancelNonce = 1; proposal clears | Canceled 160 B | 125 |
| Later cancellation | 0 | 160 B | 25 |

Fresh native recipients add a 100 u account; zero/fresh ERC-20 recipient balances add a 100 u holder word. Any retained token allowance in future extensions is separately priced. Failed bad-signature/not-ready/over-budget/short-delivery calls commit no vault words, but charge their actual envelope/revert output and surviving sender state; E=512/O=128 gives 24 archive u.

Three-key settings proposal in initial era occupies `4+2*3=10` proposal words, plus proposalCount if first. E=1,024 B, O=32, Settings event 480 B and Approved event 224 B → H=59 u: **1,159 u if first proposal**, otherwise 1,059. Threshold approval adds 127 u. First settings execution adds queueEra 100 u plus event/base 25 u; existing same-length owner/config words are overwritten, not newly allocated.

## Full lifecycle, including code and wait

Planning input: one three-owner vault runtime **C=10,000 B**, factory-call envelope E=16,384 B, VaultCreated+account events L=384 B, O=0. Contract account 100 u + eight initial words 800 u + H=528 u → **11,428 u**, plus separately measured factory deployment amortization `D_factory/K`. Factory runtime embeds child initcode; cloning is not assumed.

A standalone first native large withdrawal costs **535+127+27 = 689 u** after deployment/funding, plus a real 48-hour approval delay at default settings. A warm initial-era one costs 589 u; after rotation p1 adds 100 u. The comparable first ERC-20 path costs 695 u, plus token-recipient state if needed. These are network state fees, not transferred principal.

Complete planned joint-account cohort: deploy; one native funding envelope E=256/no event (**12 u**); 100 positive small payments on one UTC day (**228+99*28=3,000 u**); rotate three keys via the first settings proposal/approval/execution (**1,159+127+125=1,411 u**); one post-rotation native large withdrawal (**535+127+27=689 u**). Total **16,540 u**, or **165.4 u per routine payment** including code, funding, rotation and the later exit; add `D_factory/K`, fresh recipients, failures and real compiler layout differences.

At 100% shared refill, the cohort amortization has a state-only ceiling of **16,715 routine payments/day**; 50%/10% give 8,357/1,671. A retained warm 28 u spend alone has a ceiling of **98,742/day**. The shared daily money limit, funded balance, signatures and withdrawal delays can bind long before these numbers. An E=512 B direct relay also has an archive-only bound of eight transactions/height before system traffic.

Floor state fee for the full cohort is **0.016540 DBLN**, plus exec/prove/tips; its state capacity takes `ceil(16,540/32)=517` finalized heights to replenish. Neither owner approval waiting nor a mandatory 24/48-hour delay is replaced by that refill time. Additional factory/new-version code is not included in this explicit baseline instance estimate.

## Brake, failure and trust

The optional template's deterministic entry brake closes new proposals at its 64-current-era cap; guardian zero and permissionless terminalization/old-era retirement prevent a publisher from owning restart. The baseline does not provide this counter/interface. Neither version creates funds or bypasses a lost quorum.

Genuine exit preconditions: current-era proposal; distinct current owners reaching threshold; elapsed readyAt/delay; sufficient balance; exact recipient/token delivery; successful recipient call. One current owner may veto before execution. Small native spend additionally requires an owner signature, expected nonce and shared daily capacity. No founder rescue or guardian-recovery shortcut bypasses those rules.

A malicious owner can spend the small native budget and veto pending requests. Threshold collusion can approve loss of funds or choose harmful configuration. Relayers/committee can censor, and token/recipient contracts can reject payment. Loss of enough owner keys can permanently lock funds. Adding recovery would require a separately authorized design, not an admin backdoor.

Signed recipient/amount/token prevent a relayer from substituting a payment; delays give co-owners time to veto, not guaranteed observation. Public queued payments reveal intent; a token trade or recipient contract can suffer ordering/price changes. The existing vault checks ERC-20 recipient balance delta; unsupported fee-on-transfer/rebasing/frozen assets do not become safe because the transfer is threshold-approved. [ES9](../SOURCES.md#es9)

## Original wins and benchmark plan

Potential win: reuse a bounded joint-account contract with device-native signing and clear routine/large-payment flows. Safe already supports contract signatures and passkey integrations; P-256 UX alone is not exclusive to EastSea. Safe wins where richer modules, ERC-20 allowance workflows, arbitrary routine calls and established integrations are needed; native-only small spending is a real limitation. [Safe signature formats](https://docs.safe.global/advanced/smart-account-signatures), [Safe concepts/modules](https://docs.safe.global/advanced/smart-account-modules).

Compare pinned Safe with equivalent threshold and optional delay/allowance configuration, and the existing vault before/after wallet changes. Count Safe's contract-signature or on-chain approveHash path for P-256 accurately; pending account ERC-1271 is not presumed. Separate direct relay fees, owner device approvals and mandatory delay. Compare optional native batched approvals only if a new immutable version is implemented. [ES2, ES9](../SOURCES.md#es9)

Tests: threshold/duplicate signer and cross-vault/chain/nonce protection; every UTC-day boundary; first/new-era proposal occupancy; veto before/after readiness; exact token delivery/reentrancy; configuration queue invalidation with stale records; unchanged/new owner count; failed receiver exit; missing keys/relayers; baseline versus optional cap/brake/retirement; factory predicted address/code hash. Measure runtime/factory bytes, compiler packing, ≥100 lifecycle latency samples and ≥10,000 finalized-height state loads; publish baseline limitations and original wins.
