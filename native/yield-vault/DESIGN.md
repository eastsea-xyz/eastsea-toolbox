# Yield vault: an understandable claim on an actual source of returns

Status: design, 2026-10-06; **Lane C, P2**. **No native staking yield exists in the inspected chain.** Live release needs a funded or economically productive, selected source; a mock share-price increase is not yield. Inherits [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md).

## The user's problem

A saver wants to pool money into a return-producing activity, understand what can lose it, and withdraw their share without maintaining a portfolio of integrations. ERC-4626 standardizes those deposit/share/redemption interfaces; Yearn's vaults allocate assets to strategies that actually generate returns. A receipt token and a rising demo price do not establish a business model or a repayment source. [ERC-4626, created 2021-12-22](https://eips.ethereum.org/EIPS/eip-4626), [Yearn V3 management documentation, accessed 2026-10-06](https://docs.yearn.fi/developers/v3/vault_management).

Best layer: **wallet reuse of a suitable ERC-4626 source first**. Deploy the adapter below only when immutable source selection and bounded loss consent add a benefit the source lacks. If the original already supplies these, an extra wrapper is unnecessary paid state. [ES1, ES2](../SOURCES.md#es1)

## What changes, and what does not

Yearn V3 deliberately supports manager roles, adding/revoking strategies, changing debt allocation and withdrawal queues. Those powers are useful for adapting to changing markets; its documentation also warns that force revocation can realize losses and manipulated strategy conversions can misstate profit. A no-manager product sacrifices that flexibility instead of hiding it behind a different founder key. [Yearn V3 roles, losses and queues](https://docs.yearn.fi/developers/v3/vault_management).

ERC-4626 rounding and donation-related inflation are economic issues, not slow-block issues. The native adapter uses virtual assets/shares and explicit minimum output, but these are established defenses rather than an EastSea invention. A source's own conversion manipulation remains a separate risk. [OpenZeppelin ERC-4626 security guidance](https://docs.openzeppelin.com/contracts/5.x/erc4626).

EastSea contributes one P-256 batch for approval and deposit, transparent paid-state charges and a short nominal settlement cadence. The same batching benefit is available to an original that supports the on-chain path; no claim is made that finality removes source liquidity or credit risk. Sessions currently support payments only. [ES1–ES3](../SOURCES.md#es2)

## Native solution: one immutable source, with explicit loss consent

`SingleSourceVault` is an ERC-4626/ERC-20 share adapter for one exact-transfer underlying asset and one selected source. The source address, asset, code identity, fee disclosure hash, share precision offset, deposit ceiling and bounded interface are fixed in deployment code. There is no factory curator, strategy-switch function, manager, fee accountant, upgrade proxy or founder sweep.

The source must either earn real lending/other permitted income or distribute a pre-funded, bounded reward budget. Identify the payer, depletion date and repayment claim in the manifest. No native-staking, restaking, bridged yield, guaranteed APR or protocol subsidy is inferred from a token interface. **This requirement is not satisfied by current primitives alone.** [ES0, ES5](../SOURCES.md#es5)

Reject a mutable proxy as an immutable source unless its immutability is independently established; `extcodehash(proxy)` alone does not pin its implementation. A fixed bytecode contract can still depend on a mutable oracle/issuer or borrower default. The wallet displays those dependencies before deposit, and never auto-migrates when a better source appears.

State machine: `Empty → Active ↔ LiquidityLimited`; immutable identity/accounting failures latch `EntryBraked`. Complete redemption can return to Empty. The contract has no discretionary “loss report” and cannot make a source solvent.

Deposit flow:

1. Read the current realizable source claim using its pinned, bounded preview interface; verify the source asset and code identity.
2. Compute shares with explicit virtual assets/shares, e.g. offset six; require nonzero shares, minimum share output, deadline and deposit ceiling.
3. Pull the signed asset amount and check actual vault receipt equals that amount.
4. Deposit into the fixed source; verify returned shares against the actual source-share balance delta and the signed lower bound.
5. Mint native shares only after all checks pass. Every change is atomic; failed external calls mint nothing.

Tracked NAV is `accountedIdle + realizable(sourceShares)`, not an arbitrary manager's number. The selected source's preview can be stale, optimistic or manipulable; admissibility requires defining its semantics and defensively testing it, not asserting a generic preview is a proof.

Unsolicited underlying or source-share donations do not mint a donor claim. Account only tracked source shares; excess underlying remains excluded from deposit pricing. There is no central sweep recipient. If permanently stranded surplus matters economically, the source/adaptor design must be revised before deployment. Donations into the **source** can still change its share conversion; output bounds and its own defenses remain necessary.

Redeem flow: compute the current pro-rata claim, require the user's `minAssets` and deadline, burn only the authorized shares, redeem the necessary source shares, verify underlying delivery and transfer exactly the resulting assets. All-or-nothing rollback restores native shares if the source or asset transfer fails. A failed redemption is not silently converted into a zero-valued receipt.

V1 has synchronous redemption only; it cannot represent a locked or asynchronous source as instantly withdrawable. Such a source needs a separately designed request/claim queue and pricing model, or is unsupported. Standard `maxRedeem/maxWithdraw` reflect actual available liquidity, not the full accounting balance. [ERC-4626 withdrawal limits](https://eips.ethereum.org/EIPS/eip-4626).

## Storage and state units

Amounts and total supply are bounded below `2^128`; external source shares must fit before accepting a deposit. Layout estimates need compiler confirmation.

| Word | Fields / purpose | Newly occupied words |
|---|---|---:|
| V0 | `uint128 totalShares; uint128 accountedIdle` | One when an Empty vault first receives a deposit |
| V1 | `uint128 sourceShares; uint64 lastSyncHeight; uint8 brakeFlags; uint56 layoutTag` | One at deployment, with nonzero tag/height |
| `balance[holder]` | `uint256 nativeShareBalance` | One per newly nonzero holder |
| `allowance[owner][spender]` | `uint256 allowance` | One per retained allowance; absent for owner redemption |
| Underlying asset | User/vault/source balance and allowance words | Price from their actual committed deltas |
| Source shares | Source's `balance[vault]`, plus its internal accounting | At least one first-holder word; source-specific additional words are a release gate |

`sourceShares` updates V1 in place. Deleting balances or clearing V0 after full withdrawal does not refund paid-state fees. Reoccupying a zero balance in a later transaction costs 100 u again; “the address existed before” does not waive it. Source-share donations are not recorded as new native depositor rights.

No NAV history/checkpoint array is kept by the adapter. Events support wallet evidence; live shares, allowances, source claims and the brake stay in state. Every event is priced archive growth. [ES1, ES7](../SOURCES.md#es1)

## Signature and product sequence

Cold, funded user: inspect the source/risk and available withdrawal amount; authorize one P-256 `execute` batch containing an exact underlying approval and `depositBounded`; receive shares. An exact approval consumed to zero in this same batch adds no final occupied allowance slot, although its Approval event is charged. Warm deposit uses the same one approval.

Redeem to self: one P-256 batch/signature, with minimum assets and expiry. Transfers of share ownership are explicit user actions; they can create another holder word. No `ecrecover` permit is assumed. ERC-1271 is pending for generic signed app authorizations; current deposit/redeem paths do not need it. Arbitrary-call sessions and unattended strategy operation are not available. [ES2, ES3](../SOURCES.md#es2)

The user sees “Source”, “Can withdraw now”, “Worst amount you approve” and “This return is paid by …”. They need not understand ERC-4626, delegation or a storage slot. They must still understand asset issuer freezes, borrower/source loss, withdrawal waiting, source fees and subsidy exhaustion.

## Quantitative closed workload

The following is a **layout/byte estimate**, not measured performance. `H=ceil((E+128+O+L)/32)`; simple P-256 batch E=512 B, O=0, account `Executed`=128 B. All ERC-20 Transfer/Approval events are 192 B; ERC-4626 Deposit is 224 B and Withdraw is 256 B. [ES1, ES2](../SOURCES.md#es1)

For a closed illustration, select an already-funded plain ERC-4626 control whose global accounting and underlying holder words are already nonzero; only its new share-holder word is added on the wrapper's first deposit. This is an executor accounting control, **not evidence that the control earns live yield**. An actual lending/reward source adds its measured internal words/events/gas and allocated deployment cost.

| Action | Final new words in this workload | L, including account event | Estimated U |
|---|---|---:|---:|
| First deposit to Empty wrapper | V0 + native holder + source holder = 3 | Approval, 2 underlying Transfers, 2 share Transfers, 2 Deposits, account = 1,536 B | 368 |
| Another holder's deposit | native holder = 1 | 1,536 B | 168 |
| Existing nonzero holder adds money | 0 | 1,536 B | 68 |
| Owner redeem; underlying recipient already nonzero | 0 | 2 share Burns, 2 underlying Transfers, 2 Withdraws, account = 1,408 B | 64 |
| Owner redeem to zero/fresh underlying balance | underlying holder = 1 | 1,408 B | 164 |
| Share transfer to a new holder | native holder = 1 | Transfer 192 + account 128 = 320 B | 130 |
| Retained share allowance | allowance = 1 | Approval 192 + account 128 = 320 B | 130 |
| Brake latch / explicit sync | V1 update only | Status 160 + account 128 = 288 B | 29 |
| Failed bounded action | 0 application words | no surviving app logs; O=128 B | 24; + actual surviving nonce account additions |

Assume runtime **C=6,000 B**, deployment E=8,192 B and L=512 B including one initial fixed-source Approval, deployment event and account event. Contract account 100 u + V1 100 u + underlying maximum allowance 100 u + archive 276 u → **6,576 u**. C is a planning input; the source and any factory have separately charged code/accounts.

A full wrapper lifecycle with 100 previously funded users, partial-balance deposits that leave their underlying holder words nonzero, one first deposit, 99 further deposits and 100 redemptions costs `6,576 + 368 + 99*168 + 100*64 = 29,976 u`: **299.76 u per completed save/redeem workflow**. All source-local costs in this explicit control are included; a real source adds `D_source/cohort + Σ additional source U`, which must be published before quoting a live cost.

If every user deposits their entire token balance, the later redemptions reoccupy 100 holder words: **39,976 u / 100 = 399.76 u/workflow**. Fresh sender accounts, additional source checkpoints, retained approvals, failed attempts and new reward funders raise both totals.

State-only ceilings at nominal 1 s/height are approximately **9,223 completed workflows/day** for the first cohort and **6,916/day** for the full-balance cohort, at 100% shared refill; 50%/10% give approximately 4,611/922 and 3,458/691. Floor state fee is 0.00029976 or 0.00039976 DBLN/workflow, plus exec/prove/tips and disclosed source fees. Refill after the first whole lifecycle consumes at least `ceil(29,976/32)=937` finalized heights of capacity.

Two 512 B envelopes per workflow imply a generous canonical-archive ceiling of four workflows/height, before source transactions and protocol traffic. Use the minimum of all [limits](../MEASUREMENTS.md); source liquidity and shared-source conflict repair can bind first.

## Deterministic entry brake and real exits

`brakeState()` has guardian zero. Deposits are refused immediately on a pinned-code/asset mismatch, tracked idle balance shortfall, failed bounded source view, or an immutable deposit ceiling. Code/asset/idle-accounting faults latch permanently through permissionless nonreverting `tripBrake`; a failed deposit cannot both revert and persist its latch. Liquidity shortage and deposit capacity are reversible entry predicates, not an administrator pause.

The conservative entry rule can additionally require `source.maxRedeem(vault) >= tracked sourceShares`; its collateral utilization cost must be benchmarked. If that excludes the chosen lending source's normal behavior, choose a different disclosed rule/instance before deployment rather than changing it with a manager key.

Redeem/withdraw remains callable during an entry brake **when the source can deliver, the share owner authorizes the burn, minimum output is met and the underlying transfers**. There is no invented bailout, unconditional principal guarantee, forced market sale or pro-rata seizure of another holder's claim. A changed/failed source may make exit impossible; the UI says so explicitly.

Owners can spend their own shares; a selected source/borrower/oracle or token issuer can lose/freeze funds; committee inclusion and relayers can censor. The adapter's immutable code cannot replace the source or steal through an admin update. That removes one power while retaining economic/source trust. [ES1, ES2](../SOURCES.md#es2)

## MEV, comparisons and release gates

Minimum shares/assets and deadlines bound price deterioration; one-second finality does not remove ordering, donation effects at the source, liquidity races or delayed losses. Public deposits/redemptions remain visible. Timelock encryption is not required and cannot make synchronous ERC-4626 redemption solvent. [ES4, ES5](../SOURCES.md#es5)

Potential win: explicit immutable source choice and bounded consent, with no allocator key. Worse: extra share/allowance/code state, no strategy rotation, no asynchronous source support and often one additional wrapping layer. A well-configured original ERC-4626 source wins on cost; Yearn wins on adaptive multi-strategy allocation and richer operating controls. [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626), [Yearn V3](https://docs.yearn.fi/developers/v3/vault_management).

Compare direct source, pinned OZ ERC-4626 and pinned Yearn V3 to this adapter under identical yield source, assets, losses, source fees and P-256 batching. Report what is removed from Yearn's capabilities instead of comparing a one-source toy against a portfolio as though they were equivalent.

Tests: conservation/rounding across first/last deposit; donation and near-zero-output defenses; source preview dishonesty/failure; partial/full liquidity; source loss; token freezes/reentrancy/fee-on-transfer; source code/proxy assumptions; allowance clearing; all-or-nothing redemption; abandoned shares; brake without an admin; equal sequential/parallel roots. Record realistic source checkpoints, holder reoccupation and ≥10,000 finalized-height sustained cohorts.

Release gates: select and fund a real source; document its economic payer and withdrawal semantics; verify exact-transfer assets and code identity; implement/audit adapter only if direct-source wallet reuse loses the agreed comparison. Native staking and automatic yield guarantees remain unsupported.
