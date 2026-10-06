// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {PoolBase} from "./PoolBase.sol";
import {SwapPool} from "../src/SwapPool.sol";
import {INativeBrake} from "../../common/src/INativeBrake.sol";
import {ExactToken} from "../../common/src/ExactToken.sol";
import {TransientLock} from "../../common/src/TransientLock.sol";
import {SlotDiff} from "../../common/test/SlotDiff.sol";
import {TestToken, FeeOnTransferToken, BlockingToken, LyingToken, CallbackToken} from "../../common/test/Tokens.sol";
import {NoBoolToken, RebasingToken, PausableToken} from "../../probes/test/ProbeTokens.sol";

contract SwapPoolDeployTest is PoolBase {
    function setUp() public {
        _deploy(new TestToken(), new TestToken(), FEE);
    }

    function test_runtimeWithinEip170() public view {
        assertLe(address(pool).code.length, 24576);
    }

    function test_constructor_checks() public {
        vm.expectRevert(SwapPool.SameToken.selector);
        new SwapPool(address(a), address(a), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SwapPool.TokenHasNoCode.selector, address(0xBEEF)));
        new SwapPool(address(0xBEEF), address(a), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SwapPool.TokenHasNoCode.selector, address(0xBEEF)));
        new SwapPool(address(a), address(0xBEEF), 0, 0);
        vm.expectRevert(SwapPool.FeeTooHigh.selector);
        new SwapPool(address(a), address(b), 101, 0);
        new SwapPool(address(a), address(b), 100, 0);
        new SwapPool(address(a), address(b), 0, 0);
    }

    /// @notice Deployment occupies only the brake metadata word (slot 2).
    function test_deploy_occupiesOnlyBrakeMetadata() public view {
        assertEq(vm.load(address(pool), bytes32(uint256(0))), 0, "reserves empty");
        assertEq(vm.load(address(pool), bytes32(uint256(1))), 0, "supply empty");
        assertTrue(vm.load(address(pool), bytes32(uint256(2))) != 0, "createdAt set");
        (uint64 createdAt, uint64 latchedAt, uint8 reason) = pool.brakeMeta();
        assertEq(createdAt, 100);
        assertEq(latchedAt, 0);
        assertEq(reason, 0);
        (uint8 s, address g, uint64 since) = pool.brakeState();
        assertEq(s, 0);
        assertEq(g, address(0), "no guardian, ever");
        assertEq(since, 0);
        (string memory uri, bytes32 doc) = pool.brakeSpec();
        assertEq(uri, "native/swap-pool/SECURITY.md#brake");
        assertEq(doc, keccak256("brake doc"));
    }

    function test_swapBeforeInit_reverts() public {
        vm.prank(trader);
        vm.expectRevert(SwapPool.NotInitialized.selector);
        pool.swapExactInput(address(a), 1e18, 0, trader, FAR);
    }
}

