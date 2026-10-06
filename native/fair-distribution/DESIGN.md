# Fair distribution: an actual item for a published entitlement

Status: design, 2026-10-06; **Lane B, P1 deterministic entitlement; P2 randomized variant blocked**. Inherits [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md). All costs below are planning estimates, not measurements; exec/prove gas remain unknown.

## The problem before the mechanism

A creator needs affordable issuance and a buyer wants a reliable opportunity to receive a scarce item, rather than repeatedly pay to race a mint. ERC721A's team reports 8,700 public-sale tokens minted within minutes on 2022-01-12; Metaplex reports Candy Machine minted 78% of Solana NFTs by September 2022. These are demand/mint counts, not unique humans. [ERC721A README](https://github.com/chiru-labs/ERC721A), [Metaplex overview, checked 2026-10-06](https://www.metaplex.com/docs/smart-contracts/candy-machine).

Batch mint efficiency is already solved well by ERC721A. It does not establish who deserves a scarce item. Metaplex's bot-tax docs warn that ordinary wallet-injected Lighthouse instructions can trigger penalties, and an invalid mint may appear successful while charging a penalty and issuing no NFT. Native UX must show actual ownership or an unchanged claim, never relabel a rejected buyer as a successful mint. [Metaplex Bot Tax Guard, checked 2026-10-06](https://www.metaplex.com/docs/smart-contracts/candy-machine/guards/bot-tax).

Best layer: **a small contract for funded entitlement and settlement; the wallet for approval, receipt and failure explanation**. A wallet cannot promise inventory it does not hold. Native accounts can batch approval/claim, but originals must receive the same account batching benefit in comparisons.

## Deterministic funded instance

One immutable instance pins one ERC-721 collection/code identity, one exact-transfer payment token, seller/payment recipient, unit price, opening/expiry heights and a fully enumerated list of **1–64 unique recipient accounts and unique uint128 token IDs**. Each account receives exactly its named item; no external Merkle root, publisher tally or asserted allocation sum substitutes for the on-chain list. The public table is the issuer's explicit allocation offer, not a proof of permissionless fair selection.

Validate uniqueness, widths, checked `count*price` and all deadlines when creating the instance. There is no proxy, rule setter, fee recipient, founder key or platform curator. Seller chooses whom to offer its own inventory to before deployment; nobody can amend those offers after deployment. A per-account entitlement is not one human, one chance.

State machine: `Unfunded → Open → Closed`, with `Unfunded → Expired` if inventory never arrives. `fundAndOpen` requires Unfunded, not latched, a matching collection identity and height before expiry; it may fund before openHeight while claims still wait for that height. Anyone may submit it using the seller's explicit collection approval; transfer at most 64 listed items and verify each owner is this contract. Every transfer and activation must succeed atomically. Missing inventory while Unfunded is expected, **not an integrity fault or permissionless permanent brake trigger**. Payment entry is forbidden until the entire named inventory is held. A missing seller/approval therefore creates no paid buyer obligation.

In Open, `claim` requires `openHeight <= height < expiryHeight`, the entitled account as caller, the named item still in custody and the fixed exact payment; write claimed state, pull payment **directly from that caller to the fixed seller/payment recipient** with exact balance-delta checks and safe-transfer the item atomically. The price is one ERC-20 Transfer; no intermediate payment-holder word or second price-transfer event is omitted from the ledger. There is no arbitrary destination argument. On transfer/payment failure the whole claim rolls back, including price and consumed entitlement; network fees remain payable. V1 has no paid reservation, no lottery entry charge and no separate buyer deposit to refund.

After expiry, anyone closes entry without consulting the seller. The seller may reclaim only items whose entitlement was never exercised before expiry; the original claim window is a disclosed term. Already transferred items are never recalled. Closed records retain a terminal status/identity so old calls cannot revive the sale; at most eight already claimed or reclaimed row records may be pruned per transaction. Unreclaimed inventory rows retain the seller's recovery right. Abandoned inventory remains withdrawable by the immutable seller, with no third-party sweep right.

