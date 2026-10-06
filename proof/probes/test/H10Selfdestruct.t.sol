// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeTest} from "./ProbeTest.sol";
import {H10Selfdestruct, SelfdestructVictim} from "../src/H10Selfdestruct.sol";

contract H10SelfdestructTest is ProbeTest {
    H10Selfdestruct h10;
    SelfdestructVictim victim;

    function setUp() public {
        h10 = new H10Selfdestruct();
        // Deployed in setUp (an earlier "tx") so the test destructs it
        // from a later one: EIP-6780 cross-tx semantics.
        victim = new SelfdestructVictim();
    }

    function test_H10_selfdestructCrossTxPersists() external {
        h10.checkCrossTxDestruct(victim);
    }

    function test_H10_selfdestructSameTx() external {
        h10.run();
    }
}