contract SwapPoolLiquidityTest is PoolBase {
    function setUp() public {
        _deploy(new TestToken(), new TestToken(), FEE);
    }

    function test_firstAdd_threeSlots_locksMinimumInsideSupply() public {
        SlotDiff.start();
        uint256 minted = _add(lp1, 4e18, 1e18);
        assertEq(SlotDiff.stop(address(pool)).occupied, 3, "reserves, supply, shares[lp1]");
        assertEq(minted, 2e18 - 1000);
        assertEq(pool.totalShares(), 2e18);
        assertEq(pool.lockedShares(), 1000);
        assertEq(pool.shares(lp1), 2e18 - 1000);
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 4e18);
        assertEq(r1, 1e18);
        assertEq(a.balanceOf(address(pool)), 4e18);
    }

    function test_firstAdd_tooSmall_reverts() public {
        vm.prank(lp1);
        vm.expectRevert(SwapPool.InitialSharesTooSmall.selector);
        pool.add(1000, 1000, 0, FAR);
        vm.prank(lp1);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.add(0, 1000, 0, FAR);
    }

    function test_newLp_oneSlot_proportional_roundedUp_restStaysWithUser() public {
        _add(lp1, 3e18 + 1, 1e18);
        uint256 a0 = a.balanceOf(lp2);
        uint256 b0 = b.balanceOf(lp2);
        SlotDiff.start();
        vm.prank(lp2);
        (uint256 u0, uint256 u1, uint256 minted) = pool.add(10e18, 1e18, 0, FAR);
        assertEq(SlotDiff.stop(address(pool)).occupied, 1, "shares[lp2] only");
        assertLe(u1, 1e18);
        assertLt(u0, 10e18, "only the proportional part is pulled");
        assertEq(a0 - a.balanceOf(lp2), u0);
        assertEq(b0 - b.balanceOf(lp2), u1);
        uint256 t = pool.totalShares() - minted;
        (uint256 r0, uint256 r1) = _reserves();
        // Paid at least the exact pro-rata value (rounded up).
        assertGe(u0 * t, minted * (r0 - u0));
        assertGe(u1 * t, minted * (r1 - u1));
    }

    function test_existingLp_addsWithNoNewSlot() public {
        _add(lp1, 1e18, 1e18);
        SlotDiff.start();
        _add(lp1, 1e18, 1e18);
        assertEq(SlotDiff.stop(address(pool)).occupied, 0);
    }

    function test_add_minShares_andDeadline() public {
        _add(lp1, 1e18, 1e18);
        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSelector(SwapPool.SlippageShares.selector, 1e18, 1e18 + 1));
        pool.add(1e18, 1e18, 1e18 + 1, FAR);
        vm.prank(lp2);
        vm.expectRevert(SwapPool.Expired.selector);
        pool.add(1e18, 1e18, 0, T0 - 1);
    }

    function test_add_tooSmallForOneShare_reverts() public {
        _add(lp1, 1e24, 1e18);
        vm.prank(lp2);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.add(100, 1e18, 0, FAR);
    }

    function test_remove_fullExit_clearsSlot_proRata() public {
        _add(lp1, 1e18, 1e18);
        uint256 s = _add(lp2, 1e18, 1e18);
        uint256 before0 = a.balanceOf(stranger);
        SlotDiff.start();
        vm.prank(lp2);
        (uint256 o0, uint256 o1) = pool.remove(s, 0, 0, stranger, FAR);
        SlotDiff.Count memory c = SlotDiff.stop(address(pool));
        assertEq(c.occupied, 0);
        assertEq(c.cleared, 1, "shares[lp2] deleted (no burn refund)");
        assertEq(o0, 1e18);
        assertEq(o1, 1e18);
        assertEq(a.balanceOf(stranger) - before0, 1e18, "explicit receiver");
        assertEq(pool.shares(lp2), 0);
    }

    function test_remove_slippage_andAuthorization() public {
        uint256 s = _add(lp1, 1e18, 1e18);
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(SwapPool.SlippageOut.selector, s, s + 1));
        pool.remove(s, s + 1, 0, lp1, FAR);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SwapPool.NotEnoughShares.selector, 0, 1));
        pool.remove(1, 0, 0, stranger, FAR);
        vm.prank(lp1);
        vm.expectRevert(SwapPool.BadRecipient.selector);
        pool.remove(1, 0, 0, address(pool), FAR);
        vm.prank(lp1);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.remove(0, 0, 0, lp1, FAR);
    }

    function test_lockedMinimum_isNeverRedeemable() public {
        uint256 s = _add(lp1, 1e18, 1e18);
        vm.prank(lp1);
        pool.remove(s, 0, 0, lp1, FAR);
        assertEq(pool.totalShares(), 1000);
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 1000);
        assertEq(r1, 1000);
        // The pool remains usable and re-addable.
        _add(lp2, 1e18, 1e18);
    }

    function test_donation_goesToCurrentLps_notToLaterJoiners() public {
        uint256 s1 = _add(lp1, 1e18, 1e18);
        vm.prank(stranger);
        a.mint(address(pool), 1e18); // donation of token0
        // A later LP joins at the post-donation ratio, so it gains nothing.
        uint256 s2 = _add(lp2, 2e18, 1e18);
        vm.prank(lp2);
        (uint256 o0, uint256 o1) = pool.remove(s2, 0, 0, lp2, FAR);
        assertLe(o0, 2e18);
        assertLe(o1, 1e18);
        vm.prank(lp1);
        (o0,) = pool.remove(s1, 0, 0, lp1, FAR);
        assertGt(o0, 1e18 + 0.99e18, "lp1 owns the donation");
    }
}

