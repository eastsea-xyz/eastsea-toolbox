# originals/mit — MIT, BSD-3-Clause, Apache-2.0, Unlicense

**This folder holds unmodified upstream source at `<repo>@<commit>`: one git submodule per item, pinned to the exact commit. It is for test and benchmark use only and is provided AS IS, with no warranty.**

You may copy, publish and deploy these items.

Each item keeps its upstream LICENSE and copyright notices inside its submodule, and those govern the item. The `LICENSE` file in this folder is the MIT text, kept for reference.

## Items

| Item (catalog) | Upstream repo @ commit | Licence | Mainnet address | Compiler | Fidelity |
|---|---|---|---|---|---|
| E1 Multicall3 | `mds1/multicall@ebd8b644` | MIT | `0xcA11bde05977b3631167028862bE2a173976CA11` | solc 0.8.12, runs 10,000,000 | MATCH (modulo metadata) |
| E2 Arachnid CREATE2 deployer | `Arachnid/deterministic-deployment-proxy` | Unlicense | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | raw bytecode | planned (Lane A) |
| E7 Permit2 | `Uniswap/permit2@cc306b60` | MIT | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | solc 0.8.17, viaIR, runs 1,000,000 | MATCH (modulo immutables) |
| E9 OpenZeppelin 5.x Governor + Timelock + ERC20Votes | `OpenZeppelin/openzeppelin-contracts` | MIT | — | solc 0.8.x | planned (Lane A) |
| E10 Seaport 1.6 + ConduitController | `ProjectOpenSea/seaport` | MIT | per release | solc 0.8.24, viaIR | planned (Lane D) |
| E12 ERC721A | `chiru-labs/ERC721A` | MIT | — | solc 0.8.x | planned (Lane A) |
| E13 Aave V3 core v3.0.2 (changed from BUSL to MIT on 2023-01-27) | `aave/aave-v3-core` | MIT | per market | solc 0.8.10 | planned (Lane C) |
| E15 Compound V2 | `compound-finance/compound-protocol` | BSD-3-Clause | per market | solc 0.5.16 / 0.8.x | planned (Lane C) |
| E18 Chainlink aggregator (outside ccip/keystone/workflow) | `smartcontractkit/chainlink` | MIT | per feed | solc 0.6 / 0.8 | planned (Lane C) |
| E19 Pyth EVM receiver + Wormhole core | `pyth-network/pyth-crosschain`, `wormhole-foundation/wormhole` | Apache-2.0 | per chain | solc 0.8.x | planned (Lane C) |
| E20 1inch Limit Order Protocol v4 | `1inch/limit-order-protocol` | MIT | per chain | solc 0.8.23 | planned (Lane D) |
| E28 ENS registry + registrar (optional) | `ensdomains/ens-contracts` | MIT | — | solc 0.8.x | planned (Lane D) |

Status `planned` means the lane has not added the submodule yet. The Fidelity column shows the `proof/fidelity.py` verdict. Multicall3 and Permit2 have been verified against the upstream commit, and their submodules have not been added yet.
