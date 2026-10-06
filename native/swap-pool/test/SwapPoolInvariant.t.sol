// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {SwapPool} from "../src/SwapPool.sol";
import {TestToken} from "../../common/test/Tokens.sol";

/// @notice Random LPs, traders, donors and an issuer that occasionally
///         seizes pool funds. Each step records whether it broke a rule;
///         the invariants then require every counter to be zero.
contract PoolHandler is Test {
    SwapPool public pool;
    TestToken public a;
    TestToken public b;
    address[3] public lps;
    address[2] public traders;
    uint64 constant FAR = type(uint64).max;

    // ghosts
    uint256 public in0;
    uint256 public in1;
    uint256 public out0;
    uint256 public out1;
    uint256 public donated0;
    uint256 public donated1;
    uint256 public seized0;
    uint256 public seized1;

    // rule violations (must stay zero)
    uint256 public kDown; // swap lowered k
    uint256 public valuePerShareDown; // any non-loss step lowered k / T^2
    uint256 public exitFailed; // an LP with shares could not remove
    uint256 public entryAfterLatch; // add/swap succeeded after the latch
    uint256 public latchMoved; // latch height changed or cleared
    uint256 public overpaid; // a trader got less than the min it asked for

    uint256 public swaps;
    uint256 public exits;
    uint256 public latchedExits;
    uint64 public seenLatch;

    constructor(SwapPool p, TestToken ta, TestToken tb) {
        pool = p;
        a = ta;
        b = tb;
        for (uint256 i; i < 3; i++) {
            lps[i] = address(uint160(0xB000 + i));
            _fund(lps[i]);
        }
        for (uint256 i; i < 2; i++) {
            traders[i] = address(uint160(0xC000 + i));
            _fund(traders[i]);
        }
        vm.prank(lps[0]);
        (uint256 u0, uint256 u1,) = p.add(1e24, 2e24, 0, FAR);
        in0 += u0;
        in1 += u1;
    }

    function _fund(address who) internal {
        a.mint(who, 1e30);
        b.mint(who, 1e30);
        vm.startPrank(who);
        a.approve(address(pool), type(uint256).max);
        b.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _r() internal view returns (uint256 r0, uint256 r1) {
        (r0, r1,) = pool.getReserves();
    }

    function _deficit() internal view returns (bool) {
        (uint256 r0, uint256 r1) = _r();
        return a.balanceOf(address(pool)) < r0 || b.balanceOf(address(pool)) < r1;
    }

    function _latched() internal view returns (bool) {
        (, uint64 l,) = pool.brakeMeta();
        return l != 0;
    }

    function _snap() internal view returns (uint256 k, uint256 t, bool loss) {
        (uint256 r0, uint256 r1) = _r();
        return (r0 * r1, pool.totalShares(), _deficit());
    }

    function _checkValue(uint256 k0, uint256 t0, bool lossBefore) internal {
        if (lossBefore) return; // a deficit is shared loss, not theft
        (uint256 k1, uint256 t1,) = _snap();
        if (!_notDown(k0, t0, k1, t1)) valuePerShareDown++;
    }

    function _notDown(uint256 k0, uint256 t0, uint256 k1, uint256 t1) internal pure returns (bool) {
        (uint256 lh, uint256 ll) = _mul512(k1, t0 * t0);
        (uint256 rh, uint256 rl) = _mul512(k0, t1 * t1);
        return lh > rh || (lh == rh && ll >= rl);
    }

    function _mul512(uint256 x, uint256 y) internal pure returns (uint256 hi, uint256 lo) {
        assembly {
            let mm := mulmod(x, y, not(0))
            lo := mul(x, y)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    function _trackLatch() internal {
        (, uint64 l,) = pool.brakeMeta();
        if (seenLatch != 0 && l != seenLatch) latchMoved++;
        if (seenLatch == 0) seenLatch = l;
    }

    // ---------------------------------------------------------------- actions

    function add(uint256 who, uint256 x, uint256 y) external {
        address lp = lps[who % 3];
        x = bound(x, 1, 1e25);
        y = bound(y, 1, 1e25);
        bool wasLatched = _latched();
        (uint256 k0, uint256 t0, bool loss) = _snap();
        vm.prank(lp);
        try pool.add(x, y, 0, FAR) returns (uint256 u0, uint256 u1, uint256) {
            if (wasLatched) entryAfterLatch++;
            in0 += u0;
            in1 += u1;
        } catch {}
        _checkValue(k0, t0, loss);
        _trackLatch();
    }

    function swapIn(uint256 who, bool dir, uint256 amount, uint256 slip) external {
        address tr = traders[who % 2];
        amount = bound(amount, 1, 1e24);
        address tin = dir ? address(a) : address(b);
        bool wasLatched = _latched();
        (uint256 k0, uint256 t0, bool loss) = _snap();
        uint256 minOut;
        try pool.quoteExactInput(tin, amount) returns (uint256 q) {
            minOut = q * (10_000 - bound(slip, 0, 500)) / 10_000;
        } catch {}
        vm.prank(tr);
        try pool.swapExactInput(tin, amount, minOut, tr, FAR) returns (uint256 out) {
            if (wasLatched) entryAfterLatch++;
            if (out < minOut) overpaid++;
            swaps++;
            if (dir) (in0, out1) = (in0 + amount, out1 + out);
            else (in1, out0) = (in1 + amount, out0 + out);
            (uint256 k1,,) = _snap();
            if (k1 < k0) kDown++;
        } catch {}
        _checkValue(k0, t0, loss);
        _trackLatch();
    }

    function swapOut(uint256 who, bool dir, uint256 amount) external {
        address tr = traders[who % 2];
        amount = bound(amount, 1, 1e23);
        address tin = dir ? address(a) : address(b);
        bool wasLatched = _latched();
        (uint256 k0, uint256 t0, bool loss) = _snap();
        vm.prank(tr);
        try pool.swapExactOutput(tin, amount, type(uint256).max, tr, FAR) returns (uint256 paid) {
            if (wasLatched) entryAfterLatch++;
            swaps++;
            if (dir) (in0, out1) = (in0 + paid, out1 + amount);
            else (in1, out0) = (in1 + paid, out0 + amount);
            (uint256 k1,,) = _snap();
            if (k1 < k0) kDown++;
        } catch {}
        _checkValue(k0, t0, loss);
        _trackLatch();
    }

    function remove(uint256 who, uint256 frac) external {
        address lp = lps[who % 3];
        uint256 have = pool.shares(lp);
        if (have == 0) return;
        uint256 amt = bound(frac, 1, have);
        (uint256 k0, uint256 t0, bool loss) = _snap();
        vm.prank(lp);
        try pool.remove(amt, 0, 0, lp, FAR) returns (uint256 o0, uint256 o1) {
            exits++;
            if (_latched()) latchedExits++;
            out0 += o0;
            out1 += o1;
        } catch {
            exitFailed++;
        }
        _checkValue(k0, t0, loss);
        _trackLatch();
    }

    function donate(bool dir, uint256 amount) external {
        amount = bound(amount, 1, 1e22);
        if (dir) {
            a.mint(address(pool), amount);
            donated0 += amount;
        } else {
            b.mint(address(pool), amount);
            donated1 += amount;
        }
    }

    /// @dev Rare issuer seizure of up to 5% of one pool balance.
    function seize(uint256 seed, bool dir) external {
        if (seed % 40 != 0) return;
        TestToken t = dir ? a : b;
        uint256 bal = t.balanceOf(address(pool));
        uint256 amt = bound(seed, 1, bal / 20 + 1);
        if (amt >= bal) return;
        t.burnFrom(address(pool), amt);
        if (dir) seized0 += amt;
        else seized1 += amt;
    }

    function trip() external {
        try pool.tripBrake() {} catch {}
        _trackLatch();
    }

    function wait(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 1 days));
        vm.roll(block.number + 1);
    }

    function sharesOf(uint256 i) external view returns (uint256) {
        return pool.shares(lps[i]);
    }
}

contract SwapPoolInvariantTest is Test {
    PoolHandler h;
    SwapPool pool;
    TestToken a;
    TestToken b;

    function setUp() public {
        vm.warp(1_000_000);
        vm.roll(10);
        a = new TestToken();
        b = new TestToken();
        pool = new SwapPool(address(a), address(b), 30, keccak256("doc"));
        h = new PoolHandler(pool, a, b);
        targetContract(address(h));
    }

    /// @notice Conservation: every token unit in the pool is accounted for by
    ///         deposits and swaps in, payouts out, donations and seizures.
    function invariant_conservation() public view {
        assertEq(a.balanceOf(address(pool)) + h.out0() + h.seized0(), h.in0() + h.donated0(), "token0");
        assertEq(b.balanceOf(address(pool)) + h.out1() + h.seized1(), h.in1() + h.donated1(), "token1");
    }

    /// @notice Books never exceed balances unless an issuer took funds; and
    ///         when they do, the brake predicate shows it.
    function invariant_booksBackedOrBraked() public view {
        (uint112 r0, uint112 r1,) = pool.getReserves();
        bool deficit = a.balanceOf(address(pool)) < r0 || b.balanceOf(address(pool)) < r1;
        if (h.seized0() + h.seized1() == 0) assertFalse(deficit, "deficit without seizure");
        if (deficit) {
            (uint8 s,,) = pool.brakeState();
            assertEq(s, 1, "deficit visible as braked");
        }
    }

    /// @notice Swaps never lower k (constant product grows only by fees), and
    ///         no add/swap/remove lowers value per share for remaining LPs
    ///         (no rounding theft) outside a shared issuer loss.
    function invariant_kAndValuePerShare() public view {
        assertEq(h.kDown(), 0, "k decreased on a swap");
        assertEq(h.valuePerShareDown(), 0, "value per share decreased");
        assertEq(h.overpaid(), 0, "minOut violated");
    }

    /// @notice Exits always open: with honest tokens, every remove by an LP
    ///         holding shares succeeded, braked or not.
    function invariant_exitsAlwaysOpen() public view {
        assertEq(h.exitFailed(), 0);
    }

    /// @notice Brake latch is permanent and closes entry.
    function invariant_brakeLatch() public view {
        assertEq(h.entryAfterLatch(), 0, "entry after latch");
        assertEq(h.latchMoved(), 0, "latch moved");
        (uint8 s, address g, uint64 since) = pool.brakeState();
        assertEq(g, address(0));
        if (since != 0) assertEq(s, 1);
    }

    /// @notice Share accounting: LP shares plus the locked minimum equal supply.
    function invariant_shareSupply() public view {
        uint256 sum = pool.lockedShares();
        for (uint256 i; i < 3; i++) {
            sum += h.sharesOf(i);
        }
        assertEq(sum, pool.totalShares());
        assertEq(pool.lockedShares(), pool.MIN_LOCKED_SHARES());
        (uint112 r0, uint112 r1,) = pool.getReserves();
        assertTrue(r0 > 0 && r1 > 0 || h.seized0() + h.seized1() > 0, "locked shares keep reserves");
    }
}
