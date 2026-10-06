# Verified EastSea boundaries

Design snapshot: 2026-10-06. These are capabilities of the inspected node worktree, not claims about a deployed mainnet. All native designs inherit this document and [the measurement contract](MEASUREMENTS.md). Source keys refer to [SOURCES.md](SOURCES.md).

## Source boundary

The requested root research paths were absent. Both research documents were read from `aether-node/.claude/worktrees/lead/docs/research/` instead. All three available copies of the clone catalog (lead, glm-account, codex-precompiles) ended at §7; the requested §8 “two tracks” was absent. We retain the founder's explicit separation: the **originals** track establishes compatibility; **native** asks whether the user's problem is solved better. Neither track's success proves the other. The inspected lead HEAD was `f92c839e9b2cc41b3f19c0b25ae42f1b4b1738bf`; working files can be ahead of HEAD. [ES0]

## Capability and dependency register

| Key | Observed capability | Boundary / release gate |
|---|---|---|
| A1 | P-256 `P256VERIFY` and EIP-7702 delegation; `execute(Call[])` is atomic under one owner transaction signature. `ownerExecute` permits a funded third party to relay an added owner's signed batch. | No RLP broadcast assumption. Existing self-call authority is not a generic off-chain signed-order verifier. Prepare batches in the wallet; reverted calls roll back the batch. [ES2, ES3] |
| A2 | Guardian recovery: at most eight guardians/owners; threshold guardian signatures, configurable delay (default 48 h, minimum 10 min), owner cancellation; added owners operate the same address. | **Recovery does not revoke a stolen original EOA key.** All existing owners independently authorize `ownerExecute`; this is not ordinary m-of-n treasury execution. [ES2] |
| A3 | Eight payment sessions; at most 16 allowed recipients per session; native payments and explicitly configured ERC-20 `transfer` only; serial identity and nonce; conservative today-plus-yesterday spending cap. | **No arbitrary app calls, approvals, swap calls, or registry-bound sub-accounts.** Those require a new account implementation and wallet integration. Session token-limit mappings can remain after removal; do not claim cleanup refunds. [ES2, ES3] |
| A4 | ERC-1271 and ERC-721/1155 receiver hooks are being added by another lane. They were absent in the read snapshot. | **PENDING.** Re-read actual deployed runtime and test P-256 and account-bound domains before enabling signed orders/claims or safe NFT receipt. Receiver hooks are not marketplace consent. Bare EIP-2612/secp256k1 `permit` remains incompatible with P-256 even after 1271. [ES0, ES2] |
| R1 | Node threshold-signs `seed_message(chain_id, draw) = be_u64(chain_id) || be_u64(draw)` under `aether-committee-seed-v1`, using Commonware `MinSig`. | Signing happens when the committee pool is frozen, **before the target epoch opens**. Draw cadence follows rotation, not wall-clock time. `prevrandao` is zero in the inspected execution path. [ES0, ES4] |
| R2 | `Randomness` reads a system word at REWARDS (`0x7704`) slot `(9 << 200) | epoch`; zero can mean epoch unopened or seed absent. | Epoch is not draw. The hash word is not the raw BLS signature. **Zero is not proof that a future seed is still secret.** Reject designs using `randomness(epoch)==0` as their admission cutoff. [ES4] |
| R3 | Existing predictable draw message and fixed committee identity suggest application timelock encryption can reuse the beacon. | **SDK / security work, not delivered capability.** Verify Commonware TLE suite/MinSig compatibility, domain/hash-to-curve binding, reshare invariance, authenticated raw signature access, availability, and early-signing assumptions. No ciphertext decryption Solidity API exists. Threshold collusion decrypts early. A permissionless on-chain proof that bidding closed before signing is not identified. Strong fairness remains gated on that boundary. [ES4, ES5] |
| R4 | Height-scheduled encryption, decrypt-at-commit mempool, and transfer-reserved capacity are survey ideas. | **PROTOCOL UPGRADES NOT PRESENT.** Do not describe draw encryption as one-second privacy or an encrypted mempool. [ES5] |
| F1 | New genesis with `node_rewards || history_v2` meters accounts, occupied slots, code, canonical signed envelopes and receipts; separate execution/proving fees. | Chain 7780 preserves legacy rules and cannot validate B5 claims. No “first ordinary transaction is free” promise. See units below. [ES1] |
| F2 | Fee sponsorship / transaction `sponsor` field and burn-funded shared pool remain proposals. | **NATIVE FEE-PAYER CHANGE NOT PRESENT.** A contract cannot select a different fee payer during EVM execution. A funded relayer can pay its own transaction to existing `ownerExecute`; zero-native-balance onboarding and initial owner setup still need funded transactions. DeviceCheck is not permissionless proof-of-personhood. [ES1, ES6] |
| L1 | Same-block canonical receipts root on new genesis; BLAKE3 ordered receipt Merkle proofs; light client verifies root against committee-certified block. State root follows separately. | **Certificate trust, not Jolt-proven receipts.** The current execution proof statement excludes receipts. Root inclusion authenticates bytes, not the semantic honesty of every event emitter. [ES7] |
| L2 | Query history defaults to a 30-day window; era roots are retained, while actual era-file deletion is operator configured. | Receipt proofs do not guarantee data availability. Wallets export payment/claim evidence; independently seeded manifests and leaf lists are needed. **No general EVM historical receipt-proof verifier has been identified.** Contracts must retain replay/ownership rights rather than trusting off-chain logs. [ES1, ES7] |
| N1 | Existing `EastSeaNames`: immutable registry, commit/reveal, expiry/grace, resolution and forward-checked reverse lookup; registration fees burn. | Reuse it; no ENS clone. Names do not establish unique humanity, creditworthiness, or merchant legitimacy. Registration needs a 60 s minimum commit age; one-second finality does not remove it. [ES8] |
| V1 | Existing P-256 `EastSeaVault`: bounded owners, threshold approvals, withdrawal/configuration delay, single-owner small native transfers; no admin/fee/proxy. | Reuse and improve its product UI rather than create another treasury custodian. Its queue, setting-era invalidation, deployment bytes and stale-proposal cleanup must be measured. Vault delay minimum is 24 h, unlike A2's 10 min. [ES9] |
| M1 | App registry design pins manifest/bundle hashes, delayed publisher updates and isolated origins; no founder ranking or default curator. | **DESIGN / DEPLOYMENT GATE**, not an assertion that app publishing or isolation is delivered. Manifest hashes are integrity, not a contract audit. Financial execution is outside the registry's beta discovery path. [ES10] |
| M2 | Proposed `brakeState() -> (uint8 state,address guardian,uint64 since)` and `brakeSpec() -> (string uri,bytes32 docSha256)`. | No chain-wide brake protocol. Native templates implement **local deterministic entry brakes** with guardian zero; predicates and monotonic latching must be specified per item. No discretionary founder, curator, publisher, or oracle-owner pause key. Refunds/repayment/settlement keep their safety preconditions; “exit open” is not a solvency guarantee. [ES10] |

