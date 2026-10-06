// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeTest} from "./ProbeTest.sol";
import {H02Precompiles} from "../src/H02Precompiles.sol";

contract H02PrecompilesTest is ProbeTest {
    H02Precompiles h02;

    function setUp() public {
        h02 = new H02Precompiles();
    }

    function test_H02_precompiles() external {
        h02.run();
    }
}
