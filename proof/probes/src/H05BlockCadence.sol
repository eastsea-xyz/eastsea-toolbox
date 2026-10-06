// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeLib} from "./ProbeLib.sol";

/// @notice H5 — block cadence. EastSea targets ~1 s blocks, so block.number
/// advances ~12x faster than on Ethereum. Contracts that hard-code a
/// blocks-per-year constant (Compound V2 `blocksPerYear = 2_102_400`, OZ
/// Governor block clock, MasterChef per-block rewards) misprice time unless
/// their deploy parameters are rescaled.
///
/// Harness use: call `observe()` in one block, then `run()` in a later block.
/// `run()` reverts unless the observed seconds-per-block lies within
/// [MIN_MS, MAX_MS] milliseconds (EastSea pin: 1 s, tolerance 0.5-2 s).
contract H05BlockCadence {
    event Observed(string what, bool ok, bytes returnValue);

    uint256 public constant MIN_MS = 500;
    uint256 public constant MAX_MS = 2000;
    /// Compound V2 JumpRateModelV2 assumption (Ethereum, ~15 s blocks).
    uint256 public constant COMPOUND_BLOCKS_PER_YEAR = 2_102_400;

    uint256 public firstBlock;
    uint256 public firstTime;

    function observe() external {
        firstBlock = block.number;
        firstTime = block.timestamp;
    }

    /// Milliseconds per block since `observe()`.
    function msPerBlock() public view returns (uint256) {
        uint256 blocks = block.number - firstBlock;
        ProbeLib.expectTrue(blocks > 0, "H05: run() needs a later block than observe()");
        return ((block.timestamp - firstTime) * 1000) / blocks;
    }

    /// Blocks per year at the observed cadence (365 days).
    function blocksPerYear() public view returns (uint256) {
        return (365 days * 1000) / msPerBlock();
    }

    function run() external {
        uint256 ms = msPerBlock();
        emit Observed("ms_per_block", ms >= MIN_MS && ms <= MAX_MS, abi.encode(ms));
        emit Observed("blocks_per_year", true, abi.encode(blocksPerYear()));
        ProbeLib.expectTrue(ms >= MIN_MS && ms <= MAX_MS, "H05: cadence outside 0.5-2 s per block");
    }
}