Collection safe-receiver support is required in this escrow template. **Buyer EastSeaAccount ERC-721 receiver hooks are PENDING A4/G2**; do not enable sales to delegated accounts until runtime hooks are verified. ERC-1271 is unnecessary for direct account calls; signed claim authorizations are not in v1. Existing payment sessions do not authorize these app calls. [Account boundaries](../PRIMITIVES.md).

## Packing and priced lifetime

Proposed packing, to be verified against actual compiler layout:

| Word | Proposed fields | Occupation |
|---|---|---:|
| S0 | `uint64 openHeight; uint64 expiryHeight; uint16 count; uint16 outstanding; uint8 phase; uint8 brakeFlags; uint64 brakeSince; uint16 tag` | 100 u once; nonzero tag |
| `entitlement[account]` | `uint128 tokenId; uint8 statusPlusOne; uint120 reserved` | 100 u per row, even tokenId zero |
| `recipient[index]` | packed storage-array address, 160 bits; two addresses do not fit one word | 100 u per recipient + 100 u array-length word |

Index enumeration is needed for complete funding and abandoned inventory recovery. No mapping's absent value is interpreted as a free entitlement. Runtime immutables cost code bytes. All paid allocations remain in the lifetime bill even if later deleted; deletion refunds no burned persistence fee or B5 capacity.

`H=ceil((E+128+O+L)/32)` includes the canonical signed envelope, output and **all** receipt events, including the account and external tokens. Illustrative warm account batch `E=768 B`, `O=0`; `Executed=128 B`, each ERC-20/ERC-721 Transfer or Approval event `192 B`, distribution event `192 B`. No EVM output/state units from an external collection are silently included in the application row estimate.

| Action | New application words | Illustrative H | U before external new state |
|---|---:|---:|---:|
| Approve payment and claim one item | 0 | `(768+128+128+3*192+192)/32=56` | 56 u |
| Failed claim, all calls reverted | 0 | `ceil((768+128+128)/32)=32` with O=128 B | 32 u |
| Close expired instance | 0 | `ceil((768+128+128+192)/32)=38` | 38 u |
| Reclaim one expired, unclaimed item | 0 | `ceil((768+128+128+192+192)/32)=44` | 44 u |

Claim can additionally occupy a seller payment-holder word (100 u when first nonzero) and recipient NFT-balance word (100 u); a fresh canonical payer adds 100 u. An exact allowance set and fully consumed inside one atomic batch ends zero and costs no newly occupied slot, although approval execution/events still cost. A retained allowance adds 100 u only if nonzero in final state. The fixture assumes ordinary ERC-721 owner words were already materialized; those owner/approval words normally update/clear. **ERC721A lazy ownership can materialize additional owner words during funding/transfers**, and these plus any collection-specific extra indexes must be measured instead of borrowing this baseline count. Reclaim similarly charges a newly occupied seller NFT balance and any collection-specific indexes. Token transfer events do not create native recipient accounts by themselves.

Illustrative deployment: runtime `C=6,000 B`, signed creation envelope `E=12,288 B`, initialization log `L=192 B`, two global words plus `2N` rows/list words, and one contract account: `D=6,000+100+100*(2+2N)+394`. At N=64, **D=19,494 u**. Code size/init envelope are assumptions, not benchmark outputs; the ERC-721 contract's own deployment/mint is excluded only in the explicitly pre-existing-collection cohort.

Funding example: `E=1,024 B`, one seller Approval, 64 NFT Transfers, account Executed and activation events gives `H=ceil((1,024+128+192+64*192+128+192)/32)=436 u`; fresh operator approval and escrow NFT balance each add 100 u, hence **636 u**. This assumes one collection operator-approval word; per-item approvals or extra escrow owner/index state add their actual delta. Collection issuance/funding gas remain unknown.

Warm complete 64-claim sale, with pre-existing recipient/seller holder balances and exact temporary payment approvals, then close and eight cleanup calls at 38 u each: `19,494+636+64*56+38+8*38 = 24,056 u`, **375.875 u/completed item**. A cold-holder cohort adds `64*100 NFT balance+100 seller payment balance = 6,500 u`, total **30,556 u / 477.4375 u/item**. Fresh payers, retained allowances, NFT issuance, collection deployment, retry costs and nonstandard indexes are additional named cohort costs.

