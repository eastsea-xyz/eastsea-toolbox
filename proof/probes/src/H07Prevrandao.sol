// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeLib} from "./ProbeLib.sol";

/// @notice H7 — randomness: EastSea pins PREVRANDAO (0x44) to zero.
///
/// `Context::mainnet` never sets prevrandao, so block.prevrandao == 0 in every
/// block. Consequences pinned here:
///   - PREVRANDAO reads as 0;
///   - any raffle/reveal that mixes in prevrandao is fully predictable;
///   - randomness must come from the threshold-BLS beacon with commit-reveal
///     (toolbox #14 pattern), which is out of scope for this probe.
contract H07Prevrandao {
    event Observed(string what, bool ok, bytes returnValue);

    function run() external {
        uint256 r = block.prevrandao;
        ProbeLib.expectTrue(r == 0, "H07: prevrandao != 0 (EastSea pins it to zero)");
        emit Observed("prevrandao", r == 0, abi.encode(r));
    }

    /// A typical "random-ish" mint mixer must NOT be treated as random here.
    /// Returns the value a drop would draw today — constant zero.
    function drawWouldBe() external view returns (uint256) {
        return uint256(block.prevrandao);
    }
}
