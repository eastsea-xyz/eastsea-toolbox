// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";

/// @notice 회귀 — subscribe()의 축소 캐스트가 지불을 조용히 잘라내면 안 된다.
///         uint64 만료·uint88 납입 두 팩 필드의 잔여 범위를 벗어나는 지불은
///         AmountTooLarge로 거부된다. (aether-node 9d7b148에서 포팅)
contract SubscriptionBoundsTest is Test {
    bytes4 constant TOO_LARGE = bytes4(keccak256("AmountTooLarge()"));

    /// @dev uint64를 넘는 기간은 전액 청구하고 시간은 잘라 넣을 수 없다.
    function test_subscribe_rejectsSecondsAboveUint64() public {
        vm.warp(1_000_000);
        SubscriptionManager sub = new SubscriptionManager(address(this), address(0xbeef), 1);
        uint256 amount = uint256(1) << 64;
        vm.deal(address(this), amount);
        vm.expectRevert(TOO_LARGE);
        sub.subscribe{value: amount}();
        assertEq(sub.refundReserve(), 0); // 실패한 지불이 준비금을 바꾸지 않았다
        assertEq(address(sub).balance, 0);
    }

    /// @dev uint88을 넘는 원금은 환불 준비금으로 회수 불가능하게 남으면 안 된다.
    function test_subscribe_rejectsPrincipalAboveUint88() public {
        vm.warp(1_000_000);
        SubscriptionManager sub = new SubscriptionManager(address(this), address(0xbeef), uint256(1) << 32);
        uint256 amount = uint256(1) << 88; // 기간은 uint64에 들어가고 원금은 uint88을 넘는다
        vm.deal(address(this), amount);
        vm.expectRevert(TOO_LARGE);
        sub.subscribe{value: amount}();
        assertEq(sub.refundReserve(), 0); // 잘린 원금이 남아 있지 않다
        assertEq(address(sub).balance, 0);
    }

    /// @dev 누적 원금이 uint88 경계를 넘는 이어달기도 거부된다.
    function test_subscribe_rejectsCumulativePrincipalCrossingUint88() public {
        vm.warp(1_000_000);
        uint256 rate = uint256(1) << 32;
        uint256 first = (uint256(1) << 88) - rate;
        SubscriptionManager sub = new SubscriptionManager(address(this), address(0xbeef), rate);
        vm.deal(address(this), first + rate);
        sub.subscribe{value: first}();
        (uint64 expiry, uint88 principal) = sub.subscribers(address(this));
        vm.expectRevert(TOO_LARGE);
        sub.subscribe{value: rate}();
        (uint64 afterExpiry, uint88 afterPrincipal) = sub.subscribers(address(this));
        assertEq(afterExpiry, expiry); // 실패한 이어달기가 구독자를 바꾸지 않았다
        assertEq(afterPrincipal, principal);
        assertEq(sub.refundReserve(), first); // 실패한 이어달기가 원금을 바꾸지 않았다
        assertEq(address(sub).balance, first);
    }

    /// @dev 정확한 uint64 만료 경계는 받아들이고, 그 위 1초는 거부한다.
    function test_subscribe_exactUint64ExpiryBoundaryAccepted() public {
        vm.warp(1_000_000);
        SubscriptionManager sub = new SubscriptionManager(address(this), address(0xbeef), 1);
        uint256 amount = uint256(type(uint64).max) - block.timestamp;
        vm.deal(address(this), amount + 1);
        sub.subscribe{value: amount}();
        (uint64 expiry,) = sub.subscribers(address(this));
        assertEq(expiry, type(uint64).max); // 유효한 경계 지불이 거부되지 않았다
        vm.expectRevert(TOO_LARGE);
        sub.subscribe{value: 1}();
    }

    /// @dev 정확한 uint88 원금 경계는 받아들인다.
    function test_subscribe_exactUint88PrincipalBoundaryAccepted() public {
        vm.warp(1_000_000);
        uint256 amount = type(uint88).max;
        SubscriptionManager sub = new SubscriptionManager(address(this), address(0xbeef), amount);
        vm.deal(address(this), amount);
        sub.subscribe{value: amount}();
        (uint64 expiry, uint88 principal) = sub.subscribers(address(this));
        assertEq(expiry, block.timestamp + 1); // 유효한 경계 지불이 거부되지 않았다
        assertEq(uint256(principal), amount); // 잘림 없음
        assertEq(sub.refundReserve(), amount);
    }
}
