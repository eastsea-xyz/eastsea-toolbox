# Proof report: other chains' killer contracts on EastSea

This report has one row per catalog item and records only what was measured. The results are neutral measurements, not recommendations, and failures and "no" verdicts get the same prominence as passes. Everything is provided AS IS: anyone who deploys or uses the code does so at their own responsibility.

The method follows catalog §5:
1. **Fidelity**: `proof/fidelity.py` compares the rebuilt runtime with the mainnet bytecode.
2. **Behaviour**: each user-journey scenario runs in Foundry and in the EastSea executor harness.
3. **Hazards**: the H1–H14 probes in `proof/probes/`.
4. **Benchmarks**: records in the `proof/bench/schema.json` format.
5. **Verdict**: yes, with changes (what changed), or no (why).

**Status (2026-10-06):** the bench is built (Lane 0). The item rows fill in as lanes A–D land. `pending` means nothing has been measured yet. The "Hypothesis" column is the catalog's pre-test guess and is **not** a result.

## Hazard probes (H1–H14)

The probes pin EastSea's EVM profile today (revm 43, Osaka spec). The Foundry column comes from `cd proof && forge test` (solc 0.8.31, `evm_version = osaka`, EIP-170 enforced). The harness column fills in once the executor harness runs the same probe contracts.

