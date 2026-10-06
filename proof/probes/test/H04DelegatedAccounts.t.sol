// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeTest} from "./ProbeTest.sol";
import {H04DelegatedAccounts} from "../src/H04DelegatedAccounts.sol";

contract H04DelegatedAccountsTest is ProbeTest {
    H04DelegatedAccounts h04;

    function setUp() public {
        h04 = new H04DelegatedAccounts();
    }

    function test_H04_receiverHooks() external {
        h04.run();
    }

    function test_H04_delegatedUserShape() external {
        address user = address(0xA11CE);
        VM.etch(user, h04.designatorFor(address(h04.noHookDelegate())));
        (uint256 size, bool isDesignator) = h04.delegatedCodeShape(user);
        check(size == 23, "designator must be 23 bytes");
        check(isDesignator, "designator must start 0xef0100");
        check(
            user.codehash == keccak256(h04.designatorFor(address(h04.noHookDelegate()))), "codehash = hash(designator)"
        );
    }

    function test_H04_safeMintToDelegatedUser() external {
        // Today's account shape (receive() only, B2 open): reverts.
        address today = address(0xA11CE);
        VM.etch(today, h04.designatorFor(address(h04.noHookDelegate())));
        h04.safeMintToDelegatedUser(today, 10, false);
        // B2-fixed shape: succeeds.
        address fixed_ = address(0xB0B);
        VM.etch(fixed_, h04.designatorFor(address(h04.hookDelegate())));
        h04.safeMintToDelegatedUser(fixed_, 11, true);
    }

    function test_H04_txOriginGuard() external {
        // A 7702 user calling directly: tx.origin == msg.sender holds.
        address user = address(0xA11CE);
        VM.etch(user, h04.designatorFor(address(h04.noHookDelegate())));
        address guard = address(h04.guard());
        VM.startPrank(user, user);
        (bool ok,) = guard.call(abi.encodeWithSignature("check()"));
        VM.stopPrank();
        check(ok, "guard must pass when tx.origin == msg.sender");
        // A contract fronting the call: guard rejects.
        (ok,) = guard.call(abi.encodeWithSignature("check()"));
        check(!ok, "guard must fail for a contract caller");
    }
}
