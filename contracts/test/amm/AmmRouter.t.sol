// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";
import {AmmFactory} from "src/amm/AmmFactory.sol";
import {AmmPair} from "src/amm/AmmPair.sol";
import {AmmRouter} from "src/amm/AmmRouter.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {FeeOnTransferToken} from "./Amm.t.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

contract AmmRouterTest is Test {
    AmmFactory internal factory;
    AmmRouter internal router;
    FixedSupplyToken internal tokA;
    FixedSupplyToken internal tokB;
    FixedSupplyToken internal tokC;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal guardian = makeAddr("guardian");

    uint256 internal constant SEED = 1000e18;
    uint256 internal constant MAX = type(uint256).max;

    function setUp() public {
        factory = new AmmFactory(guardian);
        router = new AmmRouter(factory);
        tokA = new FixedSupplyToken("Token A", "TKA", 1_000_000e18, alice);
        tokB = new FixedSupplyToken("Token B", "TKB", 1_000_000e18, alice);
        tokC = new FixedSupplyToken("Token C", "TKC", 1_000_000e18, alice);
    }

    function _approveAll(address who, address spender) internal {
        vm.startPrank(who);
        tokA.approve(spender, MAX);
        tokB.approve(spender, MAX);
        tokC.approve(spender, MAX);
        vm.stopPrank();
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 600;
    }

    function _path2(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        (p[0], p[1]) = (a, b);
    }

    function _path3(address a, address b, address c) internal pure returns (address[] memory p) {
        p = new address[](3);
        (p[0], p[1], p[2]) = (a, b, c);
    }

    /// @dev alice가 (SEED, SEED) 예치 — 페어 자동 생성 포함. 회수를 위해
    ///      LP 토큰도 라우터에 승인해 둔다 (LP는 별도 ERC-20이다).
    function _seedAB() internal returns (uint256 lp) {
        _approveAll(alice, address(router));
        vm.prank(alice);
        (,, lp) = router.addLiquidity(address(tokA), address(tokB), SEED, SEED, 0, 0, alice, _deadline());
        // 주의: vm.prank는 다음 호출 1회만 유효 — 페어 주소를 먼저 읽는다
        AmmPair pair = AmmPair(factory.getPair(address(tokA), address(tokB)));
        vm.prank(alice);
        pair.approve(address(router), MAX);
    }

    // ---- 유동성 ----

    function test_addLiquidity_createsPairAndMints() public {
        uint256 lp = _seedAB();
        assertGt(lp, 0);
        assertEq(factory.allPairsLength(), 1);
        AmmPair pair = AmmPair(factory.getPair(address(tokA), address(tokB)));
        assertEq(pair.balanceOf(alice), SEED - 1000); // 최소 유동성 잠금 제외
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(uint256(r0) + uint256(r1), 2 * SEED);
    }

    function test_addLiquidity_optimalRatio() public {
        _seedAB();
        // 리저브 1:1, desired A=100 B=50.
        // amountBOptimal = 100 > desiredB(50) → amountAOptimal = 50*1000/1000 = 50
        // → 실제 예치는 50:50으로 맞춰진다 (사용자가 가진 B가 바인딩)
        vm.prank(alice);
        (uint256 usedA, uint256 usedB,) =
            router.addLiquidity(address(tokA), address(tokB), 100e18, 50e18, 0, 0, alice, _deadline());
        assertEq(usedA, 50e18);
        assertEq(usedB, 50e18);
    }

    function test_addLiquidity_revertMinSlippage() public {
        _seedAB();
        vm.prank(alice);
        vm.expectRevert(AmmRouter.ExcessiveAmountB.selector);
        router.addLiquidity(address(tokA), address(tokB), 100e18, 50e18, 60e18, 0, alice, _deadline());
        // amountBOptimal(100) > desired(50) → amountAOptimal = 50 < amountAMin(60)
    }

    function test_addLiquidity_revertExpired() public {
        _approveAll(alice, address(router));
        vm.prank(alice);
        vm.expectRevert(AmmRouter.Expired.selector);
        router.addLiquidity(address(tokA), address(tokB), 1e18, 1e18, 0, 0, alice, block.timestamp - 1);
    }

    function test_removeLiquidity_returnsTokens() public {
        uint256 lp = _seedAB();
        uint256 aBefore = tokA.balanceOf(alice);

        vm.prank(alice);
        (uint256 outA, uint256 outB) =
            router.removeLiquidity(address(tokA), address(tokB), lp, 0, 0, alice, _deadline());
        assertEq(outA, SEED - 1000);
        assertEq(outB, SEED - 1000);
        assertEq(tokA.balanceOf(alice) - aBefore, SEED - 1000);
    }

    function test_removeLiquidity_revertMin() public {
        uint256 lp = _seedAB();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AmmRouter.InsufficientOutput.selector, SEED, SEED - 1000));
        router.removeLiquidity(address(tokA), address(tokB), lp, SEED, SEED, alice, _deadline());
    }

    // ---- 스왑 ----

    function test_swap_oneHop() public {
        _seedAB();
        _approveAll(bob, address(router));
        vm.prank(alice);
        tokA.transfer(bob, 10e18);

        uint256[] memory amounts = router.getAmountsOut(10e18, _path2(address(tokA), address(tokB)));
        uint256 bobBefore = tokB.balanceOf(bob);
        vm.prank(bob);
        router.swapExactTokensForTokens(10e18, amounts[1], _path2(address(tokA), address(tokB)), bob, _deadline());
        assertEq(tokB.balanceOf(bob) - bobBefore, amounts[1]);
    }

    function test_swap_twoHops() public {
        _seedAB();
        // B-C 페어: (1000 B : 250 C) — B 1개 = C 0.25개 가격
        vm.prank(alice);
        router.addLiquidity(address(tokB), address(tokC), SEED, SEED / 4, 0, 0, alice, _deadline());
        _approveAll(bob, address(router));
        vm.prank(alice);
        tokA.transfer(bob, 10e18);

        uint256[] memory amounts = router.getAmountsOut(10e18, _path3(address(tokA), address(tokB), address(tokC)));
        assertGt(amounts[1], 9e18); // A→B 1:1 근처
        assertGt(amounts[2], 2e18); // B→C 4:1 — 9.87 B ≈ 2.4 C

        uint256 bobBefore = tokC.balanceOf(bob);
        vm.prank(bob);
        router.swapExactTokensForTokens(
            10e18, amounts[2], _path3(address(tokA), address(tokB), address(tokC)), bob, _deadline()
        );
        assertEq(tokC.balanceOf(bob) - bobBefore, amounts[2]);
        // 중간 홉 토큰(B)은 라우터에 남지 않는다 — 다음 페어로 직송
        assertEq(tokB.balanceOf(address(router)), 0);
    }

    function test_swap_revertInsufficientOutput() public {
        _seedAB();
        _approveAll(bob, address(router));
        vm.prank(alice);
        tokA.transfer(bob, 10e18);

        uint256[] memory amounts = router.getAmountsOut(10e18, _path2(address(tokA), address(tokB)));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AmmRouter.InsufficientOutput.selector, amounts[1] + 1, amounts[1]));
        router.swapExactTokensForTokens(10e18, amounts[1] + 1, _path2(address(tokA), address(tokB)), bob, _deadline());
    }

    function test_swap_revertExpired() public {
        _seedAB();
        _approveAll(bob, address(router));
        vm.prank(bob);
        vm.expectRevert(AmmRouter.Expired.selector);
        router.swapExactTokensForTokens(1e18, 0, _path2(address(tokA), address(tokB)), bob, block.timestamp - 1);
    }

    function test_getAmountsOut_revertInvalidPath() public {
        address[] memory one = new address[](1);
        one[0] = address(tokA);
        vm.expectRevert(AmmRouter.InvalidPath.selector);
        router.getAmountsOut(1e18, one);

        address[] memory five = new address[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = address(tokA);
        }
        vm.expectRevert(AmmRouter.InvalidPath.selector);
        router.getAmountsOut(1e18, five);
    }

    // ---- F-02: FoT 경로 스왑 ----

    function test_fot_swapSupportingFeeOnTransfer() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(alice, 10_000e18);
        vm.startPrank(alice);
        fot.approve(address(router), MAX);
        tokB.approve(address(router), MAX);
        router.addLiquidity(address(fot), address(tokB), 1000e18, 990e18, 0, 0, alice, _deadline());
        vm.stopPrank();

        // 100 송금 → 라우터에 99 → 페어에 98.01 도착 (이중 과징).
        // out은 페어가 관찰한 실제 도착량 기준으로 계산된다.
        AmmPair pair = AmmPair(factory.getPair(address(fot), address(tokB)));
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) =
            address(fot) < address(tokB) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 delivered = 100e18 * 99 / 100 * 99 / 100;
        uint256 expected = router.getAmountOut(delivered, rIn, rOut);

        uint256 before = tokB.balanceOf(alice);
        vm.prank(alice);
        router.swapSupportingFeeOnTransfer(100e18, expected, _path2(address(fot), address(tokB)), alice, _deadline());
        assertEq(tokB.balanceOf(alice) - before, expected);
    }

    function test_fot_addLiquidityUsesDelivered() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(alice, 10_000e18);
        vm.startPrank(alice);
        fot.approve(address(router), MAX);
        tokB.approve(address(router), MAX);
        // 주의: 라우터 경유 FoT는 수수료가 두 번 과징된다
        // (사용자→라우터 1%, 라우터→페어 1%). 1000 요청 → 990 도착 →
        // 980.1 페어 도착. LP/리저브는 실제 도착량 기준 — 좌초는 없다.
        router.addLiquidity(address(fot), address(tokB), 1000e18, 990e18, 0, 0, alice, _deadline());
        vm.stopPrank();

        AmmPair pair = AmmPair(factory.getPair(address(fot), address(tokB)));
        assertEq(fot.balanceOf(address(pair)), 1000e18 * 99 / 100 * 99 / 100);
        assertGt(pair.balanceOf(alice), 0);
    }

    // ---- brake ----

    function test_brake_blocksAddNotRemove() public {
        uint256 lp = _seedAB();
        vm.prank(guardian);
        factory.engageBrake(1);

        // 신규 페어가 필요한 예치 — 팩토리 createPair가 brake에 막힌다
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        router.addLiquidity(address(tokA), address(tokC), 1e18, 1e18, 0, 0, alice, _deadline());

        // 기존 페어 예치도 차단 (페어 mint의 FactoryBrakedNewEntry)
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AmmPair.FactoryBrakedNewEntry.selector, 1));
        router.addLiquidity(address(tokA), address(tokB), 1e18, 1e18, 0, 0, alice, _deadline());

        // 회수는 항상 열려 있다
        vm.prank(alice);
        (uint256 outA,) = router.removeLiquidity(address(tokA), address(tokB), lp, 0, 0, alice, _deadline());
        assertGt(outA, 0);
    }

    // ---- 상태 계량 (examples/amm/GAS.md 원본 데이터) ----

    function test_meter_routerLifecycle() public {
        _approveAll(alice, address(router));

        // 1) 페어 자동 생성 + 첫 예치 (라우터 경유) — 라우터는 무상태라
        //    tracked가 0에 가깝고, 페어 배포·첫 예치분은 2)에서 잡힌다
        address[] memory tracked = new address[](1);
        tracked[0] = address(router);
        StateMeter.Result memory r = StateMeter.measureCall(
            alice,
            tracked,
            address(router),
            abi.encodeCall(router.addLiquidity, (address(tokA), address(tokB), SEED, SEED, 0, 0, alice, _deadline()))
        );
        emit log_named_uint("routerAddLiquidity1 gasUsed (pair deploy included)", r.gasUsed);
        emit log_named_uint("routerAddLiquidity1 stateUnits (router only)", r.stateUnits);

        // 2) 두 번째 예치 (페어 상태만)
        AmmPair pair = AmmPair(factory.getPair(address(tokA), address(tokB)));
        tracked[0] = address(pair);
        StateMeter.Result memory r2 = StateMeter.measureCall(
            alice,
            tracked,
            address(router),
            abi.encodeCall(router.addLiquidity, (address(tokA), address(tokB), 10e18, 10e18, 0, 0, alice, _deadline()))
        );
        emit log_named_uint("routerAddLiquidity2 gasUsed", r2.gasUsed);
        emit log_named_uint("routerAddLiquidity2 newSlots", r2.newSlots);
        emit log_named_uint("routerAddLiquidity2 stateUnits", r2.stateUnits);

        // 3) 라우터 스왑 (1홉)
        _approveAll(bob, address(router));
        vm.prank(alice);
        tokA.transfer(bob, 1e18);
        tracked[0] = address(pair);
        StateMeter.Result memory r3 = StateMeter.measureCall(
            bob,
            tracked,
            address(router),
            abi.encodeCall(
                router.swapExactTokensForTokens, (1e18, 0, _path2(address(tokA), address(tokB)), bob, _deadline())
            )
        );
        emit log_named_uint("routerSwap gasUsed", r3.gasUsed);
        emit log_named_uint("routerSwap newSlots", r3.newSlots);
        emit log_named_uint("routerSwap logBytes", r3.logBytes);
        emit log_named_uint("routerSwap stateUnits", r3.stateUnits);

        // 4) 회수 (LP 승인 후)
        vm.prank(alice);
        pair.approve(address(router), MAX);
        uint256 lp = AmmPair(factory.getPair(address(tokA), address(tokB))).balanceOf(alice);
        StateMeter.Result memory r4 = StateMeter.measureCall(
            alice,
            tracked,
            address(router),
            abi.encodeCall(router.removeLiquidity, (address(tokA), address(tokB), lp, 0, 0, alice, _deadline()))
        );
        emit log_named_uint("routerRemoveLiquidity gasUsed", r4.gasUsed);
        emit log_named_uint("routerRemoveLiquidity newSlots", r4.newSlots);
        emit log_named_uint("routerRemoveLiquidity stateUnits", r4.stateUnits);
    }
}