| ID | Hazard | Foundry (2026-10-06) | Executor harness | Note |
|---|---|---|---|---|
| H1 | Opcodes (PUSH0, TSTORE/TLOAD, MCOPY, CLZ, BLOBHASH, BLOBBASEFEE) | pass | pending | |
| H2 | Precompiles 0x01–0x11, 0x100 | pass | pending | Osaka gas: modexp floor 500 (EIP-7883), P256VERIFY 6,900 (EIP-7951) |
| H3 | ecrecover vs P-256 | pass | pending | ecrecover never returns a P-256 account, so off-chain-signature flows need B1 |
| H4 | 7702 code on EOAs | pass | pending | `safeMint` to today's account shape reverts (B2 open) |
| H5 | Block cadence (~1 s) | pass (staged 1 s blocks) | pending | Ethereum's 12 s cadence fails the pin, as intended |
| H6 | Timestamps non-decreasing | pass (staged) | pending | equal-second blocks are counted |
| H7 | prevrandao = 0 | pass (staged) | pending | a non-zero prevrandao fails the pin, as intended |
| H8 | Code 24,576 B / initcode 49,152 B / tx cap | pass | pending | the probe fits in ~10.7 M gas, under the 16,777,216 cap |
| H9 | Paid state (exec-gas side) | pass | pending | state units can only be measured in the harness |
| H10 | SELFDESTRUCT (EIP-6780) | pass | pending | the harness also checks that a same-tx victim is gone |
| H11 | Canonical addresses | pass (Foundry's CREATE2 predeploy etched away) | pending | B3 open: EastSea has no predeploys |
| H12 | Native staking | n/a | n/a | not EVM-observable; for real staking the verdict is no |
| H13 | Tx format and tooling | n/a | pending | deployment goes through the harness or SDK |
| H14 | Old compilers | see fidelity below | n/a | |

## Summary table

| # | Item | Folder | Fidelity | Behaviour (Foundry) | Behaviour (harness) | Runs on EastSea | Hypothesis (catalog) | Logs |
|---|---|---|---|---|---|---|---|---|
| E1 | Multicall3 | originals/mit | **MATCH (modulo metadata)** | pending | pending | pending | yes; canonical address needs B3 | |
| E2 | Arachnid CREATE2 deployer | originals/mit | pending | pending | pending | pending | yes; needs B3 | |
| E3 | WETH9 | originals/gpl | **MATCH (modulo metadata)** | pending | pending | pending | yes | |
| E4 | Uniswap V2 core + Router02 | originals/gpl | **Factory: MATCH (byte-identical)** | pending | pending | pending | yes; LP `permit` with changes (H3) | |
| E5 | Uniswap V3 core + periphery | originals/gpl | pending | pending | pending | pending | yes; NFT permit / safe-transfer need B1/B2 | |
| E6 | Uniswap V4 + Universal Router | originals/busl, gpl | pending | pending | pending | pending | yes (tests/testnet only) | |
| E7 | Permit2 | originals/mit | **MATCH (modulo immutables)** | pending | pending | pending | with changes: signature paths need B1 | |
| E8 | Safe v1.5.0 | originals/gpl | pending | pending | pending | pending | yes via `approveHash`; contract sigs need B1 | |
| E9 | OZ Governor + Timelock + ERC20Votes | originals/mit | pending | pending | pending | pending | yes; `castVoteBySig` needs B1 | |
| E10 | Seaport 1.6 | originals/mit | pending | pending | pending | pending | with changes: on-chain `validate()` orders | |
| E11 | EntryPoint v0.8 + SimpleAccount | originals/gpl | pending | pending | pending | pending | yes | |
| E12 | ERC721A | originals/mit | pending | pending | pending | pending | yes; `_safeMint` needs B2 | |
| E13 | Aave V3 core v3.0.2 | originals/mit | pending | pending | pending | pending | yes, with a mock feed | |
| E14 | Morpho Blue | originals/gpl | pending | pending | pending | pending | yes | |
| E15 | Compound V2 | originals/mit | pending | pending | pending | pending | with changes: rate parameters ÷ 15 (H5) | |
| E16 | Liquity V1 | originals/gpl | pending | pending | pending | pending | yes | |
| E17 | OZ ERC4626 + Yearn V3 | originals/mit, agpl | pending | pending | pending | pending | yes | |
| E18 | Chainlink aggregator | originals/mit | pending | pending | pending | pending | yes (our reporters) | |
| E19 | Pyth + Wormhole | originals/mit | pending | pending | pending | pending | yes; real VAA | |
| E20 | 1inch LOP v4 | originals/mit | pending | pending | pending | pending | with changes: P-256 makers need B1 | |
| E21 | CoW GPv2Settlement | originals/gpl | pending | pending | pending | pending | yes via `setPreSignature` | |
| E22 | Sablier Lockup | originals/busl | pending | pending | pending | pending | yes (tests/testnet only) | |
| E23 | Balancer V2 | originals/gpl | pending | pending | pending | pending | yes | |
| E24 | Curve StableSwap (clean-room) | clones | n/a | pending | pending | pending | yes (CR) | |
| E25 | MakerDAO DSS (stretch) | originals/agpl | pending | pending | pending | pending | yes | |
| E26 | Lido stETH | — | n/a | n/a | n/a | **no**: contracts cannot stake the coin (H12) | no | |
| E27 | Gnosis CTF + Polymarket (optional) | originals/gpl, mit | pending | pending | pending | pending | yes; off-chain orders need B1 | |
| E28 | ENS (optional) | originals/mit | pending | pending | pending | pending | yes | |
| S2 | `ERC20Ext` (Token-2022) | clones | n/a | pending | pending | pending | yes, except confidential transfers | |
| S4 | Candy-Machine-style drop | clones | n/a | pending | pending | pending | yes | |
| S5 | Merkle-committed NFTs (Bubblegum) | clones | n/a | pending | pending | pending | with changes: claim to own on-chain | |
| S6 | On-chain CLOB (OpenBook/Phoenix) | clones | n/a | pending | pending | pending | yes | |
| S10 | pump.fun → V2 graduation | examples/launchpad + E4 | n/a | pending | pending | pending | yes | |
| S11 | LST vault (Marinade/Jito) | E17 | n/a | pending | pending | pending | no for staking; vault mechanics yes | |

Solana items that map onto an Ethereum original (S1, S3, S7–S9, S12–S16) are reported in that original's row. S17 (perps) is out of scope.

## Blockers that set "with changes" today

| ID | Blocker | Items affected |
|---|---|---|
| B1 | `EastSeaAccount` has no ERC-1271 `isValidSignature` | Permit2 signatures, Seaport off-chain orders, Safe contract signatures, 1inch, CoW off-chain, Governor `castVoteBySig`, V3 NFT permit |
| B2 | `EastSeaAccount` has no ERC-721/1155 receiver hooks | `safeTransferFrom` / `_safeMint` to delegated users (shown by probe H4) |
| B3 | No canonical predeploys (non-RLP envelopes) | Multicall3, CREATE2 deployer, Permit2, Safe, Seaport and EntryPoint at their mainnet addresses (probe H11) |
| H5 | ~1 s blocks | Compound V2 rates, Governor block clock, per-block rewards: deploy parameters only |
| H12 | No contract staking | Lido and LSTs: no |
