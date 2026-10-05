// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AllOrNothingCrowdfund} from "src/crowdfund/AllOrNothingCrowdfund.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 12 — 올오어낫싱 크라우드펀드 테스트.
/// @dev fixture: 목표 10 ETH, 마감 30일. alice/bob/carol이 기여한다.
contract AllOrNothingCrowdfundTest is Test {
    AllOrNothingCrowdfund internal fund;

    address internal guardian = makeAddr("guardian");
    address internal beneficiary = makeAddr("beneficiary");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint128 internal constant GOAL = 10 ether;
    uint48 internal constant DURATION = 30 days;

    function setUp() public {
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(beneficiary, 0);
        fund = new AllOrNothingCrowdfund(guardian, beneficiary, GOAL, DURATION);
    }

    function _contributeAs(address who, uint256 value) internal {
        vm.prank(who);
        fund.contribute{value: value}();
    }

    // ---------------------------------------------------------------- 기여

    function test_contribute_accumulates() public {
        _contributeAs(alice, 3 ether);
        assertEq(fund.contributions(alice), 3 ether);

        vm.expectEmit(true, false, false, true);
        emit AllOrNothingCrowdfund.Contributed(bob, 4 ether, 7 ether);
        _contributeAs(bob, 4 ether);

        assertEq(fund.contributions(bob), 4 ether);
        (uint128 raised, bool withdrawn) = fund.campaign();
        assertEq(raised, 7 ether);
        assertFalse(withdrawn);
        assertEq(uint8(fund.state()), 0); // 진행중
        assertEq(address(fund).balance, 7 ether);
    }

    function test_contribute_reverts() public {
        vm.prank(alice);
        vm.expectRevert(AllOrNothingCrowdfund.ZeroAmount.selector);
        fund.contribute{value: 0}();

        // 마감 후
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AllOrNothingCrowdfund.DeadlinePassed.selector, block.timestamp, fund.deadline())
        );
        fund.contribute{value: 1 ether}();

        // 달성 후 (새 캠페인에서)
        AllOrNothingCrowdfund f2 = new AllOrNothingCrowdfund(guardian, beneficiary, GOAL, DURATION);
        vm.prank(alice);
        f2.contribute{value: 10 ether}();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AllOrNothingCrowdfund.AlreadyFunded.selector, GOAL, GOAL));
        f2.contribute{value: 1 ether}();

        // 직접 송금 거부
        (bool ok,) = address(fund).call{value: 1 ether}("");
        assertFalse(ok);

        vm.expectRevert(AllOrNothingCrowdfund.GoalTooLow.selector);
        new AllOrNothingCrowdfund(guardian, beneficiary, 0, DURATION);

        vm.expectRevert(AllOrNothingCrowdfund.DeadlineTooShort.selector);
        new AllOrNothingCrowdfund(guardian, beneficiary, GOAL, 0);

        vm.expectRevert(AllOrNothingCrowdfund.ZeroAmount.selector);
        new AllOrNothingCrowdfund(guardian, address(0), GOAL, DURATION);
    }

    /// @dev 초과 기여 — 마지막 한 방에 목표를 넘어도 전액 수용
    function test_overfundingAccepted() public {
        _contributeAs(alice, 9 ether);
        _contributeAs(bob, 5 ether); // 목표 10을 14로 넘는다
        (uint128 raised,) = fund.campaign();
        assertEq(raised, 14 ether);
        assertEq(uint8(fund.state()), 1); // 달성

        // 인도는 전액 — 초과분은 후원
        vm.prank(alice);
        fund.withdraw();
        assertEq(beneficiary.balance, 14 ether);
    }

    // ---------------------------------------------------------------- 성공 경로

    function test_withdraw_onSuccess() public {
        _contributeAs(alice, 6 ether);
        _contributeAs(bob, 4 ether);
        assertEq(uint8(fund.state()), 1); // 마감 전 조기 달성

        vm.prank(alice); // 누구나 트리거 — 수령인은 beneficiary
        fund.withdraw();
        assertEq(beneficiary.balance, 10 ether);
        assertEq(address(fund).balance, 0);
        assertEq(uint8(fund.state()), 3); // 인도 완료

        vm.prank(bob);
        vm.expectRevert(AllOrNothingCrowdfund.NothingToWithdraw.selector);
        fund.withdraw();
    }

    /// @dev 성공한 캠페인에는 환불이 없다 — all-or-nothing의 "노(not)"
    function test_refund_revertsWhenSucceeded() public {
        _contributeAs(alice, 10 ether);
        vm.warp(block.timestamp + DURATION + 1);

        // 기대 데이터를 prank 전에 계산 — expectRevert 인자 안의 정적
        // 호출(fund.deadline())이 prank를 소비한다
        bytes memory want =
            abi.encodeWithSelector(AllOrNothingCrowdfund.RefundNotAllowed.selector, 10 ether, GOAL, fund.deadline());
        vm.prank(alice);
        vm.expectRevert(want);
        fund.refund();
    }

    function test_refund_revertsWhileActive() public {
        _contributeAs(alice, 3 ether);

        bytes memory want =
            abi.encodeWithSelector(AllOrNothingCrowdfund.RefundNotAllowed.selector, 3 ether, GOAL, fund.deadline());
        vm.prank(alice);
        vm.expectRevert(want);
        fund.refund();

        vm.prank(bob); // 기여 없음
        vm.expectRevert(AllOrNothingCrowdfund.NothingToRefund.selector);
        fund.refund();
    }

    // ---------------------------------------------------------------- 실패 경로

    /// @dev 실패 시 전원 전액 환불 — 슬롯은 지워진다(일시적 상태)
    function test_refund_onFailureClearsSlots() public {
        _contributeAs(alice, 3 ether);
        _contributeAs(bob, 4 ether);
        vm.warp(block.timestamp + DURATION + 1);
        assertEq(uint8(fund.state()), 2); // 실패

        vm.prank(alice);
        fund.refund();
        assertEq(alice.balance, 100 ether);
        assertEq(fund.contributions(alice), 0); // 슬롯 소거

        vm.prank(bob);
        fund.refund();
        assertEq(bob.balance, 100 ether);
        assertEq(fund.contributions(bob), 0);
        assertEq(address(fund).balance, 0);

        vm.prank(alice); // 재환불 불가
        vm.expectRevert(AllOrNothingCrowdfund.NothingToRefund.selector);
        fund.refund();

        // 실패 캠페인 인도 시도
        vm.prank(alice);
        vm.expectRevert(AllOrNothingCrowdfund.NothingToWithdraw.selector);
        fund.withdraw();
    }

    // ---------------------------------------------------------------- 불변식

    /// @dev 자금 보존 — 성공이면 기여 총액 == 인도액, 실패면 기여 총액 ==
    ///      환불 총액. alice가 단독으로 목표를 넘으면 bob의 기여는
    ///      AlreadyFunded로 거부된다(진입 차단) — 그 갈래도 함께 검증.
    function test_fuzz_conservation(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1, 12 ether));
        b = uint96(bound(b, 1, 12 ether));

        _contributeAs(alice, a);
        uint256 paid = a;
        if (a >= GOAL) {
            // 달성 후 진입 차단 — bob의 기여는 받히지 않는다
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(AllOrNothingCrowdfund.AlreadyFunded.selector, a, GOAL));
            fund.contribute{value: b}();
        } else {
            _contributeAs(bob, b); // a+b에 따라 달성 여부가 갈린다
            paid += b;
        }
        vm.warp(block.timestamp + DURATION + 1);

        (uint128 raised,) = fund.campaign();
        if (raised >= GOAL) {
            vm.prank(alice);
            fund.withdraw();
            assertEq(beneficiary.balance, paid); // I1: 전액 인도
        } else {
            vm.prank(alice);
            fund.refund();
            vm.prank(bob);
            fund.refund();
            assertEq(alice.balance + bob.balance, 200 ether); // I2: 전액 환불
            assertEq(address(fund).balance, 0);
        }
    }

    // ---------------------------------------------------------------- brake

    function test_brake_blocksEntryNotExit() public {
        _contributeAs(alice, 3 ether);
        vm.prank(guardian);
        fund.engageBrake(1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        fund.contribute{value: 1 ether}();

        // 탈출은 열려 있다 — 마감 후 환불
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(alice);
        fund.refund();
        assertEq(alice.balance, 100 ether);
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/crowdfund/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r) = StateMeter.measureDeploy(
            abi.encodePacked(
                type(AllOrNothingCrowdfund).creationCode, abi.encode(guardian, beneficiary, GOAL, DURATION)
            )
        );
        emit log_named_uint("fundDeploy gasUsed", r.gasUsed);
        emit log_named_uint("fundDeploy codeBytes", r.codeBytes);
        emit log_named_uint("fundDeploy stateUnits", r.stateUnits);
    }

    function test_meter_lifecycle() public {
        address[] memory tracked = new address[](2);
        tracked[0] = address(fund);

        // 성공 갈래 — 목표를 채우고 인도까지
        StateMeter.Result memory r1 =
            StateMeter.measureCallValue(alice, tracked, address(fund), abi.encodeCall(fund.contribute, ()), 6 ether);
        emit log_named_uint("contribute gasUsed", r1.gasUsed);
        emit log_named_uint("contribute newSlots", r1.newSlots);
        emit log_named_uint("contribute logBytes", r1.logBytes);
        emit log_named_uint("contribute stateUnits", r1.stateUnits);

        StateMeter.Result memory r2 =
            StateMeter.measureCallValue(bob, tracked, address(fund), abi.encodeCall(fund.contribute, ()), 4 ether);
        emit log_named_uint("contribute2 gasUsed", r2.gasUsed);
        emit log_named_uint("contribute2 newSlots", r2.newSlots);
        emit log_named_uint("contribute2 stateUnits", r2.stateUnits);

        StateMeter.Result memory r3 =
            StateMeter.measureCall(alice, tracked, address(fund), abi.encodeCall(fund.withdraw, ()));
        emit log_named_uint("withdraw gasUsed", r3.gasUsed);
        emit log_named_uint("withdraw newSlots", r3.newSlots);
        emit log_named_uint("withdraw logBytes", r3.logBytes);
        emit log_named_uint("withdraw stateUnits", r3.stateUnits);

        // 실패 갈래 — 별도 인스턴스에서 마감 후 환불(슬롯 소거 관찰)
        AllOrNothingCrowdfund f2 = new AllOrNothingCrowdfund(guardian, beneficiary, GOAL, DURATION);
        tracked[1] = address(f2);
        vm.prank(alice);
        f2.contribute{value: 3 ether}();
        vm.warp(block.timestamp + DURATION + 1);

        StateMeter.Result memory r4 = StateMeter.measureCall(alice, tracked, address(f2), abi.encodeCall(f2.refund, ()));
        emit log_named_uint("refund gasUsed", r4.gasUsed);
        emit log_named_uint("refund newSlots", r4.newSlots);
        emit log_named_uint("refund logBytes", r4.logBytes);
        emit log_named_uint("refund stateUnits", r4.stateUnits);
    }
}
