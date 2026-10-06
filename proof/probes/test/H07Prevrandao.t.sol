// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeTest} from "./ProbeTest.sol";
import {H07Prevrandao} from "../src/H07Prevrandao.sol";

contract H07PrevrandaoTest is ProbeTest {
    H07Prevrandao h07;

    function setUp() public {
        h07 = new H07Prevrandao();
    }

    function test_H07_prevrandaoPinnedToZero() external {
        VM.prevrandao(bytes32(0)); // EastSea: prevrandao = 0 every block
        h07.run();
        check(h07.drawWouldBe() == 0, "draw must be 0");
        VM.roll(block.number + 1);
        VM.prevrandao(bytes32(0));
        h07.run();
    }

    function test_Ethereum_H07_prevrandaoRejected() external {
        VM.prevrandao(bytes32(uint256(0xbeac0)));
        (bool ok,) = address(h07).call(abi.encodeWithSignature("run()"));
        check(!ok, "non-zero prevrandao must fail the EastSea pin");
    }
}
