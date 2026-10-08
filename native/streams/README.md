# B1 Streams and vesting: receive already-funded pay when it is earned

Status: **implementation, unaudited, not deployed, not measured on the EastSea executor.** The design is in [DESIGN.md](DESIGN.md). The rules from [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md) apply. This code is provided AS IS for testing and benchmarking, like the rest of this repository. Whoever deploys or uses it is responsible for doing so.

## The person's problem

A contributor wants predictable access to pay they have earned, instead of waiting for the next spreadsheet reconciliation and multisig payroll run. A grant recipient wants a vesting promise that the grantor cannot quietly revoke. The task is knowing what money is available and receiving it, not sending a transaction every second ([Sablier payroll article, 2025-08-15](https://blog.sablier.com/how-to-automate-crypto-payroll-in-your-dao-or-startup-without-a-cfo)).

**Pick the right layer first.** Ordinary pay, or a capped repeating transfer, is an *account/wallet* task (A3 payment sessions). It needs no new contract. This contract exists only for money that is **already funded** and becomes the recipient's over time.

## What this contract does

`GrantLedger` ([src](src/GrantLedger.sol)) is **one shared immutable instance per exact-transfer ERC-20** holding many grants:

| Action | Who | Effect |
|---|---|---|
| `create({beneficiary,total,start,cliff,end})` | anyone | Pulls exactly `total` and stores 2 words. The creator keeps **no** authority. |
| `createBatch(≤8 grants)` | anyone | One exact pull of the sum. The whole batch reverts if any entry is invalid. |
| `claim(id)` | anyone | Pays `earned(now) - released` to the fixed beneficiary. Reverts if that is 0, so a success always moved money. The final payout deletes both words. |
| `earnedAt(id,t)`, `claimable(id)` | view | The wallet's "Available now" and "Fully available on …". |
| `tripBrake()` | anyone, only while the predicate holds | Permanently closes `create`. `claim` stays open. |

Schedule: `0` up to and including `cliff`. Then `floor(total·(t−cliff)/(end−cliff))`. Then `total` from `end` on. `start ≤ cliff < end`, all `uint32` seconds (through 2106-02-07). `t` is the full `block.timestamp`, never wrapped. `start` is recorded for display only: **accrual runs cliff to end, with no catch-up at the cliff.** A start-to-end curve with a withdrawal lock is a different schedule.

**No overflow on large grants.** `total < 2^128` and `t−cliff < 2^32`, so the product stays below `2^160`. The regression test `test_schedule_maxGrantNoOverflow` uses `total = 2^128−1` over the full `uint32` range and claims after 2106. This is the class of bug found in TokenVesting on 2026-10-06. The fuzz test `testFuzz_earnedMonotoneBoundedFloor` covers the whole range.

**No cancellation.** This instance has no cancel, revoke, clawback or sweep, and a test calls those selectors to check that they do not exist. Salary that can be terminated is a different product: use payment sessions or shorter grants. It is not a hidden employer veto over funded money. Grants are not transferable: the beneficiary is fixed at creation.

## Wallet flow (P-256 account, existing A1 batch)

- Employer: one batch `approve(exact) → create/createBatch → approve(0)`, one prompt. The UI shows "This grant cannot be recalled."
- Recipient: the wallet reads `claimable` for free. One batch, one prompt, to claim. A friend or relayer can pay for `claim(id)` and the money still goes only to the beneficiary. A payment session **cannot** call `claim` today (A3 limit).
- The UI's accrual counter is a display. Nothing is paid until someone calls `claim`.

## Better on EastSea, and worse

**Possibly better (to be measured):** one shared runtime (6,681 B in Foundry) for many grants, instead of the toolbox's one-runtime-per-grant [`LinearVesting`](../../contracts/src/lock/LinearVesting.sol) or a per-stream NFT. 2 words per live grant, deleted at the final payout. Explicit non-revocation. No protocol or UI fee in the contract. Exact-transfer checks on both legs. A deterministic brake with no keyholder.

**Worse or unchanged, stated plainly:**
- No open-ended or top-up streams (Sablier Flow does both), no cancellation (Lockup can be cancelable), no transferable stream NFT, and no other curve shapes (Lockup dynamic/tranched). Sablier's richer products and tooling may solve the actual task better.
- Abandoned grants keep their two words and their funds **forever**. There is no expiry that confiscates vested money.
- One shared balance: a deficit (issuer seizure, rebase down) blocks every payout until someone tops up the instance.
- Withdrawing is still a transaction. A sponsor-paid claim needs a real funded relayer, and native sponsorship is gated (G5/G6).
- Clearing words refunds no burned state fee.

## Head-to-head test plan (to run with the executor recorder)

Controls: Sablier Lockup Linear (with a cliff, same curve: check Lockup's cliff semantics and report any curve mismatch as a capability difference, not a cost difference), Sablier Flow (open-ended; list its extra capabilities), and the toolbox's `LinearVesting`. All run on the same EastSea genesis and the same P-256 batch wallet.

| # | Scenario | Record |
|---|---|---|
| H1 | 1 grant, cliff + 4 claims including the final one | total u, u per claim, exec/prove gas |
| H2 | 100 grants (first create, then 99 more), 4 claims each, warm holders | u/grant (design estimate 469.65 u) |
| H3 | H2 with fresh beneficiary token balances | +100 u per holder on every path |
| H4 | 1 / 100 / 1,000 grants | code amortization, break-even against a per-grant deploy |
| H5 | batch of 8 vs 8 single creates | prompts, envelope bytes, u |
| H6 | abandoned grant (never claimed) | retained words on each path |
| H7 | relayed claim | recipient binding, relayer cost |
| H8 | rejected claim (nothing yet / unknown id) | failed-attempt u and fee |
| H9 | issuer freeze / deficit | brake latch, blocked exits, recapitalisation |
| H10 | cancel-required payroll | **native unsupported**: report a Lockup-cancelable win |

## Files

- `src/GrantLedger.sol`
- `test/`: unit (`GrantLedger.t.sol`), fuzz (`GrantLedgerFuzz.t.sol`), invariants (`GrantLedgerInvariant.t.sol`).
- [SECURITY.md](SECURITY.md), [GAS.md](GAS.md).

```bash
cd native && forge test --match-path 'streams/*'
```

## Personal test instance: testnet and mainnet

<!-- i18n: personal_test.title personal_test.testnet personal_test.mainnet personal_test.accounts personal_test.local personal_test.fees personal_test.caps -->

Testnet permits shared demonstrations with test coins. Mainnet permits only
your own private, allowlisted, capped instance: deploy from your EIP-1193
wallet through `PersonalTestDeployer`, whose constructor fixes your native
and aggregate token caps. Its `deploy(bytes,bytes32)` atomically initializes
this contract's existing constructor ABI and marks it `personal-test`.
Only the deploying wallet starts allowed. Add only other accounts you own,
and use those accounts for every party, beneficiary, signer and recipient.
Personal mode charges no protocol fee and adds no administrative withdrawal.

The 17-app publisher does not invent a deployment recipe or shared frontend
for this native example. Use the
[generic native deployment interface](../../docs/personal-mainnet-testing.md#native-contracts)
with its locally built creation bytecode, own test assets, fixed caps and
wallet-approved calls. Run `cd native && forge test` locally before doing so.
Do not deploy from a company key or host a shared mainnet interface. Caps
are raw asset base units, not a dollar valuation; unsolicited external
transfers cannot be prevented at the receiving contract. The [policy](../../docs/personal-mainnet-testing.md)
describes exits and those limits. Stable [English translation keys](../../docs/i18n/personal-test.en.json)
are ready for the language pack.
