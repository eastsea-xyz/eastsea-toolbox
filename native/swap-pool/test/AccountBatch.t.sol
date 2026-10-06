// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {SwapPool} from "../src/SwapPool.sol";
import {TestToken} from "../../common/test/Tokens.sol";
import {SlotDiff} from "../../common/test/SlotDiff.sol";

/// @notice TEST-ONLY mirror of the `execute(Call[])` path of EastSeaAccount
///         (aether-node contracts/src/EastSeaAccount.sol, SOURCES ES2): the
///         same Call struct, the same "only the account itself" rule, the
///         same all-or-nothing loop and `CallFailed(index, reason)`. It is NOT
///         the deployed account: no P-256 verification, owners, guardians or
///         sessions. The executor run must use the real delegated runtime.
contract BatchAccountMirror {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    error OnlySelf();
    error CallFailed(uint256 index, bytes reason);

    event Executed(uint256 calls);

    function execute(Call[] calldata calls) external payable {
        if (msg.sender != address(this)) revert OnlySelf();
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory reason) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            if (!ok) revert CallFailed(i, reason);
        }
        emit Executed(calls.length);
    }
}

/// @notice Wallet-side bounded atomic exchange: one account transaction
///         signature authorises approve(exact) -> swap(min/max, deadline)
///         -> approve(0). The price cap, recipient and expiry are in the
///         signed calldata; nothing else is trusted.
contract AccountBatchTest is Test {
    TestToken a;
    TestToken b;
    TestToken c;
    SwapPool ab;
    SwapPool bc;
    address user = makeAddr("p256-user");
    address lp = makeAddr("lp");
    address searcher = makeAddr("searcher");
    uint64 constant T0 = 1_000_000;

    function setUp() public {
        vm.warp(T0);
        a = new TestToken();
        b = new TestToken();
        c = new TestToken();
        ab = new SwapPool(address(a), address(b), 30, 0);
        bc = new SwapPool(address(b), address(c), 30, 0);
        _seed(ab, a, b);
        _seed(bc, b, c);
        // The user's address carries the account code (EIP-7702 delegation
        // on EastSea; etched here). Balances already nonzero: a warm wallet.
        vm.etch(user, address(new BatchAccountMirror()).code);
        a.mint(user, 10e18);
        b.mint(user, 1);
        c.mint(user, 1);
        a.mint(searcher, 1e24);
        vm.prank(searcher);
        a.approve(address(ab), type(uint256).max);
    }

    function _seed(SwapPool p, TestToken x, TestToken y) internal {
        x.mint(lp, 1e24);
        y.mint(lp, 1e24);
        vm.startPrank(lp);
        x.approve(address(p), type(uint256).max);
        y.approve(address(p), type(uint256).max);
        p.add(1000e18, 1000e18, 0, type(uint64).max);
        vm.stopPrank();
    }

    function _call(address to, bytes memory data) internal pure returns (BatchAccountMirror.Call memory) {
        return BatchAccountMirror.Call(to, 0, data);
    }

    function _exactInBatch(uint256 amountIn, uint256 minOut, uint64 deadline)
        internal
        view
        returns (BatchAccountMirror.Call[] memory calls)
    {
        calls = new BatchAccountMirror.Call[](3);
        calls[0] = _call(address(a), abi.encodeCall(TestToken.approve, (address(ab), amountIn)));
        calls[1] =
            _call(address(ab), abi.encodeCall(SwapPool.swapExactInput, (address(a), amountIn, minOut, user, deadline)));
        calls[2] = _call(address(a), abi.encodeCall(TestToken.approve, (address(ab), 0)));
    }

    function _send(BatchAccountMirror.Call[] memory calls) internal {
        vm.prank(user); // the account's own transaction: msg.sender == account
        BatchAccountMirror(user).execute(calls);
    }

    function test_approveSwapReset_oneSignature_noLingeringAllowance() public {
        uint256 q = ab.quoteExactInput(address(a), 1e18);
        uint256 minOut = q * 995 / 1000; // wallet shows "receive at least"
        SlotDiff.start();
        _send(_exactInBatch(1e18, minOut, T0 + 60));
        assertEq(SlotDiff.stop(address(a)).occupied, 0, "allowance set and cleared: no final slot");
        assertEq(a.allowance(user, address(ab)), 0);
        assertEq(a.balanceOf(user), 9e18);
        assertEq(b.balanceOf(user), 1 + q);
    }

    function test_warmBatch_occupiesNoNewSlotInPoolOrOutputToken() public {
        SlotDiff.start();
        _send(_exactInBatch(1e18, 1, T0 + 60));
        assertEq(SlotDiff.stop(address(ab)).occupied, 0, "pool");
        SlotDiff.start();
        _send(_exactInBatch(1e18, 1, T0 + 60));
        assertEq(SlotDiff.stop(address(b)).occupied, 0, "output balance already nonzero");
    }

    /// @notice Someone trades first and moves the price past the cap: the
    ///         whole batch rolls back, including the approval.
    function test_priceMovedPastCap_wholeBatchReverts() public {
        uint256 q = ab.quoteExactInput(address(a), 1e18);
        uint256 minOut = q * 995 / 1000;
        vm.prank(searcher);
        ab.swapExactInput(address(a), 50e18, 0, searcher, type(uint64).max);
        uint256 now_ = ab.quoteExactInput(address(a), 1e18);
        assertLt(now_, minOut);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchAccountMirror.CallFailed.selector,
                1,
                abi.encodeWithSelector(SwapPool.SlippageOut.selector, now_, minOut)
            )
        );
        BatchAccountMirror(user).execute(_exactInBatch(1e18, minOut, T0 + 60));
        assertEq(a.balanceOf(user), 10e18);
        assertEq(a.allowance(user, address(ab)), 0);
    }

    function test_expiredBatchReverts() public {
        BatchAccountMirror.Call[] memory calls = _exactInBatch(1e18, 1, T0 + 60);
        vm.warp(T0 + 61);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchAccountMirror.CallFailed.selector, 1, abi.encodeWithSelector(SwapPool.Expired.selector)
            )
        );
        BatchAccountMirror(user).execute(calls);
    }

    function test_onlyTheAccountCanExecute() public {
        vm.prank(searcher);
        vm.expectRevert(BatchAccountMirror.OnlySelf.selector);
        BatchAccountMirror(user).execute(_exactInBatch(1e18, 1, T0 + 60));
    }

    /// @notice Exact output: the wallet approves the cap, pays at most it,
    ///         and resets the unused remainder in the same batch.
    function test_exactOutputBatch_unusedCapReset() public {
        uint256 need = ab.quoteExactOutput(address(a), 1e18);
        uint256 maxIn = need * 1005 / 1000;
        BatchAccountMirror.Call[] memory calls = new BatchAccountMirror.Call[](3);
        calls[0] = _call(address(a), abi.encodeCall(TestToken.approve, (address(ab), maxIn)));
        calls[1] =
            _call(address(ab), abi.encodeCall(SwapPool.swapExactOutput, (address(a), 1e18, maxIn, user, T0 + 60)));
        calls[2] = _call(address(a), abi.encodeCall(TestToken.approve, (address(ab), 0)));
        _send(calls);
        assertEq(a.balanceOf(user), 10e18 - need);
        assertEq(b.balanceOf(user), 1 + 1e18);
        assertEq(a.allowance(user, address(ab)), 0);
    }

    /// @notice Bounded two-hop route A -> B -> C in one signature. Each leg
    ///         has its own explicit bound: hop 1 must yield at least `bMid`,
    ///         hop 2 spends exactly `bMid` and must yield at least `cMin`.
    ///         Any B above `bMid` stays in the wallet, visible to the user.
    ///         Route search happened off-chain; the chain only enforces bounds.
    function _routeBatch(uint256 aIn, uint256 bMid, uint256 cMin)
        internal
        view
        returns (BatchAccountMirror.Call[] memory calls)
    {
        uint64 dl = T0 + 60;
        calls = new BatchAccountMirror.Call[](6);
        calls[0] = _call(address(a), abi.encodeCall(TestToken.approve, (address(ab), aIn)));
        calls[1] = _call(address(ab), abi.encodeCall(SwapPool.swapExactInput, (address(a), aIn, bMid, user, dl)));
        calls[2] = _call(address(b), abi.encodeCall(TestToken.approve, (address(bc), bMid)));
        calls[3] = _call(address(bc), abi.encodeCall(SwapPool.swapExactInput, (address(b), bMid, cMin, user, dl)));
        calls[4] = _call(address(a), abi.encodeCall(TestToken.approve, (address(ab), 0)));
        calls[5] = _call(address(b), abi.encodeCall(TestToken.approve, (address(bc), 0)));
    }

    function test_boundedTwoHopRoute_atomic() public {
        uint256 q1 = ab.quoteExactInput(address(a), 2e18);
        uint256 bMid = q1 * 995 / 1000;
        uint256 q2 = bc.quoteExactInput(address(b), bMid);
        uint256 cMin = q2 * 995 / 1000;
        _send(_routeBatch(2e18, bMid, cMin));
        assertEq(a.balanceOf(user), 8e18, "spent exactly aIn");
        assertGe(c.balanceOf(user) - 1, cMin, "received at least cMin");
        assertEq(b.balanceOf(user) - 1, q1 - bMid, "hop-1 excess stays visible in the wallet");
        assertEq(a.allowance(user, address(ab)), 0);
        assertEq(b.allowance(user, address(bc)), 0);
    }

    function test_boundedRoute_secondLegFails_everythingRollsBack() public {
        uint256 q1 = ab.quoteExactInput(address(a), 2e18);
        uint256 bMid = q1 * 995 / 1000;
        uint256 cMin = bc.quoteExactInput(address(b), bMid) + 1; // unattainable
        vm.prank(user);
        vm.expectRevert();
        BatchAccountMirror(user).execute(_routeBatch(2e18, bMid, cMin));
        assertEq(a.balanceOf(user), 10e18);
        assertEq(b.balanceOf(user), 1);
        assertEq(c.balanceOf(user), 1);
        (uint112 r0, uint112 r1,) = ab.getReserves();
        assertEq(r0, 1000e18, "first pool untouched");
        assertEq(r1, 1000e18);
    }
}
