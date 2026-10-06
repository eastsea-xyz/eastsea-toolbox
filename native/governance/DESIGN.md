# Governance: turn a community decision into a verifiable result

Status: design, 2026-10-06; **Lane A, P1**. Bounded on-chain voting is implementable with a suitable checkpoint token. Proof-aggregated voting and private voting are separate unbuilt gates. Inherits [PRIMITIVES](../PRIMITIVES.md) and [MEASUREMENTS](../MEASUREMENTS.md).

## The user's problem

A community sharing a treasury or application needs to decide what happens without handing a founder a permanent veto or relying on a meeting administrator's count. Governance contracts make the chosen voting rule and resulting action enforceable. Token-weighted communities additionally need to prevent the same assets being moved between accounts and counted repeatedly. Historical voting weight solves that accounting problem; it does not establish one human, one vote. [ERC-5805 motivation, created 2022-07-04](https://eips.ethereum.org/EIPS/eip-5805), [OpenZeppelin on-chain governance guide, accessed 2026-10-06](https://docs.openzeppelin.com/contracts/5.x/governance).

Best layer: **contract for binding outcomes; wallet for participation and understandable execution consent**. An existing EastSeaAccount's guardians are recovery authorities, not an m-of-n treasury. Existing EastSeaVault owner signatures cannot be silently replaced with a token vote. [ES2, ES9](../SOURCES.md#es9)

## Preserve what the originals got right

