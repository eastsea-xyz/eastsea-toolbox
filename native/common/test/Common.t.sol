// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {ExactToken} from "../src/ExactToken.sol";
import {NativeBrake} from "../src/NativeBrake.sol";
import {INativeBrake} from "../src/INativeBrake.sol";
import {TransientLock} from "../src/TransientLock.sol";
import {TestToken, FeeOnTransferToken, LyingToken, FalseReturnToken} from "./Tokens.sol";

contract ExactTokenHarness {
    function pull(address token, address from, uint256 amount) external {
        ExactToken.pullExact(token, from, amount);
    }

    function push(address token, address to, uint256 amount) external {
        ExactToken.pushExact(token, to, amount);
    }

    function pushNative(address to, uint256 amount) external {
        ExactToken.pushNative(to, amount);
    }

    receive() external payable {}
}

contract BrakeHarness is NativeBrake, TransientLock {
    uint8 public reasons;
    uint64 private since;
    uint256 public entries;

    constructor() NativeBrake(keccak256("doc")) {}

    function setReasons(uint8 r) external {
        reasons = r;
    }

    function enter() external lock {
        _requireEntryOpen();
        entries++;
    }

    function reenter() external lock {
        this.enter();
    }

    function _brakeReasons() internal view override returns (uint8) {
        return reasons;
    }

    function _brakeSince() internal view override returns (uint64) {
        return since;
    }

    function _setBrakeSince(uint64 h) internal override {
        since = h;
    }

    function _brakeUri() internal pure override returns (string memory) {
        return "native/common/SECURITY.md#brake";
    }
}

contract Rejector {
    receive() external payable {
        revert("no");
    }
}

contract CommonTest is Test {
    ExactTokenHarness h;
    TestToken t;

    function setUp() public {
        h = new ExactTokenHarness();
        t = new TestToken();
        t.mint(address(this), 1e24);
        t.approve(address(h), type(uint256).max);
    }

    function test_pullExact_plainToken() public {
        h.pull(address(t), address(this), 100);
        assertEq(t.balanceOf(address(h)), 100);
    }

    function test_pullExact_rejectsFeeOnTransfer() public {
        FeeOnTransferToken f = new FeeOnTransferToken();
        f.mint(address(this), 1000);
        f.approve(address(h), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ExactToken.NotExactTransfer.selector, 1000, 990));
        h.pull(address(f), address(this), 1000);
    }

    function test_pullExact_rejectsNoopTrue() public {
        LyingToken l = new LyingToken();
        l.mint(address(this), 1000);
        l.approve(address(h), type(uint256).max);
        l.setLying(true);
        vm.expectRevert(abi.encodeWithSelector(ExactToken.NotExactTransfer.selector, 1000, 0));
        h.pull(address(l), address(this), 1000);
    }

    function test_pullExact_rejectsCodeless() public {
        vm.expectRevert();
        h.pull(address(0xBEEF), address(this), 1);
    }

    function test_pushExact_rejectsFalseReturn() public {
        FalseReturnToken f = new FalseReturnToken();
        f.mint(address(h), 1000);
        f.setFail(true);
        vm.expectRevert(abi.encodeWithSelector(ExactToken.TokenCallFailed.selector, address(f)));
        h.push(address(f), address(1), 10);
    }

    function test_pushExact_rejectsOutboundFee() public {
        FeeOnTransferToken f = new FeeOnTransferToken();
        f.mint(address(h), 1000);
        vm.expectRevert();
        h.push(address(f), address(1), 1000);
    }

    function test_pushExact_rejectsSelf() public {
        vm.expectRevert(ExactToken.SelfTransfer.selector);
        h.push(address(t), address(h), 1);
    }

    function test_pushNative_revertingRecipient() public {
        vm.deal(address(h), 1 ether);
        Rejector r = new Rejector();
        vm.expectRevert(abi.encodeWithSelector(ExactToken.NativeTransferFailed.selector, address(r), 1));
        h.pushNative(address(r), 1);
    }

    function test_brake_requiresPredicate() public {
        BrakeHarness b = new BrakeHarness();
        vm.expectRevert(INativeBrake.BrakePredicateFalse.selector);
        b.tripBrake();
        (uint8 s, address g, uint64 since) = b.brakeState();
        assertEq(s, 0);
        assertEq(g, address(0));
        assertEq(since, 0);
        b.enter();
    }

    function test_brake_liveThenLatchedIsPermanent() public {
        BrakeHarness b = new BrakeHarness();
        b.setReasons(2);
        (uint8 s,, uint64 since) = b.brakeState();
        assertEq(s, 1);
        assertEq(since, 0);
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.EntryBraked.selector, 2, 0));
        b.enter();
        vm.roll(77);
        b.tripBrake();
        b.setReasons(0); // predicate recovers ...
        (s,, since) = b.brakeState();
        assertEq(s, 1); // ... but the latch stays
        assertEq(since, 77);
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.EntryBraked.selector, 0, 77));
        b.enter();
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.BrakeAlreadyLatched.selector, 77));
        b.tripBrake();
        (string memory uri, bytes32 doc) = b.brakeSpec();
        assertEq(uri, "native/common/SECURITY.md#brake");
        assertEq(doc, keccak256("doc"));
    }

    function test_transientLock_blocksReentry_andClears() public {
        BrakeHarness b = new BrakeHarness();
        vm.expectRevert(TransientLock.Reentrancy.selector);
        b.reenter();
        b.enter();
        b.enter(); // lock cleared after each call
        assertEq(b.entries(), 2);
    }
}