contract SwapPoolSwapTest is PoolBase {
    function setUp() public {
        _deploy(new TestToken(), new TestToken(), FEE);
        _add(lp1, 100e18, 200e18);
    }

    function test_exactInput_formula_noNewSlot_kGrows() public {
        uint256 k0 = _k();
        uint256 one = 1e18;
        uint256 expected = (one * 9970 * 200e18) / (100e18 * 10_000 + one * 9970);
        assertEq(pool.quoteExactInput(address(a), 1e18), expected);
        uint256 bBefore = b.balanceOf(trader);
        SlotDiff.start();
        uint256 out = _sell(trader, a, 1e18);
        assertEq(SlotDiff.stop(address(pool)).occupied, 0);
        assertEq(out, expected);
        assertEq(b.balanceOf(trader) - bBefore, out);
        assertGt(_k(), k0, "fee stays in reserves");
    }

    function test_exactInput_otherDirection() public {
        uint256 q = pool.quoteExactInput(address(b), 2e18);
        assertEq(_sell(trader, b, 2e18), q);
        (uint256 r0, uint256 r1) = _reserves();
        assertEq(r0, 100e18 - q);
        assertEq(r1, 202e18);
    }

    function test_exactInput_minOut_reverts_andNothingMoves() public {
        uint256 q = pool.quoteExactInput(address(a), 1e18);
        uint256 a0 = a.balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(SwapPool.SlippageOut.selector, q, q + 1));
        pool.swapExactInput(address(a), 1e18, q + 1, trader, FAR);
        assertEq(a.balanceOf(trader), a0);
    }

    function test_exactOutput_paysCeiling_andMaxIn() public {
        uint256 need = pool.quoteExactOutput(address(a), 1e18);
        // One less input would not satisfy the curve with fee.
        uint256 num = 100e18 * 1e18 * 10_000;
        uint256 den = (200e18 - 1e18) * 9970;
        assertEq(need, (num + den - 1) / den);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(SwapPool.SlippageIn.selector, need, need - 1));
        pool.swapExactOutput(address(a), 1e18, need - 1, trader, FAR);
        uint256 bBefore = b.balanceOf(trader);
        uint256 aBefore = a.balanceOf(trader);
        vm.prank(trader);
        uint256 paid = pool.swapExactOutput(address(a), 1e18, need, trader, FAR);
        assertEq(paid, need);
        assertEq(b.balanceOf(trader) - bBefore, 1e18);
        assertEq(aBefore - a.balanceOf(trader), need);
    }

    function test_exactOutput_cannotDrainReserve() public {
        vm.prank(trader);
        vm.expectRevert(SwapPool.InsufficientLiquidity.selector);
        pool.swapExactOutput(address(a), 200e18, type(uint256).max, trader, FAR);
    }

    function test_swap_inputChecks() public {
        vm.startPrank(trader);
        vm.expectRevert(SwapPool.Expired.selector);
        pool.swapExactInput(address(a), 1e18, 0, trader, T0 - 1);
        vm.expectRevert(SwapPool.BadRecipient.selector);
        pool.swapExactInput(address(a), 1e18, 0, address(0), FAR);
        vm.expectRevert(SwapPool.BadRecipient.selector);
        pool.swapExactInput(address(a), 1e18, 0, address(pool), FAR);
        vm.expectRevert(SwapPool.BadToken.selector);
        pool.swapExactInput(address(0xBEEF), 1e18, 0, trader, FAR);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.swapExactInput(address(a), 0, 0, trader, FAR);
        vm.expectRevert(SwapPool.ZeroAmount.selector);
        pool.swapExactInput(address(b), 1, 0, trader, FAR); // rounds to zero out
        vm.expectRevert(SwapPool.ReserveOverflow.selector);
        pool.swapExactInput(address(a), uint256(type(uint112).max) + 1, 0, trader, FAR);
        vm.stopPrank();
    }

    function test_deadlineIsInclusive() public {
        vm.prank(trader);
        pool.swapExactInput(address(a), 1e18, 0, trader, T0);
    }

    function test_swapToAnotherRecipient() public {
        uint256 out = _sell(trader, a, 1e18);
        vm.prank(trader);
        uint256 out2 = pool.swapExactInput(address(a), 1e18, 0, stranger, FAR);
        assertEq(b.balanceOf(stranger), out2);
        assertLt(out2, out, "price moved");
    }

    function test_zeroFeePool() public {
        SwapPool p0 = new SwapPool(address(a), address(b), 0, 0);
        vm.startPrank(lp1);
        a.approve(address(p0), type(uint256).max);
        b.approve(address(p0), type(uint256).max);
        p0.add(100e18, 100e18, 0, FAR);
        uint256 out = p0.swapExactInput(address(a), 1e18, 0, lp1, FAR);
        vm.stopPrank();
        uint256 one = 1e18;
        assertEq(out, (one * 100e18) / 101e18);
    }

    function test_reentrancyThroughTokenCallback_isBlocked() public {
        CallbackToken cb = new CallbackToken();
        SwapPool p = new SwapPool(address(cb), address(b), FEE, 0);
        Reenterer r = new Reenterer(p, address(cb), address(b));
        cb.mint(address(this), 1e24);
        b.mint(address(this), 1e24);
        cb.approve(address(p), type(uint256).max);
        b.approve(address(p), type(uint256).max);
        p.add(100e18, 100e18, 0, FAR);
        b.mint(address(r), 1e18);
        r.go(1e18);
        assertTrue(r.attempted(), "callback fired");
        assertEq(r.reenteredOk(), false, "re-entry rejected");
        assertEq(r.lastError(), TransientLock.Reentrancy.selector);
    }
}

