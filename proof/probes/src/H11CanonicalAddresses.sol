// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeLib} from "./ProbeLib.sol";

/// @notice H11 — canonical addresses. On Ethereum these contracts were placed
/// by keyless presigned legacy (RLP) transactions or by the CREATE2 deployer.
/// EastSea envelopes are not RLP and genesis has no predeploys (catalog B3),
/// so today every address below is expected to be EMPTY on EastSea.
///
/// Two checks:
///   - `run()` reverts only if an address holds code whose hash differs from
///     Ethereum mainnet: wrong code at a well-known address is the dangerous
///     case (tooling such as viem and forge scripts trusts these addresses).
///   - `presentMask()` returns which ones exist. The Foundry runner pins
///     "all absent" (B3 open). When the genesis allocation lands, flip the
///     runner expectation; `run()` then proves the hashes equal mainnet.
///
/// Mainnet hashes: keccak256(eth_getCode) at block "latest" on 2026-10-06
/// (proof/mainnet-code/ holds the cached bytes for the fidelity script).
contract H11CanonicalAddresses {
    event Observed(string what, bool ok, bytes returnValue);

    struct Canon {
        string name;
        address at;
        bytes32 mainnetHash;
    }

    function canon() public pure returns (Canon[5] memory c) {
        c[0] = Canon(
            "multicall3",
            0xcA11bde05977b3631167028862bE2a173976CA11,
            0xd5c15df687b16f2ff992fc8d767b4216323184a2bbc6ee2f9c398c318e770891
        );
        c[1] = Canon(
            "create2-deployer-arachnid",
            0x4e59b44847b379578588920cA78FbF26c0B4956C,
            0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989
        );
        c[2] = Canon(
            "safe-singleton-factory",
            0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7,
            0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989
        );
        c[3] = Canon(
            "permit2",
            0x000000000022D473030F116dDEE9F6B43aC78BA3,
            0xc67d1657868aa5146eaf24fb879fb1fdec3d2d493b3683a61c9c2f4fb2851131
        );
        c[4] = Canon(
            "entrypoint-v0.8",
            0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108,
            0x44e632a24c6f2600cbd5b5b8b4c2d372359112c8b5774297f5fd0a9e64f11f86
        );
    }

    /// Bit i set = canon()[i] has code.
    function presentMask() public view returns (uint256 mask) {
        Canon[5] memory c = canon();
        for (uint256 i = 0; i < c.length; ++i) {
            if (c[i].at.code.length > 0) mask |= 1 << i;
        }
    }

    function run() external {
        Canon[5] memory c = canon();
        for (uint256 i = 0; i < c.length; ++i) {
            bool present = c[i].at.code.length > 0;
            bool same = present && c[i].at.codehash == c[i].mainnetHash;
            emit Observed(c[i].name, !present || same, abi.encode(present, c[i].at.codehash));
            if (present) {
                ProbeLib.expectEq(c[i].at.codehash, c[i].mainnetHash, string.concat("H11: wrong code at ", c[i].name));
            }
        }
    }
}