OpenZeppelin Governor separates voting, quorum, proposal execution and optional delay. Its ordinary flow involves proposal, voting, queueing and execution; token holders may need self-delegation before voting. It already hashes proposal actions instead of storing the entire action array. Native design must not claim this existing optimization as an invention. [OpenZeppelin Governor flow](https://docs.openzeppelin.com/contracts/5.x/governance).

The real EastSea constraint is the ongoing cost of checkpoint/receipt state, not a need to shorten human deliberation to one second. `getVotes`, current `balanceOf` and historical `getPastVotes` are different facts. ERC-5805 specifically explains why current balances permit transferred tokens to vote twice; native code must retain that protection. [ERC-5805](https://eips.ethereum.org/EIPS/eip-5805).

A signed tally, publisher-controlled voter list or Merkle root is **not an authoritative election result**. A root can omit eligible votes or include duplicates. This v1 retains on-chain voter receipts and tallies; proof aggregation is blocked until eligibility, authorization, uniqueness, omission resistance and data availability are verifiable together.

## Native solution: a bounded ballot with an optional treasury

One immutable `NativeBallot` instance pins a nonproxy voting token and its expected code/clock, proposal threshold, quorum fraction, three choices (`For`, `Against`, `Abstain`), notice period, vote period, execution delay and maximum eight CALL actions/4 KiB action data. There is no delegatecall, rule upgrade, founder veto, mutable curator, fee recipient or emergency signer.

The selected token must implement historical delegated votes plus the `IVotes` historical-total-supply extension; ERC-5805 alone does not require every needed supply method. Require `CLOCK_MODE` to match finalized block heights and all values to fit `<2^120`. A normal ERC-20 without checkpoints is unsupported. Source bytecode identity does not prove a dishonest token's checkpoint semantics; independent semantic tests are a gate. [OpenZeppelin IVotes and Votes reference](https://docs.openzeppelin.com/contracts/5.x/api/governance).

Illustrative periods: 86,400 heights of notice, 604,800 heights of voting and 172,800 heights before execution. At nominal one-second cadence these are one, seven and two days; stopped finalization delays them. One-second settlement does not remove the need for human review.

State machine: `Notice → Voting → Defeated | Queued → Executed`, with terminal `Unavailable` for an unusable, never-activated snapshot; actions that fail remain Queued for permissionless retry. No creator can change/cancel an accepted proposal. Ended ballots can be finalized by anyone, regardless of their vote or proposer availability.

At proposal creation, check the proposer's delegated checkpoint weight at the previous finalized height against the fixed proposal threshold, pin a future voting snapshot height and hash the complete action bundle, instance, chain and monotonic proposal sequence. Vote only when that voting snapshot is strictly in the past. Anyone activates a ballot, caching its historical total supply. Each vote reads the account's **delegated checkpoint weight at that snapshot**, writes one receipt and adds the weight to exactly one tally.

Rules: one immutable choice per account; nonzero eligible weight; tally sum cannot exceed cached total supply; quorum requires `For+Abstain >= ceil(snapshotSupply*quorumBps/10,000)`; passage additionally requires `For>Against`. Current token ownership is neither the weight source nor a second vote credential. Long-term borrowed voting power and wealthy majorities remain part of this chosen rule.

V1 permits at most 32 simultaneous Notice/Voting proposals. A qualifying proposer pays normal state/execution fees; there is no fee paid to a curator. The cap bounds outstanding work but allows a wealthy proposer to occupy capacity until voting closes. It never limits the number of voters in an already accepted ballot. Finalization releases capacity even if an approved action later fails.

If a proposal was never activated and its voteEnd has passed, anyone may terminalize it as Unavailable and decrement activeCount without consulting the failed checkpoint source. Require no cached supply and zero tallies/accepted votes; this marks an uncounted ballot, invents no eligibility/quorum and grants no execution authority. A selected source outage therefore cannot lock all proposal capacity forever.

For advisory use, the final on-chain status/tallies are the result; no automatic control is implied. For binding transfers, this same contract holds explicitly donated native/token treasury funds and executes only approved bundles after the delay. A separate existing vault or application must explicitly opt into this executor; **no such integration is assumed to exist**.

Treasury contributors understand there is no unilateral deposit refund: this is community-owned spending authority. The chosen voting majority can direct the treasury, including to itself. No founder can reverse that outcome. The wallet shows each asset/recipient/call and the full execution delay before voting.

Proposal action bytes travel in the priced envelope and independently saved manifests. The contract keeps their hash, not an archive server's authority. Anyone with the bytes can execute the exact matching bundle; if all copies disappear, a hash cannot reconstruct them. Export the bundle locally and to independent archives because a 30-day query window is not permanent availability. [ES1, ES7](../SOURCES.md#es7)

## Storage and retention

Proposed packing; actual compiler storage layout is a required check.

| Word | Fields | New occupation |
|---|---|---|
| G0 | `uint64 nextSequence; uint32 activeCount; uint8 brakeFlags; uint64 brakeSince; uint88 layoutTag` | 100 u at deployment; nonzero layout tag |
| P0 | `bytes32 actionHash` | 100 u per proposal |
| P1 | `uint64 snapshot; uint64 voteEnd; uint64 executeAfter; uint32 sequence; uint8 status; uint8 actionCount; uint16 layoutTag` | 100 u per proposal; reject sequence overflow rather than reuse ids |
| P2 | `uint120 forVotes; uint120 againstVotes; uint16 layoutTag` | 100 u at proposal creation, including nonzero tag |
| P3 | `uint120 abstainVotes; uint120 snapshotSupply; uint16 layoutTag` | 100 u at proposal creation; supply cached later in the occupied word |
| `receipt[proposal][voter]` | `uint120 weight; uint8 choicePlusOne; uint128 reserved` | 100 u for each accepted voter |

Tallies stay on-chain. Historical token checkpoints and delegate mappings remain the token's separately metered state. Token transfers/delegation can allocate new checkpoint-array words even though a ballot only reads them. No arbitrary root substitutes for these records.

Retain proposal metadata and final tallies. Anyone may prune at most eight voter receipts per transaction **after a terminal outcome**; status and unique sequence make old votes unusable. Pruning burns no new slot fee but charges the signed envelope/events, and refunds no earlier fees. Abandoned ballots can be finalized without voters; abandoned queued actions/treasury funds remain governed by their original conditions, with no sweep key.

The status write preceding a treasury CALL prevents reentrancy into that execution; a failed action rolls back the status and the whole bundle. No partial success is relabeled as a successful vote outcome. Additional target-contract storage is measured as the action's incremental diff.

## User signature sequence

Already-delegated, funded voter: open an explanation of the proposal; approve For/Against/Abstain once; one P-256 account batch calls `castVote`. A first-time token holder may need one earlier self-delegation batch **before the future snapshot**, then a vote batch. Wallet setup is counted rather than hidden in the warm path.

Propose, activate, finalize and execute each require a canonical payer transaction; a third party can relay permissionless steps. Current `ownerExecute` can relay a user's vote after funded owner setup. ERC-1271 is pending for generic signed votes, and `delegateBySig` using `ecrecover` does not work for P-256. Payment sessions do not vote. [ES2, ES3](../SOURCES.md#es2)

Product outcome: “Your vote counted with X weight at the snapshot; execution cannot happen before this date estimate.” Hide token standards and storage layout; keep quorum, public vote, snapshot eligibility, majority control and wait time visible.

## Quantitative lifecycle and ceilings

All values are design estimates. `H=ceil((E+128+O+L)/32)`; O=0, a simple batch E=512 B, account `Executed`=128 B. Proposal envelope E=4,096 B in this illustration, not every possible maximum bundle. [ES1, ES2](../SOURCES.md#es1)

| Action | New words | L including account event | Estimated U |
|---|---:|---:|---:|
| Create proposal | P0–P3 = 4 | Created 288 + account 128 = 416 B | 545 |
| Activate after snapshot | 0 | Activated 160 + account 128 = 288 B | 29 |
| Vote once | receipt = 1 | Vote 224 + account 128 = 352 B | 131 |
| Finalize | 0 | Result 224 + account 128 = 352 B | 31 |
| Execute existing-recipient native grant | 0 | Execution 160 + account 128 = 288 B | 29 |
| Execute grant to fresh native recipient | recipient account = 1 | 288 B | 129 |
| Prune eight terminal receipts | 0; eight clear | Pruned 160 + account 128 = 288 B; E=1,024 B | 45 |
| Failed vote/action | 0 application words | O=128 B, no reverted application events | 24 at E=512 B |

ERC-20 grants can reoccupy a 100 u recipient holder slot and add a 192 B Transfer event; approval/target events/calldata alter the **same transaction's H**, not a second standalone action charge. The selected voting token's deployment, mint/holder state and checkpoints are separately included when they are part of the cohort.

Planning deployment: runtime **C=8,000 B**, E=12,288 B, L=192 B, one contract account and G0 → `8,000+100+100+394 = 8,594 u`. No code-size measurement is claimed.

A complete 256-voter, already-delegated lifecycle with one native grant to an existing account and 32 receipt-pruning transactions costs `8,594+545+29+256*131+31+29+32*45 = 44,204 u`, or **172.671875 u per participating voter** including this instance's code and cleanup. Native treasury donations, if needed, add their own funding envelopes; this closed illustration starts with a funded treasury and pre-existing voting token.

Cold self-delegation in a plain checkpoint-token model adds a delegate mapping, checkpoint length and checkpoint element: 300 u, plus 36 u for E=512 B, two 192 B delegation events and account event. For all 256 users, the full cost becomes **130,220 u / 256 = 508.671875 u/voter**. This estimate assumes the token's total-supply checkpoint already exists; measure actual token layout and include issuance/setup/deployment when absent.

At 100% B5 refill, those state-only bounds are approximately **16,011 warm or 5,435 cold participations/day**; 50%/10% yield half/one tenth. But 32 active ballots with eight-day notice+voting permits only about **four completed ballots/day, or 1,024 voters/day at 256 voters/ballot**, in steady state. Publish this intentional application limit as the likely binding ceiling, not the larger state-only number.

The warm lifecycle floor state fee is **0.044204 DBLN/ballot**; the cold lifecycle is 0.130220 DBLN, plus exec/prove/tips and funding/setup. Warm lifecycle capacity takes `ceil(44,204/32)=1,382` heights to refill; a cold lifecycle needs at least `ceil((130,220-100,000)/32)=945` extra heights beyond a fresh burst. A simple vote's 512 B envelope gives an archive-only upper bound of eight votes/height before system traffic and proposal data.

## Brake, MEV and trust

`brakeState()` has guardian zero. New proposals stop when activeCount reaches 32, or on a verifiable pinned-token code/clock/width failure. Capacity is reversible through permissionless finalization; identity/clock violations can be permanently latched via nonreverting `tripBrake`. Each entry recomputes the predicate so a failing/reverting action is not relied on to persist a latch.

Existing ballots continue voting only with valid historical weights; existing known tallies can be finalized despite an entry brake. Approved treasury execution remains callable subject to its delay, exact bundle hash, available funds and successful token/target calls. No “exit open” claim grants a treasury donor unilateral withdrawal or repairs an invalid checkpoint source.

Committee/relayer censorship can exclude timely votes; a token issuer/checkpoint implementation can invalidate eligibility; the selected majority can spend funds; a proposer can occupy proposal capacity. There is no founder veto or tally publisher trusted to replace the on-chain count. Public voting reveals choices and enables lobbying/bribery; short finality does not prevent those incentives or pre-inclusion deadline ordering.

Future private/proof voting is blocked on an account-bound ERC-1271 verifier, a specified proof system linking a certified eligible snapshot to uniquely authorized ballots, data availability, omission-resistant inclusion and bounded challenges. A receipt root does not by itself verify those statements inside EVM, and draw encryption is not a height-scheduled private-voting system. [ES4, ES5, ES7](../SOURCES.md#es7)

## Original wins and verification

Potential native win: simpler immutable rules and a wallet that explains participation without a founder tally server. Worse: fixed choices/rules, proposal-cap censorship, public votes, growing checkpoint state, no arbitrary Governor modules and no automatic integration into existing vaults. Original Governor stacks win on reusable modules, established timelock integrations and broad operational tooling. [OpenZeppelin governance reference](https://docs.openzeppelin.com/contracts/5.x/api/governance).

Compare a pinned Governor+Timelock+ERC20Votes and this ballot using the **same** token, snapshot/delay/quorum, full P-256 batching and action payload. Count cold self-delegation in both; benchmark advisory and funded treasury cases separately. No comparison to a publisher-trusted signed tally counts as equivalent security.

Tests: current-balance double-count prevention; delegation before/after snapshot; future-clock rejection; stale/malformed checkpoint token; zero/maximum supply and tally overflow; duplicate/cross-proposal vote; all quorum/tie edges; public capacity exhaustion/finalization and never-activated source-outage terminalization; action bytes unavailable; failing token/target, reentrancy and atomic retry; pruning after terminal status; code/clock brake; no veto key. Measure state growth/conflicts, vote deadline failures and ≥10,000 finalized-height load traces without shortening the production human-review window.
