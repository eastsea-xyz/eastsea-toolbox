# clones/ — clean-room rebuilds of behaviour we may not copy (MIT)

Some killer contracts cannot be copied:
- **Solana programs** cannot run on the EVM.
- **Some originals have no licence or a proprietary one:** Curve (all rights reserved), Orca Whirlpools (Orca License since 2025-02-27), Marinade, Metaplex, Jupiter and pump.fun.

For these, the proof is **the same user-facing behaviour**, rebuilt in Solidity from public specifications. The MIT licence of the toolbox root applies.

> [!WARNING]
> **Provided AS IS, with no warranty of any kind.** For tests and benchmarks. Anyone who deploys or uses this code does so at their own responsibility.

## Clean-room rules

1. Design only from **public docs, whitepapers and specs**. The person writing the code must **not read the source** of a non-permissive original.
2. Each item's README lists the spec sources it used, with URL and access date.
3. Behaviour tests come from the catalog (§3, "Behaviour tests"). Benchmarks use `proof/bench/schema.json`.
4. Each item ships the toolbox's four documents: README, SECURITY, GAS and manifest.

## Planned items (catalog §3, §6)

| Item | Mirrors | Lane |
|---|---|---|
| S2 `ERC20Ext` | Token-2022 extensions (transfer fee, hook, metadata pointer, non-transferable, interest display, default-frozen) | D |
| S4 Drop | Candy Machine: phases, merkle allowlist, per-wallet cap, beacon commit-reveal | D |
| S5 Merkle-committed collection | Bubblegum compressed NFTs | D |
| S6 On-chain CLOB | OpenBook v2 / Phoenix | D |
| E24 StableSwap | Curve StableSwap, built from the whitepaper | B, under a strict no-source rule |

Problem-first redesigns native to EastSea (Track 2) are not clones. They live in `native/`.

## Personal mainnet deployment guard

The items above are planned designs, not executable publisher examples.
Mainnet copies must use the [personal deployment policy](../docs/personal-mainnet-testing.md#originals-and-clones).
`PersonalTestDeployer` rejects bare original bytecode without the policy,
atomically leaving no unguarded deployed instance. Original source and
fidelity bytes must never be edited to pass this guard.

A future thin adapter must guard the whole call graph, initialize constructor
state correctly, prevent direct implementation access and unguarded children,
track all supported assets, and remove protocol fees without claiming the
wrapper itself is byte-for-byte original code. A public forwarding proxy is
insufficient. WETH9, Multicall3, Uniswap V2 and Permit2 remain fidelity controls
until such an adapter is reviewed; the BUSL mainnet exclusion still applies.
