// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {SwapPool} from "../src/SwapPool.sol";
import {TestToken} from "../../common/test/Tokens.sol";

abstract contract PoolBase is Test {
    TestToken a;
    TestToken b;
    SwapPool pool;
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address trader = makeAddr("trader");
    address stranger = makeAddr("stranger");
    uint64 constant T0 = 1_000_000;
    uint64 constant FAR = type(uint64).max;
    uint256 constant FEE = 30;

    function _deploy(TestToken ta, TestToken tb, uint256 fee) internal {
        vm.warp(T0);
        vm.roll(100);
        a = ta;
        b = tb;
        pool = new SwapPool(address(ta), address(tb), fee, keccak256("brake doc"));
        address[3] memory who = [lp1, lp2, trader];
        for (uint256 i; i < who.length; i++) {
            ta.mint(who[i], 1e30);
            tb.mint(who[i], 1e30);
            vm.startPrank(who[i]);
            ta.approve(address(pool), type(uint256).max);
            tb.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _add(address who, uint256 x, uint256 y) internal returns (uint256 minted) {
        vm.prank(who);
        (,, minted) = pool.add(x, y, 0, FAR);
    }

    function _sell(address who, TestToken tin, uint256 amountIn) internal returns (uint256 out) {
        vm.prank(who);
        out = pool.swapExactInput(address(tin), amountIn, 0, who, FAR);
    }

    function _reserves() internal view returns (uint256 r0, uint256 r1) {
        (r0, r1,) = pool.getReserves();
    }

    /// @dev sqrt(k) per share as an exact cross-multiplied comparison helper:
    ///      returns r0*r1 (fits: both reserves < 2^112).
    function _k() internal view returns (uint256) {
        (uint256 r0, uint256 r1) = _reserves();
        return r0 * r1;
    }

    /// @dev True when (k1 / t1^2) >= (k0 / t0^2), using 512-bit products.
    function _valuePerShareNotDown(uint256 k0, uint256 t0, uint256 k1, uint256 t1) internal pure returns (bool) {
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
}
