// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {GrantLedger} from "../src/GrantLedger.sol";
import {INativeBrake} from "../../common/src/INativeBrake.sol";
import {ExactToken} from "../../common/src/ExactToken.sol";
import {TransientLock} from "../../common/src/TransientLock.sol";
import {TestToken, FeeOnTransferToken, BlockingToken, CallbackToken} from "../../common/test/Tokens.sol";
import {SlotDiff} from "../../common/test/SlotDiff.sol";

abstract contract GrantsBase is Test {
    TestToken token;
    GrantLedger ledger;
    address employer = makeAddr("employer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address relayer = makeAddr("relayer");

    uint32 constant T0 = 1_000_000;

    function _deploy(TestToken t) internal {
        token = t;
        ledger = new GrantLedger(address(t), keccak256("brake-doc"));
        t.mint(employer, type(uint128).max);
        vm.prank(employer);
        t.approve(address(ledger), type(uint256).max);
        vm.warp(T0);
    }

    function _p(address b, uint128 total, uint32 start, uint32 cliff, uint32 end)
        internal
        pure
        returns (GrantLedger.GrantParams memory)
    {
        return GrantLedger.GrantParams({beneficiary: b, total: total, start: start, cliff: cliff, end: end});
    }

    function _grant(address b, uint128 total, uint32 cliff, uint32 end) internal returns (uint256 id) {
        vm.prank(employer);
        id = ledger.create(_p(b, total, T0, cliff, end));
    }
}

contract GrantLedgerCreateTest is GrantsBase {
    function setUp() public {
        _deploy(new TestToken());
    }

    function test_runtimeWithinEip170() public view {
        assertLe(address(ledger).code.length, 24576);
    }

    function test_constructor_rejectsCodelessToken() public {
        vm.expectRevert(GrantLedger.TokenHasNoCode.selector);
        new GrantLedger(address(0xdead), 0);
    }

    function test_create_twoWordsExactPull() public {
        SlotDiff.start();
        uint256 id = _grant(alice, 1000e18, T0 + 100, T0 + 1100);
        SlotDiff.Count memory c = SlotDiff.stop(address(ledger));
        assertEq(c.occupied, 2, "S0 + S1; M0 already occupied");
        assertEq(id, 1);
        assertEq(ledger.nextId(), 2);
        assertEq(ledger.outstanding(), 1000e18);
        assertEq(token.balanceOf(address(ledger)), 1000e18);
        GrantLedger.Grant memory g = ledger.grant(id);
        assertEq(g.beneficiary, alice);
        assertEq(g.total, 1000e18);
        assertEq(g.released, 0);
        assertEq(g.cliff, T0 + 100);
        assertEq(g.end, T0 + 1100);
    }

    function test_create_validation() public {
        vm.startPrank(employer);
        vm.expectRevert(GrantLedger.BadBeneficiary.selector);
        ledger.create(_p(address(0), 1, 0, 0, 1));
        vm.expectRevert(GrantLedger.BadBeneficiary.selector);
        ledger.create(_p(address(ledger), 1, 0, 0, 1));
        vm.expectRevert(GrantLedger.ZeroAmount.selector);
        ledger.create(_p(alice, 0, 0, 0, 1));
        vm.expectRevert(abi.encodeWithSelector(GrantLedger.BadSchedule.selector, 5, 4, 10));
        ledger.create(_p(alice, 1, 5, 4, 10));
        vm.expectRevert(abi.encodeWithSelector(GrantLedger.BadSchedule.selector, 0, 10, 10));
        ledger.create(_p(alice, 1, 0, 10, 10));
        ledger.create(_p(alice, type(uint128).max - 1, 0, 0, 1));
        vm.expectRevert(GrantLedger.OutstandingOverflow.selector);
        ledger.create(_p(alice, 2, 0, 0, 1));
        vm.stopPrank();
    }

    function test_create_rejectsFeeOnTransferAsset() public {
        _deploy(new FeeOnTransferToken());
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(ExactToken.NotExactTransfer.selector, 1000, 990));
        ledger.create(_p(alice, 1000, 0, 0, 1));
        assertEq(ledger.outstanding(), 0);
        assertEq(ledger.nextId(), 1);
    }

    function test_createBatch_singlePullUpToEight() public {
        GrantLedger.GrantParams[] memory ps = new GrantLedger.GrantParams[](8);
        uint256 sum;
        for (uint256 i; i < 8; i++) {
            ps[i] = _p(address(uint160(0x1000 + i)), uint128(100 + i), T0, T0, T0 + 10);
            sum += 100 + i;
        }
        vm.prank(employer);
        uint256 first = ledger.createBatch(ps);
        assertEq(first, 1);
        assertEq(ledger.nextId(), 9);
        assertEq(ledger.outstanding(), sum);
        assertEq(token.balanceOf(address(ledger)), sum);
        assertEq(ledger.grant(8).beneficiary, address(0x1007));

        GrantLedger.GrantParams[] memory nine = new GrantLedger.GrantParams[](9);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(GrantLedger.BadBatchSize.selector, 9));
        ledger.createBatch(nine);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(GrantLedger.BadBatchSize.selector, 0));
        ledger.createBatch(new GrantLedger.GrantParams[](0));
    }

    function test_createBatch_oneBadEntryRevertsAll() public {
        GrantLedger.GrantParams[] memory ps = new GrantLedger.GrantParams[](2);
        ps[0] = _p(alice, 10, 0, 0, 1);
        ps[1] = _p(bob, 0, 0, 0, 1);
        uint256 bal = token.balanceOf(employer);
        vm.prank(employer);
        vm.expectRevert(GrantLedger.ZeroAmount.selector);
        ledger.createBatch(ps);
        assertEq(token.balanceOf(employer), bal);
        assertEq(ledger.nextId(), 1);
    }
}

