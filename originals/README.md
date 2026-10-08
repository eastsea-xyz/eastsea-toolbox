# originals/ — unmodified upstream contracts (compatibility proof)

Track 1 of the proof (clone catalog §8). Each folder holds **unmodified upstream source**, pinned to an exact commit, so anyone can check that the code tested on EastSea is the code Ethereum runs (`proof/fidelity.py`). The better EastSea-native designs are Track 2 and live in `native/`, not here.

> [!WARNING]
> **Provided AS IS, with no warranty of any kind.** The originals are here only for **tests and benchmarks**. We do not deploy, host or operate them, and we run no front end for them. Anyone who deploys or uses this code does so at their own responsibility. Admin roles that the originals have (Aave ACL, Compound admin, Maker `auth`, Chainlink owner) are held by a throwaway test deployer in our runs. Protocol names identify the original work only. They do not imply endorsement by its authors.

## Folders by licence class (catalog §4)

| Folder | Licences | What we may do | Rule |
|---|---|---|---|
| `mit/` | MIT, BSD-3-Clause, Apache-2.0, Unlicense | copy, publish, deploy | keep each original's copyright notice |
| `gpl/` | GPL-2.0-or-later, GPL-3.0, LGPL-3.0 | copy, publish, deploy | our tests and scripts in this folder are **GPL-3.0-or-later** |
| `agpl/` | AGPL-3.0 | copy, publish, deploy (with a network-use source offer, which is moot because we host nothing) | never import AGPL code (e.g. Solmate) into the MIT `examples/` |
| `busl/` | BUSL-1.1, still active | copy, redistribute, **non-production use only** | submodules only, nothing modified; tests and testnets only, no mainnet deployment |

Each folder has the licence text (`LICENSE`) and a `README.md` that lists its items. The toolbox root stays MIT. Code with no licence or a proprietary licence (Curve, Orca, Marinade, Metaplex, Jupiter, pump.fun) is **never** copied. Its behaviour is rebuilt clean-room under `../clones/`.

Originals remain fidelity references, outside the 17 executable publisher
examples. Mainnet personal publishing never deploys a bare original:
`PersonalTestDeployer` rejects unguarded creation bytecode atomically. Keep
all original code/pins/fidelity artifacts unchanged; future adapters must
meet the [complete personal graph policy](../docs/personal-mainnet-testing.md#originals-and-clones).
A proxy that leaves the original directly usable is not a deployment guard.

## Adding an item (lanes A–D)

1. `git submodule add <repo> originals/<class>/<item>`, then check out the exact commit used for the mainnet deployment.
2. Add a row to `<class>/README.md` with: upstream repo, commit, licence, mainnet address and compiler settings.
3. Add `proof/fidelity/items/<item>.json` and run `proof/fidelity.py --fetch <item>`. Commit the cached `proof/mainnet-code/*.hex`.
4. Put behaviour tests in `originals/<class>/test/<item>/`. They take the folder's licence.
5. Build with the profile for the item's compiler (below). Record the results in `proof/REPORT.md` and the benchmark in `proof/bench/`.

## Compiler profiles (`foundry.toml`)

Every compiler setting the catalog lists has a Foundry profile, and lanes select files with `--contracts`/`--match-path`:

```bash
FOUNDRY_PROFILE=solc-0_5_16 forge build --root originals --contracts gpl/uniswap-v2-core/contracts
```

| Profile | solc | Optimizer | EVM | Items (catalog) |
|---|---|---|---|---|
| `solc-0_4_19` | 0.4.19 | off | byzantium | E3 WETH9 |
| `solc-0_5_16` | 0.5.16 | 999,999 | istanbul | E4 Uniswap V2 core |
| `solc-0_6_6` | 0.6.6 | 999,999 | istanbul | E4 Uniswap V2 Router02 |
| `solc-0_6_11` | 0.6.11 | 100 (unverified) | istanbul | E16 Liquity V1 |
| `solc-0_6_12` | 0.6.12 | 200 (unverified) | istanbul | E25 Maker DSS |
| `solc-0_7_6` | 0.7.6 | 800 (core) | istanbul | E5 Uniswap V3, E8 Safe |
| `solc-0_8` | per pragma (auto-detect) | 200 | cancun | E7, E9–E14, E17–E23, E27, E28 |
| (Vyper) | vyper 0.3.7 | — | — | E17 Yearn V3: built by `proof/fidelity.py` with `vyper` on `PATH`; Foundry is not used |

The profile values are starting points. The exact per-contract settings (for example V3 periphery `runs`, or Seaport `viaIR`) are in each item's fidelity manifest, and the fidelity check is what proves them.