At 100% of shared B5 refill, state-only bounds are approximately **7,355 warm or 5,790 cold items/day**, divided by two/ten at 50%/10% allocation. Entire-sale floor state fees are **0.024056 / 0.030556 DBLN**, plus exec/prove/tips. Warm lifecycle consumes about 752 heights of refill; cold about 955. Inventory abandonment replaces claims with reclaim/cleanup costs rather than making them free. Archive payload, exec/prove, 512-new-slot/block cap and contention can bind earlier; these are not achieved TPS.

## Consent, brake and gated randomness

Creator setup includes publishing the full table, deployment, collection approval and funding; count each signature/transaction before amortizing. Funded buyer opens the fixed offer and confirms one P-256 batch containing payment approval plus claim. Repeated approval may be unnecessary but must be accounted separately. A relayer using existing added-owner `ownerExecute` can pay after funded setup; native sponsorship/zero-balance first use is not delivered. Wallet displays the actual item, all-in price estimate, expiry, beneficiary and success ownership; hide standards, not those terms.

`brakeState` reports guardian zero. **Claims** check Open, not expired, inventory ownership, pinned code identity and exact-payment conditions; funding uses its separate Unfunded guard above. Inventory-integrity checks apply only after successful funding, to unexercised/unreclaimed Open/Closed obligations: empty Unfunded inventory cannot trip a latch, and a correctly claimed NFT belonging to its buyer is not an escrow shortfall. Any no-argument whole-instance inventory view loops over at most the immutable 64 rows, with the same bound enforced in execution. Anyone can persist a justified deterministic code/inventory violation through a nonreverting `tripBrake`; a failed claim cannot be relied on to persist a flag. A latched integrity brake closes new claims, preserving seller recovery after the originally pinned expiry. It cannot claw back claimed NFTs or release somebody else's item early. Issuer-frozen tokens/corrupt collection behavior can still defeat transfers; no admin rescue promises solvency or honest assets.

Fixed entitlements remove the race for another account's inventory, not committee inclusion censorship, buyer-key theft, issuer quality risk or public transaction ordering. Seller has no post-Open stop key but the chosen collection/payment issuer may freeze/change behavior; relayers/frontends can refuse service; validators may exclude claims before expiry. Recipients retain direct calls and exported terms, not an archive's claim authority.

Optional RANDOMIZED allocation is **blocked on R3 SDK compatibility and G4 an enforceable on-chain close-before-signing cutoff**, neither supplied. Require fully recorded eligible entries, bounded verifiable selection and independently available encrypted data before accepting money. `randomness(epoch)==0` proves no secrecy; epoch is not draw; a seed hash is not a raw BLS signature; signing can precede epoch opening. No organizer root, favorable-seed choice or predictable fallback may determine winners. Missing prerequisites/seed must yield the specified deposit refund, never silently substitute a seed; algorithm/economics remain a release gate, not a v1 promise.

## Original wins and verification

Potential improvement is explicit funded item rights and atomic visible success without bot-tax disguises; superiority is unproven. Worse: only 64 named recipients, public allocation, upfront inventory/paid state, no open public lottery or multi-rule minting. ERC721A can win on batch issuance/storage; Core Candy Machine has broader guards and creator tooling. Pin their exact versions and compare equal inventory, token behavior, cold/warm holders and P-256 batching, including separate upfront issuance and the removed capability. [ERC721A](https://github.com/chiru-labs/ERC721A), [Core overview, updated 2026-03-10](https://www.metaplex.com/docs/smart-contracts/core-candy-machine/overview).

Required tests: duplicate recipient/item, zero/max ID, premature Unfunded brake rejection, full missing-inventory rollback, normal claimed items excluded from inventory faults, exact-price/overflow, wrong caller, failed account hook/payment/issuer transfer, reentrancy, expiry boundary, stale old claims after pruning, partial/all abandonment, deterministic brake, absent seller/frontend, cold balances, funding/claim conflicts and sustained B5. Random variant additionally needs pre-signing cutoff proof, withholding/early-signing and refund conservation tests before design approval. Run [the common head-to-head method](../MEASUREMENTS.md); publish original wins and all unsupported outcomes.