/// @notice Receives a CallbackToken payout and tries to swap again inside it.
contract Reenterer {
    SwapPool pool;
    address cb;
    address other;
    bool public attempted;
    bool public reenteredOk;
    bytes4 public lastError;

    constructor(SwapPool p, address cb_, address other_) {
        pool = p;
        cb = cb_;
        other = other_;
        TestToken(other_).approve(address(p), type(uint256).max);
        TestToken(cb_).approve(address(p), type(uint256).max);
    }

    function go(uint256 amount) external {
        pool.swapExactInput(other, amount, 0, address(this), type(uint64).max);
    }

    function onTokenTransfer(address, uint256) external {
        if (msg.sender != cb || attempted) return;
        attempted = true;
        try pool.swapExactInput(cb, 1e6, 0, address(this), type(uint64).max) {
            reenteredOk = true;
        } catch (bytes memory err) {
            lastError = bytes4(err);
        }
    }
}

contract SwapPoolBrakeTest is PoolBase {
    uint256 s1;
    uint256 s2;

    function setUp() public {
        _deploy(new TestToken(), new TestToken(), FEE);
        s1 = _add(lp1, 100e18, 100e18);
        s2 = _add(lp2, 300e18, 300e18);
    }

    function test_tripBrake_requiresPredicate() public {
        vm.expectRevert(INativeBrake.BrakePredicateFalse.selector);
        pool.tripBrake();
    }

    function test_deficit_closesEntry_latchIsPermanent_exitsProRata() public {
        a.burnFrom(address(pool), 40e18); // issuer seizure / negative rebase
        (uint8 st,, uint64 since) = pool.brakeState();
        assertEq(st, 1, "visible before anyone latches");
        assertEq(since, 0);
        assertEq(pool.brakePredicate(), 2);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.EntryBraked.selector, 2, 0));
        pool.swapExactInput(address(a), 1e18, 0, trader, FAR);

        vm.roll(500);
        vm.prank(stranger);
        pool.tripBrake();
        (, uint64 latchedAt, uint8 reason) = pool.brakeMeta();
        assertEq(latchedAt, 500);
        assertEq(reason, 2);

        // Recapitalising does not reopen entry.
        a.mint(address(pool), 40e18);
        assertEq(pool.brakePredicate(), 0);
        a.burnFrom(address(pool), 40e18);
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.EntryBraked.selector, 2, 500));
        pool.add(1e18, 1e18, 0, FAR);
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.BrakeAlreadyLatched.selector, 500));
        pool.tripBrake();

        // Exits: pro rata of the actual 360 / 400 balances, recalculated each time.
        uint256 total = pool.totalShares();
        vm.prank(lp1);
        (uint256 o0, uint256 o1) = pool.remove(s1, 0, 0, lp1, FAR);
        assertEq(o0, s1 * 360e18 / total);
        assertEq(o1, s1 * 400e18 / total);
        vm.prank(lp2);
        (o0, o1) = pool.remove(s2, 0, 0, lp2, FAR);
        assertApproxEqAbs(o0, 270e18, 1e6, "lp2 shares the 10% loss equally");
        assertApproxEqAbs(o1, 300e18, 1e6);
        (st,, since) = pool.brakeState();
        assertEq(st, 1);
        assertEq(since, 500);
    }

    function test_remove_latchesALiveDeficit_itself() public {
        b.burnFrom(address(pool), 1e18);
        vm.roll(777);
        vm.prank(lp1);
        pool.remove(1e18, 0, 0, lp1, FAR);
        (uint8 st,, uint64 since) = pool.brakeState();
        assertEq(st, 1);
        assertEq(since, 777, "exit recorded the evidence before syncing books");
        assertEq(pool.brakePredicate(), 0, "books now match balances");
    }

    function test_codeHashChange_closesEntry_exitsStayOpen() public {
        vm.etch(address(a), address(new LyingToken()).code);
        assertEq(pool.brakePredicate(), 1);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.EntryBraked.selector, 1, 0));
        pool.swapExactInput(address(b), 1e18, 0, trader, FAR);
        vm.prank(lp1);
        pool.remove(s1, 0, 0, lp1, FAR);
        (uint8 st,,) = pool.brakeState();
        assertEq(st, 1);
    }

    function test_noOneCanPauseWithoutPredicate() public {
        vm.prank(lp1);
        vm.expectRevert(INativeBrake.BrakePredicateFalse.selector);
        pool.tripBrake();
        _sell(trader, a, 1e18); // still open
    }
}

