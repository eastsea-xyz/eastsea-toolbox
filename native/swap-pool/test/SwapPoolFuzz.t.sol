// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {PoolBase} from "./PoolBase.sol";
import {SwapPool} from "../src/SwapPool.sol";
import {TestToken} from "../../common/test/Tokens.sol";

contract SwapPoolFuzzTest is PoolBase {
    uint256 constant MAXR = 1e30;

    function _init(uint256 r0, uint256 r1, uint256 fee) internal returns (uint256 s) {
        _deploy(new TestToken(), new TestToken(), fee);
        s = _add(lp1, r0, r1);
    }

    /// @notice Exact input: output equals the floor formula, the
    ///         fee-adjusted product never decreases and raw k never decreases.
    function testFuzz_exactInput_matchesCurve_kNeverDown(
        uint256 r0,
        uint256 r1,
        uint256 amountIn,
        uint256 fee,
        bool dir
    ) public {
        r0 = bound(r0, 1e6, MAXR);
        r1 = bound(r1, 1e6, MAXR);
        fee = bound(fee, 0, 100);
        _init(r0, r1, fee);
        amountIn = bound(amountIn, 1, MAXR);
        (TestToken tin, uint256 rIn, uint256 rOut) = dir ? (a, r0, r1) : (b, r1, r0);
        uint256 expected = amountIn * (10_000 - fee) * rOut / (rIn * 10_000 + amountIn * (10_000 - fee));
        vm.assume(expected > 0);
        uint256 k0 = _k();
        uint256 out = _sell(trader, tin, amountIn);
        assertEq(out, expected);
        assertGe(_k(), k0, "k never decreases");
        (uint256 n0, uint256 n1) = _reserves();
        (uint256 nIn, uint256 nOut) = dir ? (n0, n1) : (n1, n0);
        assertGe((nIn * 10_000 - amountIn * fee) * nOut, rIn * rOut * 10_000, "fee-adjusted k");
        assertEq(a.balanceOf(address(pool)), n0, "books == balances");
        assertEq(b.balanceOf(address(pool)), n1);
    }

    /// @notice Exact output: the charged input is the minimum that satisfies
    ///         the curve (one less would break it).
    function testFuzz_exactOutput_chargesMinimalCeiling(uint256 r0, uint256 r1, uint256 out, uint256 fee) public {
        r0 = bound(r0, 1e6, MAXR);
        r1 = bound(r1, 1e6, MAXR);
        fee = bound(fee, 0, 100);
        _init(r0, r1, fee);
        out = bound(out, 1, r1 - 1);
        uint256 need = pool.quoteExactOutput(address(a), out);
        vm.assume(r0 + need <= type(uint112).max && need <= a.balanceOf(trader));
        uint256 k0 = _k();
        vm.prank(trader);
        uint256 paid = pool.swapExactOutput(address(a), out, need, trader, FAR);
        assertEq(paid, need);
        assertGe(_k(), k0);
        // need - 1 would violate the fee-adjusted invariant
        uint256 lhs = (r0 * 10_000 + (need - 1) * (10_000 - fee)) * (r1 - out);
        assertLt(lhs, r0 * r1 * 10_000, "ceiling is tight");
    }

    /// @notice Round trip A -> B -> A never returns more than was spent.
    function testFuzz_roundTrip_noProfit(uint256 r0, uint256 r1, uint256 amountIn, uint256 fee) public {
        r0 = bound(r0, 1e6, MAXR);
        r1 = bound(r1, 1e6, MAXR);
        fee = bound(fee, 0, 100);
        _init(r0, r1, fee);
        amountIn = bound(amountIn, 1, r0 * 10 < MAXR ? r0 * 10 : MAXR);
        try pool.quoteExactInput(address(a), amountIn) returns (uint256 q) {
            vm.assume(q > 0);
        } catch {
            vm.assume(false);
        }
        uint256 mid = _sell(trader, a, amountIn);
        try pool.quoteExactInput(address(b), mid) returns (uint256 q2) {
            uint256 back = _sell(trader, b, mid);
            assertEq(back, q2);
            assertLe(back, amountIn, "no free round trip");
        } catch {}
    }

    /// @notice Adding then immediately removing never returns more of either
    ///         token than was deposited (no rounding theft by joiners).
    function testFuzz_addRemove_noProfit(uint256 r0, uint256 r1, uint256 x, uint256 y, uint256 fee) public {
        r0 = bound(r0, 1e6, MAXR);
        r1 = bound(r1, 1e6, MAXR);
        fee = bound(fee, 0, 100);
        _init(r0, r1, fee);
        x = bound(x, 1, MAXR);
        y = bound(y, 1, MAXR);
        vm.prank(lp2);
        try pool.add(x, y, 0, FAR) returns (uint256 u0, uint256 u1, uint256 minted) {
            vm.prank(lp2);
            (uint256 o0, uint256 o1) = pool.remove(minted, 0, 0, lp2, FAR);
            assertLe(o0, u0);
            assertLe(o1, u1);
        } catch {}
    }

    /// @notice Value per share (k / totalShares^2) never decreases across
    ///         add, swap and remove.
    function testFuzz_valuePerShare_monotone(uint256 r0, uint256 r1, uint256 x, uint256 amountIn, uint256 part) public {
        r0 = bound(r0, 1e6, 1e27);
        r1 = bound(r1, 1e6, 1e27);
        _init(r0, r1, FEE);
        uint256 k = _k();
        uint256 t = pool.totalShares();
        x = bound(x, 1, 1e27);
        vm.prank(lp2);
        try pool.add(x, x, 0, FAR) {} catch {}
        assertTrue(_valuePerShareNotDown(k, t, _k(), pool.totalShares()), "add");
        (k, t) = (_k(), pool.totalShares());
        amountIn = bound(amountIn, 1, 1e27);
        vm.prank(trader);
        try pool.swapExactInput(address(a), amountIn, 0, trader, FAR) {} catch {}
        assertTrue(_valuePerShareNotDown(k, t, _k(), pool.totalShares()), "swap");
        (k, t) = (_k(), pool.totalShares());
        part = bound(part, 1, pool.shares(lp1));
        vm.prank(lp1);
        pool.remove(part, 0, 0, lp1, FAR);
        assertTrue(_valuePerShareNotDown(k, t, _k(), pool.totalShares()), "remove");
    }

    /// @notice First-depositor inflation: an attacker who initializes with
    ///         the minimum and donates cannot make a later depositor's
    ///         `minShares` meaningless; the victim either gets >= minShares or
    ///         reverts, and the attacker's donation mostly accrues to the
    ///         locked shares and the victim.
    function testFuzz_inflationAttack_boundedByMinShares(uint256 donation, uint256 deposit) public {
        _deploy(new TestToken(), new TestToken(), FEE);
        address attacker = makeAddr("attacker");
        a.mint(attacker, 1e30);
        b.mint(attacker, 1e30);
        vm.startPrank(attacker);
        a.approve(address(pool), type(uint256).max);
        b.approve(address(pool), type(uint256).max);
        (,, uint256 aShares) = pool.add(1001, 1001, 0, FAR); // 1 share above the lock
        donation = bound(donation, 1, 1e27);
        a.transfer(address(pool), donation);
        b.transfer(address(pool), donation);
        vm.stopPrank();

        deposit = bound(deposit, 1e6, 1e27);
        // The victim's wallet computes the expected shares from the reserves
        // it will see after the donation is absorbed, and asks for 99.9%.
        uint256 total = pool.totalShares();
        uint256 bal = a.balanceOf(address(pool));
        uint256 expected = deposit * total / bal;
        uint256 minShares = expected * 999 / 1000;
        vm.prank(lp2);
        try pool.add(deposit, deposit, minShares, FAR) returns (uint256 u0, uint256, uint256 minted) {
            assertGe(minted, minShares);
            // Victim's claim is worth at least what it paid, minus one share's rounding.
            uint256 claim = minted * a.balanceOf(address(pool)) / pool.totalShares();
            uint256 perShare = a.balanceOf(address(pool)) / pool.totalShares() + 1;
            assertGe(claim + perShare, u0);
        } catch {}
        // The attacker never extracts more than it put in.
        vm.prank(attacker);
        (uint256 o0,) = pool.remove(aShares, 0, 0, attacker, FAR);
        assertLe(o0, 1001 + donation);
    }

    /// @notice Quotes equal execution in both directions and both modes.
    function testFuzz_quotesMatchExecution(uint256 r0, uint256 r1, uint256 v, bool exactIn) public {
        r0 = bound(r0, 1e6, MAXR);
        r1 = bound(r1, 1e6, MAXR);
        _init(r0, r1, FEE);
        if (exactIn) {
            v = bound(v, 1, MAXR);
            try pool.quoteExactInput(address(b), v) returns (uint256 q) {
                assertEq(_sell(trader, b, v), q);
            } catch {}
        } else {
            v = bound(v, 1, r0 - 1);
            uint256 q = pool.quoteExactOutput(address(b), v);
            vm.assume(r1 + q <= type(uint112).max && q <= b.balanceOf(trader));
            vm.prank(trader);
            assertEq(pool.swapExactOutput(address(b), v, q, trader, FAR), q);
        }
    }

    /// @notice A stranger with no shares can never withdraw.
    function testFuzz_strangerCannotRemove(uint256 amount) public {
        _init(1e18, 1e18, FEE);
        amount = bound(amount, 1, type(uint128).max);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SwapPool.NotEnoughShares.selector, 0, amount));
        pool.remove(amount, 0, 0, stranger, FAR);
    }
}
