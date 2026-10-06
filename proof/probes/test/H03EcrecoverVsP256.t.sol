// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeTest} from "./ProbeTest.sol";
import {H03EcrecoverVsP256} from "../src/H03EcrecoverVsP256.sol";

contract H03EcrecoverVsP256Test is ProbeTest {
    H03EcrecoverVsP256 h03;

    function setUp() public {
        h03 = new H03EcrecoverVsP256();
    }

    function test_H03_signatures() external {
        h03.run();
        check(
            h03.p256AccountAddress() != 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf,
            "P-256 account address equals the secp256k1 d=1 address"
        );
    }
}
