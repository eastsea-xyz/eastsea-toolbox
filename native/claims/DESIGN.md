# Receive a fixed allocation with one clear claim

Status: design, 2026-10-06; **Lane B, P1**. Best layer: funded contract entitlement plus wallet/proof distribution. No Solidity or measured results. Inherits [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md).

## The person's problem

An issuer wants a published allocation to reach its eligible recipients without operating a custodial batch-paying service. A recipient wants to know eligibility, receive the right amount and avoid paying repeatedly for an already-used entitlement. UNI's 2020-09-16 announcement allocated a user claim to 251,534 historical addresses, including about 12,000 with only failed transactions; these were eligible addresses, not a count of completed claims or people. [Introducing UNI, eligibility cutoff 2020-09-01](https://blog.uniswap.org/uni).

## What the original already solves

Uniswap's distributor already has an immutable root/token, packed 256-claim bitmap and permissionless submission to the leaf's recipient. A third-party payer and bitmap are not native inventions. Its fixed root cannot correct a wrong allocation, and the contract cannot supply unavailable leaf/proof data. [Original distributor source, checked 2026-10-06](https://github.com/Uniswap/merkle-distributor/blob/master/contracts/MerkleDistributor.sol).

The proposal shares code across finite campaigns for one chosen asset, rather than deploying one runtime for every allocation. EastSea's account batch, proof-aware wallet, finalized receipt evidence and explicit paid-state lifecycle complete the product. They benefit the original control too. Benchmark whether shared-code savings exceed additional campaign words; the original can win for one large long-lived campaign. The toolbox's [existing airdrop](../../contracts/src/airdrop/MerkleAirdrop.sol) stores an address flag per claimant and native-coin payouts; its meter must be compared under design 27 rather than its older execution-gas approximation.

## Native solution: immutable funded campaigns on one asset

An instance pins an exact-transfer ERC-20, code identity, canonical leaf/proof format and maximum 65,536 leaves/proof depth 16. Anyone creates a campaign by supplying **expectedCampaignId**, nonzero root, leaf count, fixed refund recipient, finite finalized-height deadline and exact funding. Before any token pull/state effect, require expectedCampaignId equals the current nextCampaign counter. If a concurrent creator advanced it, the entire batch fails; rebuild/publish the root for the new expected id and show the failed-attempt cost. Campaign id strictly increases and never reuses a cleared id. There is no creator root update, eligibility curation after creation, protocol fee, proxy, sweep key or admin.

Leaf commitment is domain-separated over chain, instance, campaign id, index, account and amount. Publish the dataset/algorithm and root before requesting claims; the wallet checks the leaf locally. The issuer still chooses the initial eligibility set. This is an allocation product, not a protocol's assertion that someone deserves a reward or is a unique person.

`claim(campaign,index,account,amount,proof)` accepts only a live campaign, index below leafCount, positive amount, bounded canonical proof and unconsumed bit. Set the bit and deduct remaining backing before exact transfer **to account**, regardless of submitter. Full rollback restores both if transfer fails. No caller-selected substitute recipient, external order signature or ERC-1271 path is needed. A compromised relayer can delay the claim, not redirect it.

The root proves membership, **not correct total funding, unique people or honest initial allocation**. An issuer can publish an underfunded or duplicate/incorrect dataset; require independent sum/uniqueness/recipient review before product use. All aggregate-budget caps are checked, but no claim is made that an ordinary Merkle root proves the sum. A Merkle-sum format would be a separately priced audited option, not silently present here.

After deadline, anyone closes a campaign and delivers remaining funds to its immutable refund recipient. A campaign with remaining zero may close earlier. Close clears campaign root/metadata only after its claims are permanently disabled; ids below the persistent high-water mark can never be recreated. Failed refund transfer preserves the campaign/right to retry. A refund receiver is a user-selected residual beneficiary, not a fee-collecting platform administrator.

Once a campaign is closed, anyone prunes up to eight bitmap words per transaction. Live campaign bits are never pruned, even after every visible wallet has claimed. Old logs and uploaded receipt proofs do not reopen a campaign or replace its replay state. Abandoned claims remain funded until the agreed deadline, then obey the published refund policy; no late grace is invented.

## Storage and retention

Proposed packing, subject to compiler confirmation; all asset amounts and aggregate outstanding must fit `uint128`.

| Word | Fields | First occupation |
|---|---|---:|
| M0 | `uint64 nextCampaign; uint64 brakeSince; uint128 outstanding` | 100 u at deployment, nextCampaign starts at one |
| Campaign C0 | `bytes32 root` | 100 u per live campaign |
| Campaign C1 | `address refundRecipient; uint64 deadline; uint32 leafCount` | 100 u per live campaign |
| Campaign C2 | `uint128 remaining; uint128 initiallyFunded` | 100 u per live campaign; initiallyFunded keeps the word nonzero |
| `used[campaign][word]` | `uint256 bitmap` | 100 u for each first occupied 256-index word |
| Token state | Instance/recipient/refund holder and retained allowance slots | 100 u per zero-to-nonzero word |

There is no per-recipient contract balance, claimed-amount map, on-chain leaf list, participant array or history counter. Campaign rights stay in C0–C2 and the bitmap until close. Bitmap cost is **0.390625 u per claim only when all 256 bits in a word are exercised**; a sparse cohort can pay 100 u for one claim. Completed campaign/root clearing and pruning refund no burned state fees. Code and all claim proofs/envelopes are priced too. [ES1](../SOURCES.md#es1).

## Signature sequence and hidden plumbing

Issuer: one funded P-256 approve/create/reset batch; publish the leaf dataset to independent mirrors and export it locally. Recipient: wallet obtains proof, confirms asset/amount/deadline and submits one funded batch. Anyone else can pay a direct transaction with the same proof to the same recipient; proof possession is not authority to redirect money. Existing original claims also allow this.

No typed order signature, NFT hook, arbitrary-call session or 1271 is required. Added-owner relay can cover the canonical fee after funded setup; true zero-DBLN first-use sponsorship remains gated on native fee settlement. If all sponsors refuse, the wallet gives actual self-funded cost and another payer choice. [ES2](../SOURCES.md#es2), [sponsorship](../sponsorship/DESIGN.md).

The recipient sees “You can receive X”, “Claimed”, or “This allocation ended”; the wallet handles proof/bitmap/fee-budget details. Deadline, wrong allocation, missing evidence and sponsor refusal remain visible. Names do not change eligibility or human uniqueness. The wallet retains certified payment evidence and campaign metadata before query pruning. [ES7](../SOURCES.md#es7).

## Illustrative exact action ledger

`H(E,O,L)=ceil((E+128+O+L)/32)`; **layout/byte estimates**, not test results. Standard ERC-20 Transfer/Approval is 192 B; account `Executed` is 128 B. `CampaignCreated(id indexed,creator indexed,root,funding,deadline,count,refundRecipient)` has three topics/five data words = 320 B. `Claimed(id indexed,index indexed,account indexed,amount)` has four topics/32 data B = 224 B. `Closed(id indexed,refundRecipient indexed,amount)` and `Pruned(id indexed,start,count)` are 192 B each.

| Action / existing initialized caller | New final words | Chosen E/O/L | Estimated U |
|---|---:|---|---:|
| Create, instance token holder already nonzero | 3 campaign words | 768/0/1,024 | 360 |
| First create after token instance balance is zero | 3 campaign + 1 token holder | same | 460 |
| Claim, bitmap word already occupied, recipient token balance nonzero | 0 | 1,536/0/544 | 69 |
| First claim in a bitmap word | 1 bitmap | same | 169 |
| Claim to zero recipient token balance | +1 token holder | same | +100 |
| Close with zero remaining backing | 0; three campaign words clear | 512/0/320 | 30 |
| Close with a positive refund to warm holder | 0; three words clear | 512/0/512 | 36 |
| Prune eight closed-campaign bitmap words | 0; up to eight clear | 1,024/0/320 | 46 |
| Invalid/replayed/expired proof | 0 app growth | 1,536/128/0 | 56 |
| Permissionless entry-brake latch | 0; M0 remains occupied | 512/0/288 | 29 |

Fresh sender nonce accounts add 100 u; this ERC-20-only fixture creates no native receiver account. Actual ABI proofs, signature envelope and extra token events replace the chosen lengths. A direct third-party transaction can omit `Executed`; calculate its actual single H instead of adding a second whole transaction meter.

Deployment illustration: C=6,000 runtime B, one contract account, M0, E=8,192/O=0/L=160 gives **6,465 u**. Extra factory/source code is not bundled free.

Full cohort: one 4,096-recipient campaign; pool token balance initially zero, sender accounts initialized, all recipients' token balances nonzero; every index claimed, sixteen bitmap words, one zero-remainder close and two eight-word prunes. `6,465+460+4,096*69+16*100+30+2*46 = 291,271 u`, **71.111084 u per completed entitlement** including this instance's code/close/cleanup. First token holders add 409,600 u: **700,871 u / 171.111084 u each**. Original bitmap is the same packing control; much of the cold cost is token state, not the proof contract.

State-only full-refill ceilings are `floor(2,764,800/71.111084)` warm or `floor(2,764,800/171.111084)` fresh-holder entitlements/day. The first full cohort burns **0.291271 DBLN** at the state floor and needs at least `ceil((291,271-100,000)/32)=5,978` refill heights beyond an initially full bucket. At 10% refill use one tenth the shared allowance; archive proof bytes, exec/prove gas and bitmap/token contention can bind earlier. Failed claims and unpublished proofs reduce actual completed output. [B5 method](../MEASUREMENTS.md).

## Failure, MEV, immutability and brake

A copied public proof can only advance the same fixed payout; one bit prevents duplicate payment. There is no random draw or auction, so encryption is unnecessary. Inclusion may still miss a deadline, and racing the final available backing matters for an underfunded root. Fast finality does not repair allocation correctness or evidence availability. Finite claiming/refund is worse for late recipients than an indefinite original; benchmark that tradeoff explicitly.

`brakeState()` reports zero guardian. New campaigns stop on a pinned-token identity change or actual token balance below aggregate outstanding; anyone can latch permanent entry closure. Claims/refunds remain callable only when exact transfers preserve backing of all other campaigns. A global deficit can make payouts fail until voluntary recapitalization; there is no haircut, bailout or privileged drain. Token issuer/proxy behavior may freeze funds even with a fixed facade hash. The publisher may withhold proofs, a relay/committee may censor, and the initial allocator may choose wrong recipients; none has a root-edit key or power to redirect a valid claim.

## Tests and original comparison

Pin Uniswap MerkleDistributor version/compiler/licence and the toolbox campaign. Compare one versus 1/100 repeated campaigns under identical asset, eligibility, deadline and account batching; separately price native shared-code contention and the original's simpler immutable-per-campaign state. Include sparse bitmap occupancy, fresh holders, expired partial campaigns and unavailable mirror data.

Tests: concurrent creators and expected-id mismatch before funding; leaf domain/index/depth; recipient binding; duplicate/cross-campaign proofs; zero/fresh bits; underfunded/duplicate dataset disclosures; conservation, donations and allocation overflow; close-before-prune, high-water id overflow and no campaign resurrection; fixed refund and transfer failure; reentrancy; bitmap cleanup without rent/burn refund; aggregate-backing brake; account relay and sequential/parallel receipts. Run every success/failure lifecycle through [MEASUREMENTS](../MEASUREMENTS.md); actual exec/prove gas, envelope sizes, throughput and superiority remain **TO MEASURE**.

Potential win: shared code, finite reusable campaign infrastructure and wallet-local entitlement/payment evidence. Worse: campaign storage, global token-balance contention, finite claim deadlines and bounded proof size. For a single durable allocation, the original may be the better contract and native wallet/proof UX the only required change.