## Exact paid-state interpretation

Per [27-state-fee.md][ES1]:

```
U = 100 * newly_created_accounts
  + 100 * newly_occupied_storage_slots
  + newly_persisted_code_bytes
  + ceil((signed_envelope_bytes + 128 + output_bytes
          + sum_events(64 + 32 * topic_count + data_bytes)) / 32)
```

This is the final committed difference against pre-state. Existing nonzero slot updates incur **zero new-slot units**, but execution/prove gas and envelope/receipt charges remain. Setting then clearing within one transaction contributes zero slot units. Clearing in a later transaction **does not refund previously burned state fees** or replenish B5. There is no periodic rent charged by this rule. EVM gas refunds are a separate execution-gas issue. A fresh sender nonce account can cost 100 u. Fresh native recipients can cost another 100 u; ERC-20 holder balances/allowances and NFT ownership can add slots even for an existing account. Code deployment counts accounts and actual persisted code; compiler layout/chunks must be measured, not assumed. [ES1]

The older toolbox [paid-state note](../docs/paid-state-design.md) converts SSTORE execution gas into approximate monetary “u”, describes updates as 25 u and deletion as a refund. **That approximation is not the new-genesis persistence meter.** These native documents follow design 27; the earlier file is outside this docs-only change. Events are priced archive growth, not free storage. A standard ERC-20 Transfer event contributes exactly 192 metered bytes = 6 u before aggregate rounding. [ES1]

## B5 is shared, bursty and finite

State burst `B=100,000 u`, refill `R=32 u/finalized height`, debt `d`:

```
u <= B-d
d_next = max(0, d+u-R)
sum(u) over N consecutive heights <= B + 32*N
```

At a nominal one-second cadence, refill is 2,764,800 u/day for **all apps together**, not per app. A 100 u new slot alone supports at most 27,648/day before any envelope/receipt overhead. New-slot cap: 512/block. Per block: 2 MiB logical priced bytes, 2,000 transactions; research reports 30 M exec / 200 M prove and Osaka per-tx 16,777,216 exec gas, requiring probes because design 04's precompile/parallelism descriptions partly disagree with code. The implemented parallel executor is optimistic one-round execution with serial conflict repair; no per-transaction static BAL DAG should be assumed. [ES0, ES1, ES11]

Independent canonical-payload burst: 8 MiB; refill 4,096 B/height; 256 KiB control reserve. It includes BAL and protocol traffic, not only user bytes. Empty block headers consume refill too. Thus `4096 / action_encoded_bytes` is a generous upper bound; benchmark actual block payload deltas and system load. [ES1]

Floor state fee: `U * 10^12 wei = U * 10^-6 DBLN`; no USD claim. Total fee includes exec/prove dimension, any tip, and any explicitly chosen counterparty fee. Congestion price is `fake_exponential(10^12,max(0,d-50,000),12,500)`; at debt 62,500/75,000/near 100,000, approximately 2.72x/7.39x/54.46x floor. Refill follows finalized heights, not elapsed idle wall time. [ES1]

## Inherited design rules

- Stateless histories are logs plus client evidence; live balances, consumed authorizations, disputes and rights stay on-chain. Deletion alone cannot stop replay of a still-valid signed authorization.
- No founder admin, protocol-fee recipient, mutable asset allowlist, curated solver list, privileged settlement sequencer, upgrade proxy, or issuer bailout key. Immutable instances can differ by user-chosen assets/oracle policies; those choices remain visible.
- Token adapters accept only explicit exact-transfer assets after balance-delta checks; fee-on-transfer, rebasing, callback and frozen issuer tokens are separate test cases, not silently supported.
- Contracts have no private state. Hiding wallet jargon never hides a price cap, recipient, refund condition, collateral loss, waiting period, oracle trust, or sponsor refusal.
- New deploys opt into new bytecode; moving funds requires the owner's authority. Account re-delegation is a separately authorized change, not a template upgrade key.

[ES0]: SOURCES.md#es0
[ES1]: SOURCES.md#es1
[ES2]: SOURCES.md#es2
[ES3]: SOURCES.md#es3
[ES4]: SOURCES.md#es4
[ES5]: SOURCES.md#es5
[ES6]: SOURCES.md#es6
[ES7]: SOURCES.md#es7
[ES8]: SOURCES.md#es8
[ES9]: SOURCES.md#es9
[ES10]: SOURCES.md#es10
[ES11]: SOURCES.md#es11