/// @notice Token behaviour cases (C0 probes applied to the pool).
contract SwapPoolTokenBehaviourTest is PoolBase {
    function _pair(address t0, address t1) internal returns (SwapPool p) {
        p = new SwapPool(t0, t1, FEE, 0);
        address[2] memory ts = [t0, t1];
        for (uint256 i; i < 2; i++) {
            (bool ok,) = ts[i].call(abi.encodeWithSignature("mint(address,uint256)", lp1, 1e24));
            require(ok);
            (ok,) = ts[i].call(abi.encodeWithSignature("mint(address,uint256)", trader, 1e24));
            vm.prank(lp1);
            (ok,) = ts[i].call(abi.encodeWithSignature("approve(address,uint256)", address(p), type(uint256).max));
            vm.prank(trader);
            (ok,) = ts[i].call(abi.encodeWithSignature("approve(address,uint256)", address(p), type(uint256).max));
        }
    }

    function setUp() public {
        vm.warp(T0);
        vm.roll(100);
    }

    function test_noBoolToken_fullLifecycle() public {
        NoBoolToken nb = new NoBoolToken();
        TestToken t = new TestToken();
        SwapPool p = _pair(address(nb), address(t));
        vm.prank(lp1);
        (,, uint256 s) = p.add(100e6, 100e18, 0, FAR);
        vm.prank(trader);
        uint256 out = p.swapExactInput(address(nb), 1e6, 0, trader, FAR);
        assertGt(out, 0);
        vm.prank(trader);
        p.swapExactInput(address(t), 1e18, 0, trader, FAR);
        vm.prank(lp1);
        p.remove(s, 0, 0, lp1, FAR);
    }

    function test_feeOnTransfer_cannotEnter() public {
        FeeOnTransferToken f = new FeeOnTransferToken();
        TestToken t = new TestToken();
        SwapPool p = _pair(address(f), address(t));
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(ExactToken.NotExactTransfer.selector, 100e18, 99e18));
        p.add(100e18, 100e18, 0, FAR);
    }

    function test_noopTrueToken_cannotEnter() public {
        LyingToken l = new LyingToken();
        TestToken t = new TestToken();
        SwapPool p = _pair(address(l), address(t));
        l.setLying(true);
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(ExactToken.NotExactTransfer.selector, 100e18, 0));
        p.add(100e18, 100e18, 0, FAR);
    }

    function test_positiveRebase_isAbsorbedByLps() public {
        RebasingToken rb = new RebasingToken();
        TestToken t = new TestToken();
        SwapPool p = _pair(address(rb), address(t));
        vm.prank(lp1);
        (,, uint256 s) = p.add(100e18, 100e18, 0, FAR);
        rb.rebase(2e18); // index 2: even amounts still move exactly
        assertEq(p.brakePredicate(), 0, "surplus is not a deficit");
        vm.prank(trader);
        p.swapExactInput(address(rb), 2e18, 0, trader, FAR); // absorbs surplus first
        (uint112 r0,,) = p.getReserves();
        assertEq(r0, 202e18, "100 deposited, doubled, plus 2 sold");
        vm.prank(lp1);
        (uint256 o0,) = p.remove(s, 0, 0, lp1, FAR);
        assertGt(o0, 190e18, "LP receives the rebase gain");
    }

    /// @notice With a non-integer index, share rounding makes transfers
    ///         inexact: entry is refused (rebasing is unsupported), but the
    ///         exit leg follows actual balances and still lets the LP out.
    function test_rebasingRounding_entryRefused_exitStillOpen() public {
        RebasingToken rb = new RebasingToken();
        TestToken t = new TestToken();
        SwapPool p = _pair(address(rb), address(t));
        vm.prank(lp1);
        (,, uint256 s) = p.add(100e18, 100e18, 0, FAR);
        rb.rebase(1.1e18);
        vm.prank(trader);
        vm.expectRevert();
        p.swapExactInput(address(t), 1e18, 0, trader, FAR);
        uint256 before = rb.balanceOf(lp1);
        vm.prank(lp1);
        (uint256 o0,) = p.remove(s, 0, 0, lp1, FAR);
        assertApproxEqAbs(o0, 110e18, 2e3);
        assertApproxEqAbs(rb.balanceOf(lp1) - before, o0, 2);
        assertEq(p.brakePredicate(), 0, "books match balances after the exit");
    }

    function test_negativeRebase_tripsBrake_lpsExitWithLoss() public {
        RebasingToken rb = new RebasingToken();
        TestToken t = new TestToken();
        SwapPool p = _pair(address(rb), address(t));
        vm.prank(lp1);
        (,, uint256 s) = p.add(100e18, 100e18, 0, FAR);
        rb.rebase(0.8e18);
        assertEq(p.brakePredicate(), 2);
        vm.prank(trader);
        vm.expectRevert();
        p.swapExactInput(address(t), 1e18, 0, trader, FAR);
        vm.prank(lp1);
        (uint256 o0, uint256 o1) = p.remove(s, 0, 0, lp1, FAR);
        assertApproxEqAbs(o0, 80e18, 1e3);
        assertApproxEqAbs(o1, 100e18, 1e3);
    }

    function test_blockedRecipient_swapReverts_exitToAnotherReceiverWorks() public {
        BlockingToken bt = new BlockingToken();
        TestToken t = new TestToken();
        SwapPool p = _pair(address(t), address(bt));
        vm.prank(lp1);
        (,, uint256 s) = p.add(100e18, 100e18, 0, FAR);
        bt.setBlocked(trader, true);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(ExactToken.TokenCallFailed.selector, address(bt)));
        p.swapExactInput(address(t), 1e18, 0, trader, FAR);
        bt.setBlocked(lp1, true);
        vm.prank(lp1);
        p.remove(s, 0, 0, stranger, FAR);
        assertGt(bt.balanceOf(stranger), 0);
    }

    /// @notice A no-op "true" token cannot make an LP burn shares for
    ///         nothing when the LP set a minimum: the minimum is checked on
    ///         what actually left the pool.
    function test_exitMinimum_isCheckedOnActualDebit() public {
        LyingToken l = new LyingToken();
        TestToken t = new TestToken();
        SwapPool p = _pair(address(l), address(t));
        vm.prank(lp1);
        (,, uint256 s) = p.add(100e18, 100e18, 0, FAR);
        l.setLying(true);
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(SwapPool.SlippageOut.selector, 0, 1));
        p.remove(s, 1, 1, lp1, FAR);
    }

    function test_frozenPool_blocksExits_documentedLimit() public {
        PausableToken pt = new PausableToken();
        TestToken t = new TestToken();
        SwapPool p = _pair(address(pt), address(t));
        vm.prank(lp1);
        (,, uint256 s) = p.add(100e18, 100e18, 0, FAR);
        pt.setPaused(true);
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSelector(SwapPool.TokenCallFailed.selector, address(pt)));
        p.remove(s, 0, 0, lp1, FAR);
        // "Exit callable" cannot create issuer cooperation; it resumes with it.
        pt.setPaused(false);
        vm.prank(lp1);
        p.remove(s, 0, 0, lp1, FAR);
    }

    /// @notice A token that starts charging a transfer fee after deployment
    ///         closes entry (code hash) but LPs still get out: the exit leg
    ///         checks only the pool's own balance.
    function test_tokenTurnsFeeOnTransfer_exitStillOpen() public {
        TestToken t0 = new TestToken();
        TestToken t1 = new TestToken();
        SwapPool p = _pair(address(t0), address(t1));
        vm.prank(lp1);
        (,, uint256 s) = p.add(100e18, 100e18, 0, FAR);
        vm.etch(address(t0), address(new FeeOnTransferToken()).code);
        assertEq(p.brakePredicate(), 1);
        uint256 before = t0.balanceOf(lp1);
        vm.prank(lp1);
        (uint256 o0,) = p.remove(s, 0, 0, lp1, FAR);
        assertEq(t0.balanceOf(lp1) - before, o0 - o0 / 100, "issuer fee taken from the LP, books exact");
    }
}
