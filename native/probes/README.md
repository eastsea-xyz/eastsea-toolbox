# C0 token probes

Status: **measurement tool, unaudited, not deployed, not run against any real EastSea asset.** Provided AS IS for testing and benchmarking. Lane C0 of [PLAN.md](../PLAN.md); it is the evidence half of gate G8 ("exact transfer, issuer/bridge trust").

## The question it answers

Before a pool, loan or vault accepts an asset, someone has to know what a transfer of that asset actually does. Native templates only accept **exact-transfer** assets ([PRIMITIVES](../PRIMITIVES.md#inherited-design-rules)); the probe turns that rule into a reproducible observation instead of a name on a list.

`TokenProbe` ([src](src/TokenProbe.sol)) is a personal tool: its owner approves a small amount, calls `probe(token, amount)`, and gets a `Report`:

| Leg | Call | Recorded |
|---|---|---|
| pull | `transferFrom(owner → probe)` | return shape, owner debit, probe credit |
| push | `transfer(probe → sink)` | return shape, probe debit, sink credit |
| back | `transfer(sink → probe)` | return shape, sink debit, probe credit |

Return shapes: `1` true, `2` empty (no bool, USDT style), `3` false or other data, `4` reverted. `exact` is true only when every leg returned true/empty and moved exactly `amount` on both sides, which is exactly what `common/src/ExactToken.sol` accepts (each test cross-checks the probe verdict against the library). Whatever arrived is returned to the owner at the end. The probe stores nothing: owner and sink are immutables.

`park(token, amount)` leaves a balance in the sink; `parked(token)` read at a later height reveals rebasing, demurrage or seizure; `sweep(token)` returns everything.

## What a probe can never show

- **Rebasing** is invisible inside one transaction. Park and re-read across heights.
- **Issuer powers not in use right now** (pause, blocklist, seizure, upgrade). A clean report is evidence about one height, never an endorsement of the issuer. Read proxy slots off-chain (`cast storage <token> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`) and the issuer's published terms.
- **Bridge or reserve backing.** A wrapped asset can move exactly and still be unbacked.
- **Price or liquidity.** That is the oracle/market part of G8 and is not established here.

## Test matrix (Foundry, mock tokens labelled TEST-ONLY)

| Token behaviour | Mock | Probe verdict | Test |
|---|---|---|---|
| plain ERC-20 | `TestToken` | exact | `test_plainToken_isExact_andFullyReturned` |
| no bool return | `NoBoolToken` | exact (empty shape) | `test_noBoolToken_isExact_withEmptyReturn` |
| fee on transfer | `FeeOnTransferToken` | not exact, fee visible | `test_feeOnTransfer_isNotExact_andShowsTheFee`, fuzz |
| no-op "true" | `LyingToken` | not exact | `test_noopTrue_isNotExact` |
| returns false | `FalseReturnToken` | not exact, owner sweeps later | `test_falseReturn_isNotExact_andTokensComeBack` |
| blocklisted holder | `BlockingToken` | not exact at this height, clean after unblock | `test_blocklistedSink_showsRevertedLeg_atThisHeightOnly` |
| global pause | `PausableToken` | first leg reverted | `test_pausedToken_revertsFirstLeg` |
| ERC-777-style callback | `CallbackToken` | exact (reentrancy is a per-template test) | `test_callbackToken_probesExact_butCallbacksAreSeparateRisk` |
| rebasing | `RebasingToken` | exact in one tx; `park` shows the rebase | `test_rebasing_singleTxProbeIsClean_parkRevealsRebase` |
| code replaced at same address | `vm.etch` | code hash differs, verdict changes | `test_codeHashChange_isVisible` |
| no code | — | reported, not reverted | `test_codelessAddress_isReported` |

The Lane B mocks in `common/test/Tokens.sol` are reused; `test/ProbeTokens.sol` adds the no-bool, rebasing and pausable shapes.

## Still to do on the executor (G8)

Run `probe` and a multi-height `park` against every asset proposed for a native pool or market on the B5 benchmark genesis, and publish the raw reports, the token's code hash, proxy slots and issuer terms next to them. No real EastSea asset has been probed in this revision, and no stablecoin or bridge has been identified.

```bash
cd native && forge test --match-path 'probes/*'
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
for this native diagnostic. Use the
[generic native deployment interface](../../docs/personal-mainnet-testing.md#native-contracts)
with its locally built creation bytecode, own test assets, fixed caps and
wallet-approved calls. Run `cd native && forge test` locally before doing so.
Do not deploy from a company key or host a shared mainnet interface. Caps
are raw asset base units, not a dollar valuation; unsolicited external
transfers cannot be prevented at the receiving contract. The [policy](../../docs/personal-mainnet-testing.md)
describes exits and those limits. Stable [English translation keys](../../docs/i18n/personal-test.en.json)
are ready for the language pack.
