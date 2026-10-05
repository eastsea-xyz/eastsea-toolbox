// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 10 — 구독 관리자 테스트.
/// @dev fixture: rate 1 gwei/초 — 1일 = 86_400 gwei ≈ 0.0000864 ETH.
contract SubscriptionManagerTest is Test {
    SubscriptionManager internal sub;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal guardian = makeAddr("guardian");
    address internal payee = makeAddr("payee");

    uint256 internal constant RATE = 1 gwei;
    uint256 internal constant DAY = 86_400;

    function setUp() public {
        sub = new SubscriptionManager(guardian, payee, RATE);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
    }

    function _subscribeAs(address who, uint256 value) internal {
        vm.prank(who);
        sub.subscribe{value: value}();
    }

    function _expiry(address who) internal view returns (uint64) {
        (uint64 expiry,) = sub.subscribers(who);
        return expiry;
    }

    // ---------------------------------------------------------------- 구독

    function test_subscribe_buysTime() public {
        _subscribeAs(alice, 3 * DAY * RATE);
        assertEq(_expiry(alice), block.timestamp + 3 * DAY);
        assertTrue(sub.isSubscribed(alice));
        assertEq(address(sub).balance, 3 * DAY * RATE);
        assertEq(sub.refundReserve(), 3 * DAY * RATE); // 전액이 환불 준비금
        assertEq(sub.claimableRevenue(), 0); // 아직 수익 없음
    }

    /// @dev 재구독은 만료 시각에 이어 붙는다 — 잔여 기간 손실 없음.
    function test_subscribe_extendsFromExpiry() public {
        _subscribeAs(alice, 2 * DAY * RATE);
        vm.warp(block.timestamp + DAY);
        _subscribeAs(alice, 2 * DAY * RATE); // 만료까지 1일 남은 상태
        assertEq(_expiry(alice), block.timestamp + 3 * DAY); // 1 + 2
        assertEq(sub.refundReserve(), 4 * DAY * RATE); // 납입 누적
    }

    /// @dev 만료 후 재구독은 지금부터 — 죽은 시간이 이어지지 않는다.
    ///      이전 기간 납입분은 이때 수익으로 정산된다.
    function test_subscribe_afterExpiryStartsNow() public {
        _subscribeAs(alice, DAY * RATE);
        vm.warp(block.timestamp + 2 * DAY); // 만료 1일 경과

        vm.expectEmit(true, false, false, true);
        emit SubscriptionManager.Settled(alice, DAY * RATE);
        _subscribeAs(alice, DAY * RATE);

        assertEq(_expiry(alice), block.timestamp + DAY);
        assertEq(sub.refundReserve(), DAY * RATE); // 새 기간만
        assertEq(sub.claimableRevenue(), DAY * RATE); // 죽은 기간 = 수익
    }

    /// @dev 1초 미만 지불은 거부 — dust(<1초치)는 거부 없이 수익이 된다.
    function test_subscribe_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionManager.PaymentTooSmall.selector, RATE - 1, RATE));
        sub.subscribe{value: RATE - 1}();

        // dust 흡수: 1일 + 0.5초치 지불 → 정확히 1일, 0.5초치는 즉시 수익
        _subscribeAs(alice, DAY * RATE + RATE / 2);
        assertEq(_expiry(alice), block.timestamp + DAY);
        assertEq(sub.claimableRevenue(), RATE / 2);

        // 직접 송금 거부
        (bool ok,) = address(sub).call{value: 1 ether}("");
        assertFalse(ok);

        vm.expectRevert(SubscriptionManager.ZeroPayee.selector);
        new SubscriptionManager(guardian, address(0), RATE);

        vm.expectRevert(abi.encodeWithSelector(SubscriptionManager.PaymentTooSmall.selector, 0, 1));
        new SubscriptionManager(guardian, payee, 0);
    }

    // ---------------------------------------------------------------- 취소

    /// @dev 정확히 남은 초 × 요율 — 1.5일 후 취소하면 1.5일치 환불.
    ///      납입 전액이 준비금에서 풀려 소비분이 수익이 된다.
    function test_cancel_refundsProRata() public {
        _subscribeAs(alice, 3 * DAY * RATE);
        vm.warp(block.timestamp + 1.5 days);
        uint256 before = alice.balance;

        vm.prank(alice);
        sub.cancel();

        assertEq(alice.balance, before + 1.5 days * RATE); // 남은 1.5일치
        assertFalse(sub.isSubscribed(alice));
        assertEq(_expiry(alice), block.timestamp);
        assertEq(address(sub).balance, 1.5 days * RATE); // 소비분이 전부다
        assertEq(sub.refundReserve(), 0); // 납입 전액 해제
        assertEq(sub.claimableRevenue(), 1.5 days * RATE);

        vm.prank(alice); // 재취소 불가
        vm.expectRevert(SubscriptionManager.NotSubscribed.selector);
        sub.cancel();
    }

    function test_cancel_revertsWhenExpired() public {
        _subscribeAs(alice, DAY * RATE);
        vm.warp(block.timestamp + 2 * DAY);
        vm.prank(alice);
        vm.expectRevert(SubscriptionManager.NotSubscribed.selector);
        sub.cancel();

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(SubscriptionManager.NotSubscribed.selector);
        sub.cancel();
    }

    // ---------------------------------------------------------------- 수익 정산

    /// @dev 활성 구독이 남은 동안에는 수익 인도가 불가 — 전액이 준비금이다.
    function test_claimBlockedWhileActive() public {
        _subscribeAs(alice, 3 * DAY * RATE);
        vm.warp(block.timestamp + DAY); // 1일 소비, 2일 잔여

        vm.prank(payee);
        vm.expectRevert(SubscriptionManager.NothingToClaim.selector);
        sub.claimRevenue();

        vm.prank(alice); // 취소로 소비 1일치만 수익화
        sub.cancel();
        assertEq(sub.claimableRevenue(), DAY * RATE);
    }

    /// @dev 만료 방치 구독은 permissionless settle로 수익 확정 —
    ///      키퍼가 대신 트리거한다. payee는 온체인 행동이 필요 없다.
    function test_settleExpiredUnlocksLapsedRevenue() public {
        _subscribeAs(bob, DAY * RATE);
        vm.warp(block.timestamp + 2 * DAY); // 만료 1일 경과

        vm.prank(makeAddr("keeper"));
        vm.expectEmit(true, false, false, true);
        emit SubscriptionManager.Settled(bob, DAY * RATE);
        sub.settleExpired(bob);

        assertEq(sub.claimableRevenue(), DAY * RATE);
        vm.prank(makeAddr("keeper"));
        sub.claimRevenue();
        assertEq(payee.balance, DAY * RATE); // 수취인 지급 — 누가 트리거했든
        assertEq(address(sub).balance, 0);

        // 정산은 1회 — 재호출은 거부
        vm.prank(makeAddr("keeper"));
        vm.expectRevert(SubscriptionManager.NothingToSettle.selector);
        sub.settleExpired(bob);
    }

    /// @dev 활성 구독 정산 시도는 거부 — 부채를 훔칠 수 없다.
    function test_settleExpired_reverts() public {
        _subscribeAs(alice, 3 * DAY * RATE);
        vm.prank(makeAddr("keeper"));
        vm.expectRevert(SubscriptionManager.NothingToSettle.selector);
        sub.settleExpired(alice);

        vm.prank(makeAddr("keeper"));
        vm.expectRevert(SubscriptionManager.NothingToSettle.selector);
        sub.settleExpired(makeAddr("neverSubscribed"));
    }

    // ---------------------------------------------------------------- 불변식

    /// @dev 자금 보존 — 지불 총액 == 되돌려받은 분 + 컨트랙트 잔액.
    ///      dust도 컨트랙트에 남으므로 등식이 정확히 성립한다.
    ///      준비금은 잔액을 초과할 수 없다(환불 전액 뒷받침).
    function test_fuzz_paymentConservation(uint96 pay1, uint96 pay2, uint256 t1, uint256 t2) public {
        pay1 = uint96(bound(pay1, RATE, 10 * DAY * RATE));
        pay2 = uint96(bound(pay2, RATE, 10 * DAY * RATE));
        t1 = bound(t1, 0, 20 * DAY);
        t2 = bound(t2, 0, 20 * DAY);

        _subscribeAs(alice, pay1);
        vm.warp(block.timestamp + t1);
        vm.prank(alice);
        try sub.cancel() {} catch {} // 만료 상태면 NotSubscribed — 정상

        _subscribeAs(alice, pay2);
        vm.warp(block.timestamp + t2);

        // I1: 준비금 상한 — 환불 가능액은 항상 잔액으로 뒷받침
        assertLe(sub.refundReserve(), address(sub).balance);

        // I2: 자금 보존 — 유출은 환불뿐 (수익 인도는 fuzz에서 호출 안 함)
        uint256 paid = pay1 + pay2;
        uint256 received = alice.balance - (1_000 ether - paid);
        assertEq(received + address(sub).balance, paid);
    }

    // ---------------------------------------------------------------- brake

    function test_brake_blocksEntryNotExit() public {
        _subscribeAs(alice, 3 * DAY * RATE);
        vm.warp(block.timestamp + DAY);
        vm.prank(guardian);
        sub.engageBrake(1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        sub.subscribe{value: DAY * RATE}();

        // 탈출은 열려 있다 — 남은 2일치 환불
        vm.prank(alice);
        sub.cancel();
        assertEq(alice.balance, 1_000 ether - DAY * RATE);

        // 수익 인도도 탈출 — brake 하에 그대로 지급된다
        vm.prank(makeAddr("keeper"));
        sub.claimRevenue();
        assertEq(payee.balance, DAY * RATE);
        assertEq(address(sub).balance, 0);
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/subscription/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r) = StateMeter.measureDeploy(
            abi.encodePacked(type(SubscriptionManager).creationCode, abi.encode(guardian, payee, RATE))
        );
        emit log_named_uint("subDeploy gasUsed", r.gasUsed);
        emit log_named_uint("subDeploy codeBytes", r.codeBytes);
        emit log_named_uint("subDeploy stateUnits", r.stateUnits);
    }

    function test_meter_lifecycle() public {
        address[] memory tracked = new address[](1);
        tracked[0] = address(sub);

        StateMeter.Result memory r1 = StateMeter.measureCallValue(
            alice, tracked, address(sub), abi.encodeCall(sub.subscribe, ()), 30 * DAY * RATE
        );
        emit log_named_uint("subscribe30d gasUsed", r1.gasUsed);
        emit log_named_uint("subscribe30d newSlots", r1.newSlots);
        emit log_named_uint("subscribe30d logBytes", r1.logBytes);
        emit log_named_uint("subscribe30d stateUnits", r1.stateUnits);

        vm.warp(block.timestamp + DAY);

        StateMeter.Result memory r2 = StateMeter.measureCallValue(
            alice, tracked, address(sub), abi.encodeCall(sub.subscribe, ()), 30 * DAY * RATE
        );
        emit log_named_uint("renew gasUsed", r2.gasUsed);
        emit log_named_uint("renew newSlots", r2.newSlots);
        emit log_named_uint("renew logBytes", r2.logBytes);
        emit log_named_uint("renew stateUnits", r2.stateUnits);

        StateMeter.Result memory r3 =
            StateMeter.measureCall(alice, tracked, address(sub), abi.encodeCall(sub.cancel, ()));
        emit log_named_uint("cancel gasUsed", r3.gasUsed);
        emit log_named_uint("cancel newSlots", r3.newSlots);
        emit log_named_uint("cancel logBytes", r3.logBytes);
        emit log_named_uint("cancel stateUnits", r3.stateUnits);

        StateMeter.Result memory r4 =
            StateMeter.measureCall(alice, tracked, address(sub), abi.encodeCall(sub.claimRevenue, ()));
        emit log_named_uint("claimRevenue gasUsed", r4.gasUsed);
        emit log_named_uint("claimRevenue newSlots", r4.newSlots);
        emit log_named_uint("claimRevenue logBytes", r4.logBytes);
        emit log_named_uint("claimRevenue stateUnits", r4.stateUnits);
    }
}
