# originals/busl — BUSL-1.1 (still active): non-production use only

**Unmodified upstream source at `<repo>@<commit>` (git submodules only, pinned to the exact commit). Test and testnet use only. Provided AS IS, with no warranty.**

BUSL-1.1 lets anyone copy, modify and redistribute the code, but only for **non-production use**. Our rules for this folder:
- These items run **only in tests and on testnets**.
- Nobody deploys them to mainnet on our instructions.
- Items are added **only as submodules**, so we redistribute nothing modified.

Open legal question (catalog §4): does a public testnet benchmark count as "non-production"?

`LICENSE` in this folder contains the BUSL-1.1 terms that every item shares. Each item's own Parameters (licensor, change date, change licence) are in the LICENSE file inside its submodule, and those Parameters govern that item.

## Items

| Item (catalog) | Upstream repo @ commit | Licence | Mainnet address | Compiler | Fidelity |
|---|---|---|---|---|---|
| E6 Uniswap V4 PoolManager (becomes MIT on the earlier of 2027-06-15 or the ENS-set date) | `Uniswap/v4-core` | BUSL-1.1 | `0x000000000004444c5dc75cB358380D2e3dE08A90` | solc 0.8.26, cancun | planned (Lane B) |
| E22 Sablier Lockup (BUSL until 2029-07-01) | `sablier-labs/lockup` | BUSL-1.1 | per release | solc 0.8.x | planned (Lane D) |

`planned` means the lane has not added the submodule yet.
