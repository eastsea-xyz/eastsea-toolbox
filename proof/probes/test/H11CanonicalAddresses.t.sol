// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeTest} from "./ProbeTest.sol";
import {H11CanonicalAddresses} from "../src/H11CanonicalAddresses.sol";

contract H11CanonicalAddressesTest is ProbeTest {
    H11CanonicalAddresses h11;

    function setUp() public {
        h11 = new H11CanonicalAddresses();
    }

    function test_H11_canonicalAddressesAbsent() external {
        // Foundry predeploys the Arachnid CREATE2 deployer at 0x4e59...;
        // EastSea genesis does not (B3). Stage EastSea's empty state.
        VM.etch(0x4e59b44847b379578588920cA78FbF26c0B4956C, "");
        h11.run(); // nothing present -> nothing wrong
        check(h11.presentMask() == 0, "B3 open: no canonical predeploys expected");
    }

    function test_Foundry_H11_create2DeployerIsMainnetCode() external {
        h11.run(); // Foundry's predeploy hashes equal to mainnet
        check(h11.presentMask() == 2, "Foundry: only the CREATE2 deployer is predeployed");
    }

    function test_H11_wrongCodeAtCanonicalAddressRejected() external {
        VM.etch(0xcA11bde05977b3631167028862bE2a173976CA11, hex"00");
        (bool ok,) = address(h11).call(abi.encodeWithSignature("run()"));
        check(!ok, "foreign code at the Multicall3 address must be flagged");
    }
}
