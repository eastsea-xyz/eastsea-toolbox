// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentVending} from "src/vending/AgentVending.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 17 — 에이전트 자판기 테스트.
/// @dev fixture: 정가 0.2 ether, 배달 기한 3일. spec/result 는 해시.
contract AgentVendingTest is Test {
    AgentVending internal vend;

    address internal guardian = makeAddr("guardian");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice"); // 주문자

    uint256 internal constant PRICE = 0.2 ether;
    uint48 internal constant WINDOW = 3 days;

    bytes32 internal constant SPEC = keccak256("translate 5 pages to Korean, source ipfs://QmX");
    bytes32 internal constant RESULT = keccak256("ipfs://QmY");

    function setUp() public {
        vend = new AgentVending(guardian, agent, PRICE, WINDOW);
    }

    function _order() internal returns (uint256 id) {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        id = vend.order{value: PRICE}(SPEC);
    }

    // ---------------------------------------------------------------- 주문

    function test_order_recordsCommitment() public {
        vm.expectEmit(true, true, true, true);
        emit AgentVending.Ordered(1, alice, SPEC, uint48(block.timestamp) + WINDOW);
        uint256 id = _order();

        (address buyer, uint48 due) = vend.orders(id);
        assertEq(buyer, alice);
        assertEq(due, uint48(block.timestamp) + WINDOW);
        assertEq(vend.orderCount(), 1);
        assertEq(address(vend).balance, PRICE);
    }

    function test_order_reverts() public {
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentVending.WrongPrice.selector, PRICE + 1, PRICE));
        vend.order{value: PRICE + 1}(SPEC);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentVending.WrongPrice.selector, 0, PRICE));
        vend.order{value: 0}(SPEC);

        // 밖 송금 거부
        (bool ok,) = address(vend).call{value: PRICE}("");
        assertFalse(ok);

        // 생성자
        vm.expectRevert(AgentVending.ZeroPrice.selector);
        new AgentVending(guardian, agent, 0, WINDOW);
        vm.expectRevert(AgentVending.ZeroWindow.selector);
        new AgentVending(guardian, agent, PRICE, 0);
        vm.expectRevert(abi.encodeWithSelector(AgentVending.NotAgent.selector, address(0)));
        new AgentVending(guardian, address(0), PRICE, WINDOW);
    }

    // ---------------------------------------------------------------- 배달

    function test_deliver_settlesWithoutReview() public {
        uint256 id = _order();
        uint256 before = agent.balance;

        vm.expectEmit(true, true, true, true);
        emit AgentVending.Delivered(id, RESULT);
        vm.prank(agent); // 심사 없음 — 등록이 곧 정산
        vend.deliver(id, RESULT);

        assertEq(agent.balance, before + PRICE);
        (address buyer,) = vend.orders(id);
        assertEq(buyer, address(0)); // 완결된 주문은 존재하지 않는다

        // 재배달·환불 모두 불가 — 주문 부재
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVending.UnknownOrder.selector, id));
        vend.deliver(id, RESULT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentVending.UnknownOrder.selector, id));
        vend.refund(id);
    }

    function test_deliver_reverts() public {
        uint256 id = _order();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentVending.NotAgent.selector, alice));
        vend.deliver(id, RESULT);

        // 기한 후 배달 — 기대 데이터는 warp 전 사전 계산 (prank 소비 함정)
        (, uint48 due) = vend.orders(id);
        bytes memory late = abi.encodeWithSelector(AgentVending.DeliveryTooLate.selector, uint256(due) + 1, due);
        vm.warp(uint256(due) + 1);
        vm.prank(agent);
        vm.expectRevert(late);
        vend.deliver(id, RESULT);
    }

    // ---------------------------------------------------------------- 환불

    function test_refund_returnsEverything() public {
        uint256 id = _order();

        // 기한 내 환불 불가 — 아직 배달 창구다 (경계 <=)
        (, uint48 due) = vend.orders(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentVending.StillOpen.selector, block.timestamp, due));
        vend.refund(id);

        vm.warp(uint256(due) + 1);
        vm.expectEmit(true, true, true, true);
        emit AgentVending.Refunded(id);
        vm.prank(alice);
        vend.refund(id);

        assertEq(alice.balance, 1 ether); // 원금 전액 — 자판기는 수수료 없음
        (address buyer,) = vend.orders(id);
        assertEq(buyer, address(0));
        assertEq(address(vend).balance, 0);
    }

    function test_refund_reverts() public {
        uint256 id = _order();
        (, uint48 due) = vend.orders(id);
        vm.warp(uint256(due) + 1);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVending.NotBuyer.selector, agent));
        vend.refund(id);

        vm.prank(alice);
        vend.refund(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgentVending.UnknownOrder.selector, id));
        vend.refund(id); // 이중 환불 — 부재가 답이다
    }

    // ---------------------------------------------------------------- 불변식

    /// @dev n주문 × (배달/환불/방치) — agent 잔액은 정확히 배달수×정가,
    ///      환불자는 원금 회복, 방치분만 슬롯에 남는다.
    function test_fuzz_lifecycle(uint8 seed) public {
        uint256 n = bound(seed, 1, 8);
        uint256 delivered;
        uint256 refunded;
        uint256 stranded; // 방치(미배달·미환불)

        for (uint256 i; i < n; ++i) {
            address buyer = address(uint160(0x4000 + i));
            vm.deal(buyer, 1 ether);
            vm.prank(buyer);
            uint256 id = vend.order{value: PRICE}(keccak256(abi.encode(seed, i)));

            uint8 route = uint8(uint256(keccak256(abi.encode(seed, i, "r"))) % 3);
            if (route == 0) {
                vm.prank(agent);
                vend.deliver(id, RESULT); // 기한 내 배달
                ++delivered;
            } else if (route == 1) {
                (, uint48 due) = vend.orders(id);
                vm.warp(uint256(due) + 1);
                vm.prank(buyer);
                vend.refund(id);
                ++refunded;
                vm.warp(1); // 다음 주문의 due 가 과거가 되지 않게 리셋
            } else {
                ++stranded;
            }
        }

        // I1: 정산은 배달 수와 정확히 비례
        assertEq(agent.balance, delivered * PRICE);

        // I2: 환불자는 전액 회복 — 컨트랙트가 버는 것은 0
        assertEq(address(vend).balance, stranded * PRICE);

        // I3: 방치분만 살아 있다
        uint256 alive;
        for (uint256 i = 1; i <= n; ++i) {
            (address buyer,) = vend.orders(i);
            if (buyer != address(0)) ++alive;
        }
        assertEq(alive, stranded);
    }

    // ---------------------------------------------------------------- brake

    function test_brake_blocksOrderNotExits() public {
        uint256 id = _order();
        vm.prank(guardian);
        vend.engageBrake(1);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        vend.order{value: PRICE}(SPEC);

        // 진행 중 주문의 배달·환불은 열려 있다
        vm.prank(agent);
        vend.deliver(id, RESULT);
        assertEq(agent.balance, PRICE);
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/vending/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r) = StateMeter.measureDeploy(
            abi.encodePacked(type(AgentVending).creationCode, abi.encode(guardian, agent, PRICE, WINDOW))
        );
        emit log_named_uint("vendDeploy gasUsed", r.gasUsed);
        emit log_named_uint("vendDeploy codeBytes", r.codeBytes);
        emit log_named_uint("vendDeploy stateUnits", r.stateUnits);
    }

    function test_meter_lifecycle() public {
        address[] memory tracked = new address[](1);
        tracked[0] = address(vend);

        vm.deal(alice, 2 ether);
        StateMeter.Result memory r1 =
            StateMeter.measureCallValue(alice, tracked, address(vend), abi.encodeCall(vend.order, (SPEC)), PRICE);
        emit log_named_uint("orderFirst gasUsed", r1.gasUsed);
        emit log_named_uint("orderFirst newSlots", r1.newSlots);
        emit log_named_uint("orderFirst logBytes", r1.logBytes);
        emit log_named_uint("orderFirst stateUnits", r1.stateUnits);

        address bob = makeAddr("bob");
        vm.deal(bob, 1 ether);
        StateMeter.Result memory r2 =
            StateMeter.measureCallValue(bob, tracked, address(vend), abi.encodeCall(vend.order, (SPEC)), PRICE);
        emit log_named_uint("orderSecond gasUsed", r2.gasUsed);
        emit log_named_uint("orderSecond newSlots", r2.newSlots);
        emit log_named_uint("orderSecond stateUnits", r2.stateUnits);

        StateMeter.Result memory r3 =
            StateMeter.measureCall(agent, tracked, address(vend), abi.encodeCall(vend.deliver, (1, RESULT)));
        emit log_named_uint("deliver gasUsed", r3.gasUsed);
        emit log_named_uint("deliver newSlots", r3.newSlots);
        emit log_named_uint("deliver logBytes", r3.logBytes);
        emit log_named_uint("deliver stateUnits", r3.stateUnits);

        (, uint48 due) = vend.orders(2);
        vm.warp(uint256(due) + 1);
        StateMeter.Result memory r4 =
            StateMeter.measureCall(bob, tracked, address(vend), abi.encodeCall(vend.refund, (2)));
        emit log_named_uint("refund gasUsed", r4.gasUsed);
        emit log_named_uint("refund newSlots", r4.newSlots);
        emit log_named_uint("refund stateUnits", r4.stateUnits);
    }
}
