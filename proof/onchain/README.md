# DAO and multisig transaction journeys

`scenarios_examples.py` exports `example:multisig` and `example:dao` using the
`SCENARIOS` registry and `Context` interface from `codex/onchain-harness`.
Both callables deploy their dependencies, fund the example, and check native
payouts and contract state after `ctx.tx` obtains finalized receipts.

Each journey exercises P-256/ERC-1271 signatures from delegated accounts,
wrong signers, duplicate/unsorted signers, replay, expired authorizations,
direct account approval/vote calls with empty signature entries, and mixed
signed/direct quorums. The DAO also waits for ordinary blocks to enforce its
timelock and verifies approved execution under the entry brake.

This worktree starts before the harness infrastructure. When integrating with
that lane, retain its other example registrations and use these two updated
callables and registrations in `proof/onchain/scenarios_examples.py`. The
compatibility `executeWithSigners` APIs remain callable by the existing
harness; the new multisig overload also binds an explicit deadline.

After integration, the harness can select these journeys with repeated IDs:

```sh
make onchain ONCHAIN_ARGS='--only example:multisig --only example:dao'
```

That command belongs to the harness lane and starts a local devnet. It was
not run for this repo-only change. Foundry verifies the contracts locally;
the account mock matches EastSea v2's `isValidSignature(bytes32,bytes)` and
its 128-byte `r || s || x || y` format, with real P-256 verification. Unit
results do not constitute deployed-account or mainnet gate evidence.
