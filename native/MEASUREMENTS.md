# Did the user's problem get solved better?

This is the common test/benchmark specification. Everything in design cost tables is a **layout estimate or illustrative workload**, never a measured result. There is no Solidity implementation or benchmark output in this revision. Units follow [PRIMITIVES.md](PRIMITIVES.md), not SSTORE-gas conversions.

## Two comparisons and an honest control

1. **Original on its native chain:** pinned source/deployed version and documented wallet flow. Measure UX/signatures, gas or Solana compute/rent, inclusion/finality, price quality and adverse outcomes. Never translate Solana rent deposits directly into burned EastSea fees.
2. **Original through EastSea's actual executor:** licensed, fidelity-checked originals from the compatibility track. Same assets/parameters, P-256 user, same holder freshness and same B5 genesis. Count batching benefits in **both** paths. A two-transaction EOA flow becoming one native-account batch is an account benefit, not automatically a new contract's benefit.
3. **Native design through that same executor:** identical user task and adversarial traces. Publish original wins, ties, unsupported actions and worse wait time/state growth. Do not compare a toy one-pair market against unrestricted production routing without labeling the removed capability.

Licences are checked against the exact comparison pin before any originals are vendored. Restricted originals remain in separately allowed test contexts; clean-room designs derive from public behavior/specifications. No licence conclusion is inferred from a family name.

## Cost record for each action

Publish: runtime/initcode sizes; exec gas before/after any EVM refund; prove gas; **actual** new slots/accounts, state units and canonical envelope length; receipt output and event topic/data bytes; code bytes; rollback units for failure; sponsor/relayer fees; added token state; amortization cohort. Include create, success, cancel, expiry, retry, stale price, invalid signature, brake and all exit paths. Runtime immutables still cost code bytes; events still cost state units. An updated zero field becoming nonzero is a newly occupied slot, even inside an old record.

For each storage layout list field widths and packing, counter/bitmap high-water cost, who owns live rights, who can retire records, and what happens when every participant abandons them. Calldata leaf lists and ciphertexts are paid signed-envelope bytes; publishing hashes alone does not guarantee availability. Replay tombstones/bitmap words must be priced and retained for the authorization's lifetime.

Floor fee vector for a recorded action:

```
fee_floor = G_exec*p_exec + G_prove*p_prove + U*10^12 + tip
```

Report the measured target-load zero-exec/zero-prove case separately from nonzero fee-vector cases. Asset principal, name-service burns, LP returns, bid prices and issuer fees are not network fees. Specify who pays each, including relayer failures.

## Throughput and latency

For isolated repeated actions with mean paid-state cost `u`, paid-state ceiling at 1 s/height is `32/u actions/s`, or `2,764,800/u actions/day`. This is **not achieved TPS**. Allocate 10%, 50% and 100% of shared refill, add deployment/code amortization and fresh-recipient cohorts, and report burst recovery. For a mixed workflow use the total units across all legs divided by completed workflows, including failed attempts and non-claiming users.

| Illustration, ignoring other binding limits | State-only maximum/day at 100% refill | Floor state fee |
|---|---:|---:|
| 25 u action | 110,592 | 0.000025 DBLN |
| 100 u action | 27,648 | 0.000100 DBLN |
| 500 u action | 5,529 completed actions (floor) | 0.000500 DBLN |
| 1,000 u workflow | 2,764 completed workflows (floor) | 0.001000 DBLN |
| 10,000 u deployment | 276 deployments (floor), no other traffic | 0.010000 DBLN |

Use `min(state ceiling, canonical archive ceiling, exec ceiling, prove ceiling, new-slot cap, tx cap, per-tx limits)` as an upper bound and name the observed binding limit. Burst capacity is the **remaining** bucket, not 100,000 fresh u per block. Stateful actions contending on the same pool, sponsor balance or counter can serialize even with independent user addresses; benchmark conflict re-executions explicitly. Cold/hot cache and sequential/parallel roots must agree.

Load tests: ≥100 completed samples for p50/p95/p99 inclusion and finality; sustained ≥10,000 finalized heights to exhaust a misleading burst, plus restart and gap tests. Record rejected/expired actions and drain recovery. If sustained simulation is substituted for live chain time, label it. Finalized receipts and later execution proofs are distinct latency milestones. Report the number of protocol proofs/beacons/control entries and their encoded-byte share; never assign the full archive refill to user traffic by default.

## User and trust record

Count UI steps, biometric prompts, transaction signatures, typed-message signatures, session provisioning, guardian signatures and relayer transactions separately. Test first use with zero DBLN, funded first use, repeat use, another device, sponsor absent, expired session and offline counterparty. Count setup before amortizing it; present cold and warm paths side by side. Record what the user can accomplish if every hosted frontend, solver, sponsor, witness archive or data source disappears.

For every design explicitly identify who can **stop/censor/steal**: owner/guardians, token issuer, chosen oracle signers, committee threshold, relayer, counterparty, data publisher. Measure censorship/timeouts and losses; “no admin” removes a power, not all trust. One-second finality neither prevents pre-inclusion reordering nor fixes stale observations or illiquid exits.

## Shared correctness gates

- Unit boundary tests plus property/invariant sequences for conservation, rounding, authorization, domain separation, expiry, duplicate/partial fills, bounded loops and exit accounting.
- Real executor tests for P-256 self batches and added-owner relays; ERC-1271 only after A4; fresh accounts/holders; same-block conflicts; BAL, sequential/parallel state roots and receipts; signed exec/prove/state caps and reverts.
- Adversarial **defensive** scenarios for price manipulation, withheld/missing seed, malformed ciphertext or proof, oracle outage, blocked token transfer, unavailable evidence, sponsor exhaustion and counterparties disappearing. Publish outcomes without exploit reproduction tooling.
- Receipt evidence must verify the block certificate, canonical index/path, emitter address/code context, success and intended fields; never treat arbitrary logs as approved claims or on-chain replay memory.
- Deterministic brake tests: caller cannot set arbitrary pause; entry predicate is checkable; repayment/refund/settlement remains callable subject to solvency and token behavior; no founder rescue key appears in constructor, manifest or fallback.

Release the method, pins, machine/OS/compiler/genesis/fee vector, raw results, layout diffs and failures. Native superiority remains **unproven** until these comparisons run.