contract GrantLedgerScheduleTest is GrantsBase {
    function setUp() public {
        _deploy(new TestToken());
    }

    function test_schedule_boundaries() public {
        uint256 id = _grant(alice, 1000, T0 + 100, T0 + 1100);
        assertEq(ledger.earnedAt(id, T0), 0);
        assertEq(ledger.earnedAt(id, T0 + 100), 0, "zero at the cliff: no catch-up");
        assertEq(ledger.earnedAt(id, T0 + 101), 1);
        assertEq(ledger.earnedAt(id, T0 + 600), 500);
        assertEq(ledger.earnedAt(id, T0 + 1099), 999);
        assertEq(ledger.earnedAt(id, T0 + 1100), 1000);
        assertEq(ledger.earnedAt(id, type(uint256).max), 1000);
    }

    function test_schedule_roundsDown() public {
        uint256 id = _grant(alice, 10, T0, T0 + 3);
        assertEq(ledger.earnedAt(id, T0 + 1), 3); // 10/3 = 3.33
        assertEq(ledger.earnedAt(id, T0 + 2), 6); // 6.67
        assertEq(ledger.earnedAt(id, T0 + 3), 10);
    }

    /// Regression for the TokenVesting overflow class (2026-10-06): the
    /// largest grant over the longest schedule, evaluated mid-way and past
    /// 2106, neither overflows nor wraps the timestamp.
    function test_schedule_maxGrantNoOverflow() public {
        uint128 total = type(uint128).max;
        vm.prank(employer);
        uint256 id = ledger.create(_p(alice, total, 0, 0, type(uint32).max));
        uint256 mid = uint256(type(uint32).max) / 2;
        assertEq(ledger.earnedAt(id, mid), uint256(total) * mid / type(uint32).max);
        uint256 m = type(uint32).max;
        assertEq(ledger.earnedAt(id, m - 1), uint256(total) * (m - 1) / m);
        assertLt(ledger.earnedAt(id, m - 1), total);
        vm.warp(uint256(type(uint32).max) + 1 days); // beyond uint32 seconds
        assertEq(ledger.claimable(id), total);
        ledger.claim(id);
        assertEq(token.balanceOf(alice), total);
        assertEq(ledger.outstanding(), 0);
    }

    function test_claim_relayedToBeneficiary_partialThenFinalDeletes() public {
        uint256 id = _grant(alice, 1000, T0, T0 + 1000);
        vm.warp(T0 + 250);
        vm.prank(relayer);
        assertEq(ledger.claim(id), 250);
        assertEq(token.balanceOf(alice), 250);
        assertEq(token.balanceOf(relayer), 0);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(GrantLedger.NothingToClaim.selector, id));
        ledger.claim(id); // same timestamp: nothing new, no misleading event

        vm.warp(T0 + 2000);
        SlotDiff.start();
        assertEq(ledger.claim(id), 750);
        SlotDiff.Count memory c = SlotDiff.stop(address(ledger));
        assertEq(c.cleared, 2, "final payout retires S0 and S1");
        assertEq(token.balanceOf(alice), 1000);
        assertEq(ledger.outstanding(), 0);
        vm.expectRevert(abi.encodeWithSelector(GrantLedger.UnknownGrant.selector, id));
        ledger.claim(id);
        // The id is never reissued: a new grant gets the next id.
        assertEq(_grant(bob, 1, T0, T0 + 1), id + 1);
    }

    function test_claim_beforeCliffReverts() public {
        uint256 id = _grant(alice, 1000, T0 + 100, T0 + 200);
        vm.warp(T0 + 100);
        vm.expectRevert(abi.encodeWithSelector(GrantLedger.NothingToClaim.selector, id));
        ledger.claim(id);
    }

    function test_noCancellation_creatorHasNoPower() public {
        uint256 id = _grant(alice, 1000, T0, T0 + 1000);
        // No cancel/revoke/withdraw/sweep entry exists.
        bytes4[4] memory sels = [
            bytes4(keccak256("cancel(uint256)")),
            bytes4(keccak256("revoke(uint256)")),
            bytes4(keccak256("withdraw(uint256)")),
            bytes4(keccak256("sweep(address)"))
        ];
        for (uint256 i; i < 4; i++) {
            vm.prank(employer);
            (bool ok,) = address(ledger).call(abi.encodeWithSelector(sels[i], id));
            assertFalse(ok);
        }
        vm.warp(T0 + 1000);
        vm.prank(employer);
        ledger.claim(id); // the creator can only pay the beneficiary
        assertEq(token.balanceOf(alice), 1000);
    }

    function test_donationDoesNotChangeEntitlements() public {
        uint256 id = _grant(alice, 1000, T0, T0 + 1000);
        token.mint(address(ledger), 5000);
        vm.warp(T0 + 500);
        assertEq(ledger.claimable(id), 500);
        ledger.claim(id);
        vm.warp(T0 + 1000);
        ledger.claim(id);
        assertEq(token.balanceOf(alice), 1000);
        assertEq(token.balanceOf(address(ledger)), 5000);
    }

    function test_blockedBeneficiaryKeepsRight() public {
        BlockingToken bt = new BlockingToken();
        _deploy(bt);
        uint256 id = _grant(alice, 1000, T0, T0 + 1000);
        vm.warp(T0 + 1000);
        bt.setBlocked(alice, true);
        vm.expectRevert();
        ledger.claim(id);
        assertEq(ledger.grant(id).released, 0);
        assertEq(ledger.outstanding(), 1000);
        bt.setBlocked(alice, false);
        ledger.claim(id);
        assertEq(bt.balanceOf(alice), 1000);
    }
}

