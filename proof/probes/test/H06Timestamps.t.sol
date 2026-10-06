// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeTest} from "./ProbeTest.sol";
import {H06Timestamps} from "../src/H06Timestamps.sol";

contract H06TimestampsTest is ProbeTest {
    H06Timestamps h06;

    function setUp() public {
        h06 = new H06Timestamps();
    }

    function test_H06_nonDecreasingWithEqualSeconds() external {
        h06.step();
        VM.roll(block.number + 1); // same second
        h06.step();
        VM.roll(block.number + 1);
        VM.warp(block.timestamp + 1);
        h06.step();
        h06.run();
        check(h06.equalSteps() == 1, "one equal-timestamp step recorded");
    }

    function test_H06_decreasingRejected() external {
        VM.warp(1_000);
        h06.step();
        VM.roll(block.number + 1);
        VM.warp(999);
        (bool ok,) = address(h06).call(abi.encodeWithSignature("step()"));
        check(!ok, "a decreasing timestamp must revert");
    }
}
