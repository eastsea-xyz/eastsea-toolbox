# originals/agpl — AGPL-3.0

**This folder holds unmodified upstream source at `<repo>@<commit>`: one git submodule per item, each pinned to the exact commit. It is for test and benchmark use only and is provided AS IS, with no warranty.**

You may copy, publish and deploy these items. The AGPL requires an offer of source to network users; that has no effect here, because we host nothing. **Never import AGPL code (for example Solmate) into the MIT `examples/`.** The toolbox uses OpenZeppelin 5.1.0 only.

Each item keeps its upstream LICENSE and copyright notices inside its submodule, and those govern the item. The `LICENSE` in this folder is the AGPL-3.0 text; it applies to our tests and scripts here.

## Items

| Item (catalog) | Upstream repo @ commit | Licence | Mainnet address | Compiler | Fidelity |
|---|---|---|---|---|---|
| E17 Yearn V3 VaultV3.vy | `yearn/yearn-vaults-v3` | AGPL-3.0 | per vault | vyper 0.3.7 | planned (Lane C) |
| E25 MakerDAO DSS (Vat, Jug, Spot, Join, Dai, Dog/Clipper; stretch) | `makerdao/dss` | AGPL-3.0 | per contract | solc 0.6.12 | planned (Lane C) |

`planned` means the lane has not added the submodule yet.
