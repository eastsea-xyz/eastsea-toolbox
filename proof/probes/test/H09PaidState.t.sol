// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeTest} from "./ProbeTest.sol";
import {H09PaidState} from "../src/H09PaidState.sol";

contract H09PaidStateTest is ProbeTest {
    H09PaidState h09;

    function setUp() public {
        h09 = new H09PaidState();
    }

    function test_H09_paidStateGas() external {
        h09.run();
    }
}
