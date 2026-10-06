// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test, console} from "forge-std/Test.sol";
import {SwapPool} from "../../src/SwapPool.sol";
import {TestToken} from "../../../common/test/Tokens.sol";
import {MockReferencePrice} from "./MockReferencePrice.sol";

/// @title C0 economic simulation harness for SwapPool (Foundry)
/// @notice Deterministic, seeded simulations of the pool against a TEST-ONLY
///         reference price path. Sustained simulation is substituted for
///         live chain time and is labelled so (MEASUREMENTS "Throughput and
///         latency"). Outputs are arithmetic properties of this code under
///         these synthetic paths, not market results, not EastSea costs and
///         not evidence that any real asset has liquidity. Run with `-vv` to
///         print the numbers.
contract PoolSimulationTest is Test {
    uint256 constant ONE = 1e18;
    uint64 constant FAR = type(uint64).max;

    TestToken a;
    TestToken b;
    SwapPool pool;
    MockReferencePrice ref;
    address lp = makeAddr("sim-lp");
    address arb = makeAddr("sim-arb");
    address noise = makeAddr("sim-noise");
    uint256 lpShares;

    function _setup(uint256 fee, bytes32 seed, uint256 stepBps) internal {
        vm.warp(1_000_000);
        a = new TestToken();
        b = new TestToken();
        pool = new SwapPool(address(a), address(b), fee, 0);
        ref = new MockReferencePrice(seed, ONE, stepBps);
        address[3] memory who = [lp, arb, noise];
        for (uint256 i; i < 3; i++) {
            a.mint(who[i], 1e30);
            b.mint(who[i], 1e30);
            vm.startPrank(who[i]);
            a.approve(address(pool), type(uint256).max);
            b.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lp);
        (,, lpShares) = pool.add(1000e18, 1000e18, 0, FAR);
    }

    function _poolPrice() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = pool.getReserves();
        return uint256(r1) * ONE / r0;
    }

    /// @dev Arbitrageur against an outside venue at price `p` (token1 per
    ///      token0): picks the profit-maximising input by ternary search on
    ///      the pool's own curve, then trades if the profit is positive.
    ///      At the optimum the pool's marginal price is within the fee of `p`.
    ///      Returns the profit in token1 units valued at `p`.
    function _arb(uint256 p) internal returns (int256 profit) {
        (uint112 r0, uint112 r1,) = pool.getReserves();
        bool sellB = uint256(r1) * ONE / r0 < p; // token0 cheap in the pool
        (uint256 rIn, uint256 rOut) = sellB ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
        uint256 lo;
        uint256 hi = rIn;
        while (hi - lo > 2) {
            uint256 m1 = lo + (hi - lo) / 3;
            uint256 m2 = hi - (hi - lo) / 3;
            if (_arbProfit(m1, rIn, rOut, p, sellB) < _arbProfit(m2, rIn, rOut, p, sellB)) lo = m1;
            else hi = m2;
        }
        uint256 x = lo + 1;
        profit = _arbProfit(x, rIn, rOut, p, sellB);
        if (profit <= 0) return 0;
        vm.prank(arb);
        pool.swapExactInput(sellB ? address(b) : address(a), x, 0, arb, FAR);
    }

    function _arbProfit(uint256 x, uint256 rIn, uint256 rOut, uint256 p, bool sellB) internal view returns (int256) {
        if (x == 0) return 0;
        uint256 got = _out(x, rIn, rOut, pool.feeBps());
        // value both legs in token1 at the outside price p
        return sellB ? int256(got * p / ONE) - int256(x) : int256(got) - int256(x * p / ONE);
    }

    /// @dev One seeded noise trade of 0.1-1% of reserves, either direction.
    function _noise(uint256 i) internal returns (bool ok) {
        uint256 r = uint256(keccak256(abi.encode("noise", i)));
        (uint112 r0, uint112 r1,) = pool.getReserves();
        bool dir = r & 1 == 1;
        uint256 size = (dir ? r0 : r1) * (10 + (r >> 8) % 90) / 10_000;
        vm.prank(noise);
        try pool.swapExactInput(dir ? address(a) : address(b), size, 0, noise, FAR) {
            ok = true;
        } catch {}
    }

    function _lpExitValue(uint256 p) internal returns (uint256 value) {
        vm.prank(lp);
        (uint256 o0, uint256 o1) = pool.remove(lpShares, 0, 0, lp, FAR);
        value = o0 * p / ONE + o1;
    }

    /// @notice Fee 0, arbitrage only: the LP's exit value relative to holding
    ///         must match the closed-form constant-product loss
    ///         2*sqrt(p)/(1+p), whatever the path. Validates the harness.
    function test_sim_zeroFee_matchesClosedFormImpermanentLoss() public {
        _setup(0, keccak256("path-1"), 100);
        for (uint256 i; i < 300; i++) {
            _arb(ref.advance());
        }
        uint256 p = ref.truePrice();
        _arb(p);
        uint256 hodl = 1000e18 * p / ONE + 1000e18;
        uint256 lpv = _lpExitValue(p);
        uint256 ratio = lpv * ONE / hodl;
        uint256 expected = 2 * _sqrt(p * ONE) * ONE / (ONE + p);
        console.log("zero-fee: end price (1e18)", p);
        console.log("LP/HODL (1e18)", ratio, "closed form", expected);
        assertApproxEqRel(ratio, expected, 0.002e18, "harness reproduces IL formula");
    }

    /// @notice 30 bps, arbitrage + noise: arbitrage keeps the pool within
    ///         the fee band of the reference, k grows only from fees, and
    ///         the LP outcome is reported against holding and the no-fee
    ///         closed form (no claim that fees beat the loss).
    function test_sim_fee30_bandKeptAndFeesAccrue() public {
        _setup(30, keccak256("path-2"), 100);
        (uint112 r0, uint112 r1,) = pool.getReserves();
        uint256 k0 = uint256(r0) * r1;
        uint256 maxBandBps;
        uint256 noiseFail;
        int256 arbProfit;
        for (uint256 i; i < 300; i++) {
            uint256 p = ref.advance();
            if (!_noise(i)) noiseFail++;
            arbProfit += _arb(p);
            uint256 pp = _poolPrice();
            uint256 dev = pp > p ? (pp - p) * 10_000 / p : (p - pp) * 10_000 / p;
            if (dev > maxBandBps) maxBandBps = dev;
        }
        (r0, r1,) = pool.getReserves();
        uint256 pEnd = ref.truePrice();
        uint256 hodl = 1000e18 * pEnd / ONE + 1000e18;
        uint256 lpv = _lpExitValue(pEnd);
        console.log("fee30: max post-arb deviation (bps)", maxBandBps);
        console.log("fee30: k growth (1e18)", uint256(r0) * r1 * ONE / k0);
        console.log("fee30: LP/HODL (1e18)", lpv * ONE / hodl);
        console.log("fee30: closed-form no-fee LP/HODL", 2 * _sqrt(pEnd * ONE) * ONE / (ONE + pEnd));
        console.log("fee30: arbitrage profit, token1 wei", uint256(arbProfit));
        assertEq(noiseFail, 0, "ordinary swaps never failed");
        assertLe(maxBandBps, 31, "arbitrage leaves price within the 30 bps fee band (+1 bps rounding)");
        assertGt(uint256(r0) * r1, k0, "fees accrued to reserves");
    }

    /// @notice Reporter outage: the reference is withheld for 50 steps.
    ///         Ordinary swaps keep working (no oracle dependency); the pool
    ///         drifts from the hidden true price because arbitrage that relied
    ///         on the withheld reports stops; it returns to the band after.
    function test_sim_withheldReports_swapsContinue_priceDriftsThenRecovers() public {
        _setup(30, keccak256("path-3"), 100);
        uint256 noiseFail;
        uint256 maxDriftBps;
        for (uint256 i; i < 200; i++) {
            if (i == 100) ref.setWithheld(true);
            if (i == 150) ref.setWithheld(false);
            ref.advance();
            if (!_noise(i)) noiseFail++;
            (uint256 published,, bool stale) = ref.read();
            if (!stale) _arb(published);
            uint256 t = ref.truePrice();
            uint256 pp = _poolPrice();
            uint256 dev = pp > t ? (pp - t) * 10_000 / t : (t - pp) * 10_000 / t;
            if (stale && dev > maxDriftBps) maxDriftBps = dev;
        }
        uint256 tEnd = ref.truePrice();
        uint256 ppEnd = _poolPrice();
        uint256 endDev = ppEnd > tEnd ? (ppEnd - tEnd) * 10_000 / tEnd : (tEnd - ppEnd) * 10_000 / tEnd;
        console.log("outage: max drift from hidden price during outage (bps)", maxDriftBps);
        console.log("outage: deviation after reports resume (bps)", endDev);
        assertEq(noiseFail, 0, "every ordinary swap succeeded during the outage");
        assertGt(maxDriftBps, 31, "pool alone cannot know the outside price");
        assertLe(endDev, 31, "back within the fee band once reports resume");
    }

    // ---------------------------------------------------------------- sandwich

    function _out(uint256 x, uint256 rIn, uint256 rOut, uint256 fee) internal pure returns (uint256) {
        uint256 w = x * (10_000 - fee);
        return w * rOut / (rIn * 10_000 + w);
    }

    /// @dev Largest front-run (token0 in) that still lets the victim's
    ///      `amountIn` meet `minOut`, by binary search on the same curve.
    function _maxFrontRun(uint256 amountIn, uint256 minOut) internal view returns (uint256 lo) {
        (uint112 r0, uint112 r1,) = pool.getReserves();
        uint256 fee = pool.feeBps();
        uint256 hi = uint256(r0) * 10;
        for (uint256 i; i < 128 && lo < hi; i++) {
            uint256 mid = (lo + hi + 1) / 2;
            uint256 got = _out(mid, r0, r1, fee);
            if (_out(amountIn, r0 + mid, r1 - got, fee) >= minOut) lo = mid;
            else hi = mid - 1;
        }
    }

    /// @dev Front-run, victim, back-run. Returns attacker profit in token0
    ///      and what the victim received.
    function _sandwich(uint256 amountIn, uint256 minOut) internal returns (int256 profit, uint256 victimOut) {
        uint256 front = _maxFrontRun(amountIn, minOut);
        uint256 a0 = a.balanceOf(arb);
        uint256 got1;
        if (front > 0) {
            vm.prank(arb);
            got1 = pool.swapExactInput(address(a), front, 0, arb, FAR);
        }
        vm.prank(noise);
        victimOut = pool.swapExactInput(address(a), amountIn, minOut, noise, FAR);
        if (got1 > 0) {
            vm.prank(arb);
            pool.swapExactInput(address(b), got1, 0, arb, FAR);
        }
        profit = int256(a.balanceOf(arb)) - int256(a0);
    }

    /// @notice Public inclusion order is reorderable before inclusion (one-
    ///         second finality does not change that). The victim's signed
    ///         `minOut` bounds the damage: it always receives at least it,
    ///         its shortfall never exceeds its own tolerance, and a tighter
    ///         tolerance never gives the attacker more.
    function test_sim_sandwichBoundedByMinOut() public {
        uint256[4] memory tol = [uint256(10), 50, 100, 300];
        int256 prev = type(int256).min;
        for (uint256 i; i < tol.length; i++) {
            _setup(30, keccak256("sandwich"), 100);
            uint256 amountIn = 10e18;
            uint256 quote = pool.quoteExactInput(address(a), amountIn);
            uint256 minOut = quote * (10_000 - tol[i]) / 10_000;
            (int256 profit, uint256 got) = _sandwich(amountIn, minOut);
            console.log("tolerance bps", tol[i]);
            console.log("  victim shortfall vs quote (wei)", quote - got);
            console.log("  attacker profit token0 (wei, signed as uint if >0)", profit > 0 ? uint256(profit) : 0);
            assertGe(got, minOut, "victim gets at least its signed minimum");
            assertLe(quote - got, quote * tol[i] / 10_000 + 1, "shortfall within own tolerance");
            assertGe(profit, prev, "looser tolerance never helps the victim");
            prev = profit;
        }
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
