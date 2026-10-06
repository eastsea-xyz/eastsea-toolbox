// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeTest} from "./ProbeTest.sol";
import {H08CodeLimits} from "../src/H08CodeLimits.sol";

contract H08CodeLimitsTest is ProbeTest {
    H08CodeLimits h08;

    function setUp() public {
        h08 = new H08CodeLimits();
    }

    function test_H08_limits() external {
        h08.run();
    }
}
