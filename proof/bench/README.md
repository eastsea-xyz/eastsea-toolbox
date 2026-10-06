# Benchmark records (`eastsea-proof-bench/1`)

Each record is a JSON file covering one item in one environment. It validates against `schema.json` and lives at `records/<item-id>/<environment>-<date>.json`. Records are **neutral measurements**:
- We publish the method, the pinned commits, the raw logs and the failures, and we give failures the same prominence as passes.
- When a native design is compared with its original, the comparison is published even where the original wins.

```bash
python3 proof/bench/validate.py   # schema + derived-value checks (needs: pip install jsonschema)
```

`examples/illustrative.json` shows the shape of a record. **Its numbers are not measurements.**

## What a record holds

| Block | Fields | Notes |
|---|---|---|
| `item` | `id` (E…, S…, N…), `name`, `track` (originals / clones / native), `folder`, `licence`, `upstream.repo` + `commit`, `compares_with` (native only) | |
| `environment` | `kind` (foundry / executor-harness / devnet / testnet), `date`, `toolbox_commit`, `eastsea_commit`, `evm_spec`, `state_floor_wei_per_unit`, `limits` | `limits` holds the values the run used: 30 M exec, 200 M prove, 16,777,216 per tx, a 100,000 u burst, a 32 u/block refill, 512 new slots/block and 2 MiB payload |
| `fidelity` | `verdict`, `detail` | the output of `proof/fidelity.py` |
| `hazards` | `id` (H1–H14), `result` (pass / fail / expected-fail / n/a), `blocker` (B1…), `note` | `expected-fail` marks a known blocker that is documented in the catalog, such as B1 (no ERC-1271) or B2 (no receiver hooks) |
| `actions[]` | one entry for each deploy and each user action (see below) | |
| `verdict` | `runs_on_eastsea`: **yes / with_changes / no**, plus `summary`, `changes[]` (required for with_changes), `why_not` (required for no) and `blockers[]` | this feeds the summary row in `../REPORT.md` |

### Per action

| Field | Definition |
|---|---|
| `exec_gas` | EVM execution gas, as on Ethereum |
| `prove_gas` | EastSea prove gas declared for the tx. `null` in Foundry, which cannot measure it |
| `state_units` | paid-state units: 100 per new slot or account, 1 per code byte, 1 per 32 B of receipt. `null` in Foundry |
| `new_slots` | storage slots created (zero to non-zero) |
| `persisted_bytes` | logical bytes the chain keeps: code, slots and receipt |
| `fee_at_floor_wei` | `state_units × state_floor_wei_per_unit`. The exec/prove base fee is 0 at or under target. Stored as a decimal string |
| `ethereum_gas` | mainnet gas for the same action, as a neutral reference |
| `actions_per_block` | `min(⌊30 M / exec⌋, ⌊200 M / prove⌋, ⌊100,000 / units⌋, ⌊512 / new_slots⌋, ⌊2 MiB / bytes⌋)` |
| `binding_limit` | which term of that minimum binds: `exec_gas`, `prove_gas`, `state_burst`, `new_slots`, `payload` or `tx_gas_cap` |
| `sustained_per_day` | `32 u/block × 86,400 blocks ÷ state_units` = `2,764,800 ÷ units`. Example: an ERC-20 transfer to a new holder costs 125 u, so it sustains 22,118 per day |
| `latency_ms` | devnet/testnet only. submit → inclusion and submit → finality, p50/p95 over **≥ 100** tx |
| `user_signatures` | how many signatures the user makes. Used in native-vs-original comparisons |
| `outcome` | `ok`, `reverted` (it still pays for the envelope and the work done), or `rejected` (refused before execution) |

`validate.py` also checks that `fee_at_floor_wei` and `sustained_per_day` agree with `state_units`.

## How each environment fills a record

- **Foundry** (`kind: foundry`): `exec_gas`, `new_slots` and `ethereum_gas` only. `prove_gas` and `state_units` are `null`. Use this environment for behaviour tests and quick gas checks.
- **Executor harness** (`kind: executor-harness`; aether-node `scripts/run-contracts-onchain.sh`): every field except `latency_ms`. Each tx is a real P-256 envelope, uses paid state, and is compared across build, execute and sequential execution. This is the format of aether-node `docs/research/contracts-onchain-2026-10-06.md`, extended with prove gas, binding limit, sustained/day and verdict.
- **Devnet / testnet**: adds `latency_ms`. Deploying the whole originals suite live needs about 0.4–0.6 M units, which is roughly 3–5 h of refill on one chain (catalog B5). Record the budget the devnet used in `limits`.
