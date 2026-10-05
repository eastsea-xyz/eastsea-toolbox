// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MilestoneEscrow} from "src/escrow/MilestoneEscrow.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 9 — 마일스톤 에스크로 테스트.
/// @dev fixture: alice(구매자)가 bob(판매자)에게 10 ether, 마일스톤 3개.
///      승인 스텝: 3e / 4e / 3e = 10e.
contract MilestoneEscrowTest is Test {
    MilestoneEscrow internal escrow;

    address internal alice = makeAddr("alice"); // 구매자
    address internal bob = makeAddr("bob"); // 판매자
    address internal guardian = makeAddr("guardian");

    uint256 internal constant DEPOSIT = 10 ether;

    function setUp() public {
        escrow = new MilestoneEscrow(guardian);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 10 ether);
    }

    /// @dev 표준 딜 — id 1, alice→bob, 10 ether / 3 마일스톤.
    function _createDeal() internal returns (uint256) {
        vm.prank(alice);
        escrow.createDeal{value: DEPOSIT}(bob, 3);
        return 1;
    }

    /// @dev alice가 index에 amount를 승인한다.
    function _approve(uint256 dealId, uint64 index, uint256 amount) internal {
        vm.prank(alice);
        escrow.approveMilestone(dealId, index, amount);
    }

    // ---------------------------------------------------------------- 생성

    function test_create_escrowsNative() public {
        uint256 id = _createDeal();
        (address buyer, address seller, uint256 refundable, uint256 withdrawable) = escrow.dealInfo(id);
        assertEq(buyer, alice);
        assertEq(seller, bob);
        assertEq(refundable, DEPOSIT);
        assertEq(withdrawable, 0);
        assertEq(address(escrow).balance, DEPOSIT);
    }

    function test_create_reverts() public {
        vm.prank(alice);
        vm.expectRevert(MilestoneEscrow.ZeroAmount.selector);
        escrow.createDeal(bob, 3); // value 0

        vm.prank(alice);
        vm.expectRevert(MilestoneEscrow.ZeroMilestones.selector);
        escrow.createDeal{value: 1 ether}(bob, 0);

        vm.prank(alice);
        vm.expectRevert(MilestoneEscrow.NotDealParty.selector);
        escrow.createDeal{value: 1 ether}(address(0), 3);

        vm.prank(alice);
        vm.expectRevert(MilestoneEscrow.NotDealParty.selector);
        escrow.createDeal{value: 1 ether}(alice, 3); // 자기 자신

        // 직접 송금 거부 — 자금은 회계를 거쳐야 한다
        (bool ok,) = address(escrow).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(escrow).balance, 0);
    }

    /// @dev 여러 딜이 공존하고 회계가 섞이지 않는다.
    function test_create_multipleDealsIsolated() public {
        _createDeal(); // id 1: alice→bob 10e
        vm.prank(bob);
        escrow.createDeal{value: 4 ether}(alice, 1); // id 2: 역방향
        _approve(1, 0, 3 ether);
        vm.prank(bob); // id 2 승인자는 bob
        escrow.approveMilestone(2, 0, 4 ether);

        (,, uint256 r1, uint256 w1) = escrow.dealInfo(1);
        (,, uint256 r2, uint256 w2) = escrow.dealInfo(2);
        assertEq(r1, 7 ether);
        assertEq(w1, 3 ether);
        assertEq(r2, 0 ether);
        assertEq(w2, 4 ether);
    }

    // ---------------------------------------------------------------- 승인

    function test_approve_grantsWithdrawRight() public {
        uint256 id = _createDeal();
        _approve(id, 0, 3 ether);
        (,, uint256 refundable, uint256 withdrawable) = escrow.dealInfo(id);
        assertEq(refundable, 7 ether);
        assertEq(withdrawable, 3 ether);
        assertEq(address(escrow).balance, DEPOSIT); // 아직 인출 전
    }

    function test_approve_reverts() public {
        uint256 id = _createDeal();

        vm.prank(bob); // 판매자는 승인 불가
        vm.expectRevert(MilestoneEscrow.NotDealParty.selector);
        escrow.approveMilestone(id, 0, 1 ether);

        vm.prank(alice);
        vm.expectRevert(MilestoneEscrow.ZeroAmount.selector);
        escrow.approveMilestone(id, 0, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.IndexOutOfRange.selector, 3, 3));
        escrow.approveMilestone(id, 3, 1 ether); // 개수 초과

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.ExceedsDeposit.selector, 11 ether, 10 ether));
        escrow.approveMilestone(id, 0, 11 ether); // 예치 초과

        _approve(id, 0, 3 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.MilestoneAlreadyApproved.selector, id, 0));
        escrow.approveMilestone(id, 0, 1 ether); // 같은 인덱스 2회

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.DealNotFound.selector, 42));
        escrow.approveMilestone(42, 0, 1 ether); // 없는 딜
    }

    /// @dev 연속 승인의 합이 예치를 넘으면 그 시점에 죽는다.
    function test_approve_sumCannotExceedDeposit() public {
        uint256 id = _createDeal();
        _approve(id, 0, 6 ether);
        _approve(id, 1, 4 ether); // 정확히 10 — OK
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.ExceedsDeposit.selector, 1 ether, 0));
        escrow.approveMilestone(id, 2, 1 ether);
    }

    // ---------------------------------------------------------------- 인출·환불

    function test_withdraw_paysApproved() public {
        uint256 id = _createDeal();
        _approve(id, 0, 3 ether);
        _approve(id, 1, 4 ether);

        vm.prank(bob);
        escrow.sellerWithdraw(id);
        assertEq(bob.balance, 10 ether + 7 ether);

        vm.prank(bob);
        vm.expectRevert(MilestoneEscrow.NothingToWithdraw.selector);
        escrow.sellerWithdraw(id); // 인출분 소진

        _approve(id, 2, 3 ether); // 마지막 마일스톤
        vm.prank(bob);
        escrow.sellerWithdraw(id);
        assertEq(bob.balance, 10 ether + DEPOSIT);
        assertEq(address(escrow).balance, 0);
    }

    function test_refund_returnsUnapproved() public {
        uint256 id = _createDeal();
        _approve(id, 0, 3 ether);

        vm.prank(alice);
        escrow.buyerRefund(id);
        assertEq(alice.balance, 100 ether - DEPOSIT + 7 ether);

        // 잔여는 승인분뿐 — 재환불 불가
        vm.prank(alice);
        vm.expectRevert(MilestoneEscrow.NothingToRefund.selector);
        escrow.buyerRefund(id);

        // 승인분은 판매자가 그대로 인출한다
        vm.prank(bob);
        escrow.sellerWithdraw(id);
        assertEq(bob.balance, 10 ether + 3 ether);
        assertEq(address(escrow).balance, 0);
    }

    /// @dev 전액 환불 후 딜은 소멸 상태 — deposited==0으로 미사용 id와 같다.
    function test_refund_fullClosesDeal() public {
        uint256 id = _createDeal();
        vm.prank(alice);
        escrow.buyerRefund(id);
        assertEq(alice.balance, 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MilestoneEscrow.DealNotFound.selector, id));
        escrow.approveMilestone(id, 0, 1 ether);
    }

    /// @dev 악성 수신 컨트랙트가 _pay를 삼켜도 CEI라 잔액은 보존된다.
    function test_withdraw_revertPayerKeepsAccounting() public {
        // bob을 삼키는(silent revert) 컨트랙트로 대체
        BlackHole payer = new BlackHole();
        vm.prank(alice);
        escrow.createDeal{value: 5 ether}(address(payer), 2);
        vm.prank(alice);
        escrow.approveMilestone(1, 0, 5 ether);

        vm.prank(address(payer));
        vm.expectRevert(MilestoneEscrow.NativeTransferFailed.selector);
        escrow.sellerWithdraw(1);
        // withdrawnTotal은 갱신 안 됨 — 재시도 가능
        (,, uint256 refundable, uint256 withdrawable) = escrow.dealInfo(1);
        assertEq(refundable, 0);
        assertEq(withdrawable, 5 ether);
    }

    // ---------------------------------------------------------------- brake

    function test_brake_blocksEntryNotExit() public {
        uint256 id = _createDeal();
        _approve(id, 0, 4 ether);
        vm.prank(guardian);
        escrow.engageBrake(1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        escrow.createDeal{value: 1 ether}(bob, 3);

        // 승인·인출·환불은 열려 있다
        _approve(id, 1, 3 ether);
        vm.prank(bob);
        escrow.sellerWithdraw(id);
        vm.prank(alice);
        escrow.buyerRefund(id);
        assertEq(address(escrow).balance, 0);
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev 임의의 승인/인출/환불 시퀀스 후:
    ///      컨트랙트 잔액 == withdrawable + refundable (I1),
    ///      지급 총액 + 잔액 == 예치 총액 (I2 보존).
    function test_fuzz_escrowAlwaysSolvent(uint128 seed1, uint128 seed2, uint128 seed3) public {
        uint256 id = _createDeal();
        uint256[3] memory seeds = [uint256(seed1), uint256(seed2), uint256(seed3)];

        for (uint256 step; step < 3; ++step) {
            uint256 s = seeds[step];
            uint64 idx = uint64(s % 3);
            if (s % 4 != 0) {
                // 승인 시도 — 실패(초과·중복)는 조용히 넘어간다 (정상 revert)
                uint256 amt = (s >> 8) % 6 ether;
                if (amt > 0) {
                    vm.prank(alice);
                    try escrow.approveMilestone(id, idx, amt) {} catch {}
                }
            }
            if ((s >> 16) % 2 == 0) {
                vm.prank(bob);
                try escrow.sellerWithdraw(id) {} catch {}
            } else {
                vm.prank(alice);
                try escrow.buyerRefund(id) {} catch {}
            }

            (,, uint256 refundable, uint256 withdrawable) = escrow.dealInfo(id);
            assertEq(address(escrow).balance, refundable + withdrawable); // I1
        }

        // I2: 예치 10e == bob 인출 + alice 환불 + 컨트랙트 잔액
        assertEq((bob.balance - 10 ether) + (alice.balance - (100 ether - DEPOSIT)) + address(escrow).balance, DEPOSIT);
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/escrow/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r) =
            StateMeter.measureDeploy(abi.encodePacked(type(MilestoneEscrow).creationCode, abi.encode(guardian)));
        emit log_named_uint("escrowDeploy gasUsed", r.gasUsed);
        emit log_named_uint("escrowDeploy codeBytes", r.codeBytes);
        emit log_named_uint("escrowDeploy stateUnits", r.stateUnits);
    }

    function test_meter_lifecycle() public {
        address[] memory tracked = new address[](1);
        tracked[0] = address(escrow);

        StateMeter.Result memory r1 = StateMeter.measureCallValue(
            alice, tracked, address(escrow), abi.encodeCall(escrow.createDeal, (bob, 3)), DEPOSIT
        );
        emit log_named_uint("createDeal(10e) gasUsed", r1.gasUsed);
        emit log_named_uint("createDeal newSlots", r1.newSlots);
        emit log_named_uint("createDeal logBytes", r1.logBytes);
        emit log_named_uint("createDeal stateUnits", r1.stateUnits);

        StateMeter.Result memory r2 = StateMeter.measureCall(
            alice, tracked, address(escrow), abi.encodeCall(escrow.approveMilestone, (1, 0, 4 ether))
        );
        emit log_named_uint("approve gasUsed", r2.gasUsed);
        emit log_named_uint("approve newSlots", r2.newSlots);
        emit log_named_uint("approve logBytes", r2.logBytes);
        emit log_named_uint("approve stateUnits", r2.stateUnits);

        StateMeter.Result memory r3 =
            StateMeter.measureCall(bob, tracked, address(escrow), abi.encodeCall(escrow.sellerWithdraw, (1)));
        emit log_named_uint("withdraw gasUsed", r3.gasUsed);
        emit log_named_uint("withdraw newSlots", r3.newSlots);
        emit log_named_uint("withdraw logBytes", r3.logBytes);
        emit log_named_uint("withdraw stateUnits", r3.stateUnits);

        StateMeter.Result memory r4 =
            StateMeter.measureCall(alice, tracked, address(escrow), abi.encodeCall(escrow.buyerRefund, (1)));
        emit log_named_uint("refund gasUsed", r4.gasUsed);
        emit log_named_uint("refund newSlots", r4.newSlots);
        emit log_named_uint("refund logBytes", r4.logBytes);
        emit log_named_uint("refund stateUnits", r4.stateUnits);
    }
}

/// @dev 지급을 삼키는 수신자 — _pay 실패 경로 시험용.
contract BlackHole {
    receive() external payable {
        revert("no thanks");
    }
}
