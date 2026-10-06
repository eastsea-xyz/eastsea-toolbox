// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeLib} from "./ProbeLib.sol";

/// @notice H6 — timestamps. Consensus sets block.timestamp; with ~1 s blocks
/// two consecutive blocks may share a second. Pinned property: the timestamp
/// never decreases. Equal timestamps are allowed and counted, because TWAP
/// oracles (Uniswap V2 `timeElapsed > 0`, V3 observations) take a different
/// branch when they occur.
///
/// Harness use: call `step()` once per block over a run of blocks, then
/// `run()`. Each step reverts at once if the timestamp went backwards.
contract H06Timestamps {
    event Observed(string what, bool ok, bytes returnValue);

    uint256 public lastNumber;
    uint256 public lastTime;
    uint256 public steps;
    uint256 public equalSteps;

    function step() external {
        if (steps > 0) {
            ProbeLib.expectTrue(block.number > lastNumber, "H06: step() twice in one block");
            ProbeLib.expectTrue(block.timestamp >= lastTime, "H06: timestamp decreased");
            if (block.timestamp == lastTime) ++equalSteps;
        }
        lastNumber = block.number;
        lastTime = block.timestamp;
        ++steps;
    }

    function run() external {
        ProbeLib.expectTrue(steps >= 2, "H06: run() needs at least two step() blocks");
        emit Observed("steps", true, abi.encode(steps));
        emit Observed("equal_timestamp_steps", true, abi.encode(equalSteps));
    }
}
