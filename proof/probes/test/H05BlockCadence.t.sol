// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeTest} from "./ProbeTest.sol";
import {H05BlockCadence} from "../src/H05BlockCadence.sol";

contract H05BlockCadenceTest is ProbeTest {
    H05BlockCadence h05;

    function setUp() public {
        h05 = new H05BlockCadence();
    }

    function test_H05_eastSeaCadence() external {
        h05.observe();
        VM.roll(block.number + 86_400);
        VM.warp(block.timestamp + 86_400); // 1 s blocks for a day
        h05.run();
        check(h05.blocksPerYear() == 31_536_000, "1 s blocks: 31,536,000 per year");
        // Compound V2's constant assumes ~15x fewer blocks: rates x15.
        check(h05.blocksPerYear() / h05.COMPOUND_BLOCKS_PER_YEAR() == 15, "Compound V2 rescale factor");
    }

    function test_Ethereum_H05_cadenceRejected() external {
        h05.observe();
        VM.roll(block.number + 100);
        VM.warp(block.timestamp + 1_200); // 12 s blocks
        (bool ok,) = address(h05).call(abi.encodeWithSignature("run()"));
        check(!ok, "12 s blocks must fail the EastSea cadence pin");
    }
}
