// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeTest} from "./ProbeTest.sol";
import {H01Opcodes} from "../src/H01Opcodes.sol";

contract H01OpcodesTest is ProbeTest {
    H01Opcodes h01;

    function setUp() public {
        h01 = new H01Opcodes();
    }

    function test_H01_opcodes() external {
        h01.run();
    }
}
