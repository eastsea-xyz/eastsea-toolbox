# B2 Escrow: agree first, hold the funds, then release them

Status: **implementation, unaudited, not deployed, not measured on the EastSea executor.** The design is in [DESIGN.md](DESIGN.md). The rules from [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md) apply. This code is provided AS IS for testing and benchmarking, like the rest of this repository. Whoever deploys or uses it is responsible for doing so.

## The person's problem

A buyer paying a stranger risks losing the payment before anything useful is delivered. A seller who works first risks never being paid. Before escrow, one of them had to trust the other, or both had to hand custody and dispute power to an intermediary ([Kleros Escrow](https://docs.kleros.io/products/escrow)). This contract is for delivery that **cannot** happen atomically on-chain, such as work or goods. For a swap of on-chain assets, an atomic exchange such as Seaport is the better tool. A receipt or a terms hash never proves that a parcel arrived.

## What this contract does

`EscrowBook` ([src](src/EscrowBook.sol)) is one immutable instance with a fixed asset (`address(0)` = native DBLN, or one exact-transfer ERC-20), an **optional fixed arbiter** and its ruling window, and a public specification hash. People choose an instance. Nobody chooses a mediator for them, there is no protocol fee, and there is no owner, proxy or rescue key.

| Step | Who | Rule |
|---|---|---|
| `create(seller, amount, acceptBy, deliverBy, policy, termsHash)` | buyer | Exact funding. `now < acceptBy < deliverBy`, terms hash nonzero, and the arbiter cannot be a party. |
| `accept(id)` | seller, before `acceptBy` | Acceptance is a transaction, not a hook. |
| `cancel(id)` | buyer any time while unaccepted; **anyone** from `acceptBy` | Everything goes back to the buyer. This covers a seller who never shows up. |
| `release(id)` / `refund(id)` | buyer / seller | Pays everything to the other side. Also ends a dispute. |
| `propose(id, sellerAward)` → `acceptProposal(id, round, award)` | either party → only the other one | A split. A new proposal replaces the old one, and a stale round or award is rejected. |
| `dispute(id)` | either party, before `deliverBy`, arbiter instances only | Sets `rulingBy = now + rulingDuration`. Only one dispute per deal. |
| `rule(id, sellerAward)` | the arbiter, before `rulingBy` | Can only split between the two fixed parties. It cannot extend the deadline or pay itself. |
| `resolveTimeout(id)` | **anyone**, from `deliverBy` (or `rulingBy` if disputed) | Applies the silence policy both parties agreed to: `BUYER_REFUND` or `SELLER_PAYMENT`. |
| `pay(id, toSeller)` | **anyone** | Pulls one party's award to its fixed address. A zero award is consumed at resolution. The record is deleted after both payouts. |
| `tripBrake()` | anyone, only while the predicate holds | Permanently closes `create`. Every other step stays callable. |

A deal resolves exactly once. All later resolution paths revert, so a voluntary settlement makes any later ruling impossible.

## The silence policy is the honest core

No permissionless timeout protects both sides. `BUYER_REFUND` lets a dishonest buyer keep delivered work. `SELLER_PAYMENT` lets a dishonest seller get paid without delivering. The wallet must show the chosen policy as plain words before either person signs: "If nobody acts by 12 Oct, **Sam gets the 100**" or "…, **you get the 100 back**". An arbiter instance swaps that risk for the arbiter's honesty and liveness. An absent arbiter falls back to the same policy.

## Wallet flow (P-256 account, existing A1 batch)

Buyer: one batch `approve → create → approve(0)` (or a single `create` with value for DBLN). Seller: `accept`. Buyer: `release`. Then anyone, often the seller's wallet, calls `pay`. That is three decisions by the parties and up to four transactions. A split adds a proposal and an acceptance. A dispute adds the dispute call and the arbiter's ruling. No typed signatures, ERC-1271, NFT hooks or sessions are needed. Names resolve once to an address, and the wallet shows that address.

## Disappeared counterparty and failed transfers

- Seller never accepts: anyone can `cancel` from `acceptBy`, and anyone can `pay` the buyer back.
- Seller vanishes after accepting: the silence policy applies at `deliverBy` (with `BUYER_REFUND`, the buyer gets the money back).
- Buyer vanishes after accepting: the silence policy applies (with `SELLER_PAYMENT`, the seller gets paid). The buyer's own award can be paid out by anyone, to the buyer.
- Arbiter vanishes: the silence policy applies at `rulingBy`.
- A recipient's transfer fails (blocklisted, reverting contract): only **that** payout reverts. The right is kept, and the other party's payout is unaffected.

## Better on EastSea, and worse

**Possibly better (to be measured):** a small bilateral record (4 words, plus 1 only if someone proposes a split) that is deleted after payout. No compulsory dispute provider. Explicit silence policy and deadlines. Anyone can trigger timeouts and payouts, so a wallet or friend can finish a deal for someone who has gone offline. Exact-transfer on both legs. A deterministic brake with no keyholder.

**Worse or unchanged, stated plainly:**
- Kleros already has zero platform fees, negotiated settlement and permissionless timeouts. Claim no fee advantage over it. Kleros wins for people who need juror selection, evidence and appeals. This contract has a single fixed arbiter or none.
- A fixed arbiter can rule dishonestly, collude with a party or ignore the dispute. It cannot touch other deals.
- Immutable: mistakes cannot be patched, and a frozen or confiscating token can block every exit.
- Deadlines are wall-clock (`block.timestamp`). Censoring a transaction until a deadline passes changes the outcome, and fast finality does not prevent that.
- Terms are only a hash. Both wallets must export the agreement text, because the chain does not keep it.

## Head-to-head test plan (to run with the executor recorder)

Controls: Kleros Escrow (pin V1/V2 and their licences) for delivery tasks; Seaport 1.6 **only** for the separate atomic digital-swap task. Use the same EastSea genesis and the same P-256 batch wallet for the original and the native contract.

| # | Scenario | Record |
|---|---|---|
| H1 | create → accept → release → pay (warm balances) | total u (design estimate 539 u), prompts, exec/prove gas |
| H2 | H1 with a cold book and a fresh seller balance | +100 u per new holder |
| H3 | negotiated split: propose → accept → 2 payouts | S4 occupancy, u |
| H4 | dispute → ruling → 2 payouts; dispute → absent arbiter → timeout | arbiter cost; Kleros's fee and evidence steps |
| H5 | seller never accepts → lapse → refund | who can finish it, u |
| H6 | silence: both policies after `deliverBy` | outcome, u |
| H7 | blocked recipient; reverting native recipient | the other payout is unaffected |
| H8 | 1,000 completed deals with fresh seller balances | lifetime u/deal (design estimate 647.1) and B5 ceilings at 10/50/100% |
| H9 | atomic NFT-for-token swap | **Seaport wins; native is not the right tool** (reported as such) |
| H10 | deficit / issuer freeze | brake latch, exits blocked until recapitalised |

## Files

- `src/EscrowBook.sol`
- `test/`: unit (`EscrowBook.t.sol`: create, flow, arbiter, native, brake), fuzz (`EscrowBookFuzz.t.sol`), invariants (`EscrowBookInvariant.t.sol`).
- [SECURITY.md](SECURITY.md), [GAS.md](GAS.md).

```bash
cd native && forge test --match-path 'escrow/*'
```