contract GrantLedgerBrakeTest is GrantsBase {
    function setUp() public {
        _deploy(new TestToken());
    }

    function test_brake_deficitBlocksEntryAndUnbackedPayouts() public {
        uint256 a = _grant(alice, 1000, T0, T0 + 1000);
        uint256 b = _grant(bob, 1000, T0, T0 + 1000);
        vm.expectRevert(INativeBrake.BrakePredicateFalse.selector);
        ledger.tripBrake();

        token.burnFrom(address(ledger), 1);
        assertEq(ledger.brakePredicate(), 2);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.EntryBraked.selector, 2, 0));
        ledger.create(_p(alice, 1, 0, 0, 1));
        vm.roll(42);
        ledger.tripBrake();

        vm.warp(T0 + 1000);
        vm.expectRevert();
        ledger.claim(a); // would take bob's backing
        token.mint(address(ledger), 1); // anyone recapitalises
        ledger.claim(a);
        ledger.claim(b);
        (uint8 s, address g, uint64 since) = ledger.brakeState();
        assertEq(s, 1);
        assertEq(g, address(0));
        assertEq(since, 42);
    }

    function test_brake_codeChangeAndIdExhaustion() public {
        vm.etch(address(token), address(new FeeOnTransferToken()).code);
        assertEq(ledger.brakePredicate() & 1, 1);
        vm.etch(address(token), address(new TestToken()).code);
        // M0 = slot 0: nextId (low 64) | brakeSince | outstanding.
        vm.store(address(ledger), bytes32(0), bytes32(uint256(type(uint64).max)));
        assertEq(ledger.brakePredicate(), 4);
        ledger.tripBrake();
        vm.prank(employer);
        vm.expectRevert();
        ledger.create(_p(alice, 1, 0, 0, 1));
    }

    function test_reentrancy_fromBeneficiaryCallback() public {
        CallbackToken ct = new CallbackToken();
        _deploy(ct);
        GrantReenterer r = new GrantReenterer();
        vm.prank(employer);
        uint256 id = ledger.create(_p(address(r), 1000, T0, T0, T0 + 1000));
        vm.prank(employer);
        uint256 other = ledger.create(_p(bob, 1000, T0, T0, T0 + 1000));
        r.arm(ledger, other);
        vm.warp(T0 + 500);
        ledger.claim(id);
        assertTrue(r.tried());
        assertEq(r.err(), TransientLock.Reentrancy.selector);
        assertEq(ct.balanceOf(bob), 0);
    }
}

contract GrantReenterer {
    GrantLedger l;
    uint256 id;
    bool public tried;
    bytes4 public err;

    function arm(GrantLedger l_, uint256 id_) external {
        (l, id) = (l_, id_);
    }

    function onTokenTransfer(address, uint256) external {
        if (tried) return;
        tried = true;
        try l.claim(id) {}
        catch (bytes memory e) {
            err = bytes4(e);
        }
    }
}
