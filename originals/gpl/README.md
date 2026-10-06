# originals/gpl — GPL-2.0-or-later, GPL-3.0, LGPL-3.0

**Unmodified upstream source at `<repo>@<commit>` (one git submodule per item, pinned to the exact commit). For test and benchmark use only. Provided AS IS, with no warranty.**

You may copy, publish and deploy these items, as long as the published derivative is GPL-compatible.

- **Our own tests and scripts in this folder are licensed GPL-3.0-or-later**, because they compile together with GPL code.
- **Uniswap V3 core** files still carry `BUSL-1.1` headers. That BUSL changed to GPL-2.0-or-later on 2023-04-01, and the item's README must cite that date in a NOTICE.

Each item keeps its own upstream LICENSE and copyright notices inside its submodule, and those govern it. `LICENSE` in this folder is the GPL-3.0 text, which applies to our tests and scripts here.

## Items

| Item (catalog) | Upstream repo @ commit | Licence | Mainnet address | Compiler | Fidelity |
|---|---|---|---|---|---|
| E3 WETH9 | `gnosis/canonical-weth@3c3b0292` (Dapphub source) | GPL-3.0 | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | solc 0.4.19, optimizer off | MATCH (modulo metadata) |
| E4 Uniswap V2 core | `Uniswap/v2-core@27f6354b` | GPL-3.0 | Factory `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f` | solc 0.5.16, istanbul, runs 999,999 | MATCH (byte-identical) |
| E4 Uniswap V2 Router02 | `Uniswap/v2-periphery` | GPL-3.0 | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` | solc 0.6.6 | planned (Lane B) |
| E5 Uniswap V3 core + periphery | `Uniswap/v3-core`, `Uniswap/v3-periphery` | GPL-2.0-or-later (core: BUSL until 2023-04-01) | Factory `0x1F98431c8aD98523631AE4a59f267346ea31F984` | solc 0.7.6 | planned (Lane B) |
| E6 Universal Router | `Uniswap/universal-router` | GPL-3.0 | per release | solc 0.8.x | planned (Lane B) |
| E8 Safe v1.5.0 + ProxyFactory + fallback handler + MultiSend | `safe-global/safe-smart-account` | LGPL-3.0 | per release | solc 0.7.6 | planned (Lane A) |
| E11 ERC-4337 EntryPoint v0.8 + SimpleAccount | `eth-infinitism/account-abstraction` | GPL-3.0 | `0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108` | solc 0.8.28 | planned (Lane A) |
| E14 Morpho Blue | `morpho-org/morpho-blue` | GPL-2.0-or-later | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | solc 0.8.19 | planned (Lane C) |
| E16 Liquity V1 (file headers say MIT, repo says GPL: treated as GPL) | `liquity/dev` | GPL-3.0 | per contract | solc 0.6.11 | planned (Lane C) |
| E21 CoW Protocol GPv2Settlement | `cowprotocol/contracts` | LGPL-3.0 | `0x9008D19f58AAbD9eD0D60971565AA8510560ab41` | solc 0.7.6 | planned (Lane D) |
| E23 Balancer V2 Vault + WeightedPool | `balancer/balancer-v2-monorepo` | GPL-3.0 | Vault `0xBA12222222228d8Ba445958a75a0704d566BF2C8` | solc 0.7.1 | planned (Lane B) |
| E27 Gnosis Conditional Tokens (optional) | `gnosis/conditional-tokens-contracts` | LGPL-3.0 | — | solc 0.5.x | planned (Lane D) |

`planned` means the lane has not added the submodule yet. The Fidelity column gives the `proof/fidelity.py` verdict.
