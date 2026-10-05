// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";
import {BondingLaunchpad} from "src/launchpad/BondingLaunchpad.sol";
import {AmmFactory} from "src/amm/AmmFactory.sol";
import {AmmPair} from "src/amm/AmmPair.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {FeeOnTransferToken} from "test/amm/Amm.t.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 5 — 본딩 커브 런치패드 테스트.
/// @dev fixture 수치:
///      supply 1M, floors 100/100, target 1_000 quote, fee 1%,
///      snipe 20%/3600s, cap 없음(기본) — cap 전용 테스트만 별도 배포.
contract BondingLaunchpadTest is Test {
    AmmFactory internal factory;
    FixedSupplyToken internal quote;
    BondingLaunchpad internal launchpad;

    address internal alice = makeAddr("alice");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");

    uint256 internal constant SUPPLY = 1_000_000e18;
    uint256 internal constant QFLOOR = 100e18;
    uint256 internal constant TFLOOR = 100e18;
    uint256 internal constant TARGET = 1_000e18;
    uint256 internal constant FEE_BPS = 100; // 1%
    uint256 internal constant SNIPE_BPS = 2000; // 20%
    uint256 internal constant WINDOW = 3600;
    uint256 internal constant BPS_MAX = 10_000;

    function setUp() public {
        factory = new AmmFactory(guardian);
        quote = new FixedSupplyToken("Quote", "QTE", 10_000_000e18, alice);
        launchpad = new BondingLaunchpad(guardian, quote, factory, _cfg());
        // 기본 시나리오는 스나이프 세금 소멸 후(t >= window) — 세금 자체는
        // 전용 테스트에서 자체 배포한 커브로 검증한다.
        vm.warp(launchpad.launchTime() + WINDOW);
    }

    function _cfg() internal view returns (BondingLaunchpad.Config memory) {
        return BondingLaunchpad.Config({
            name: "Curve Coin",
            symbol: "CRV",
            tokenSupply: SUPPLY,
            quoteFloor: QFLOOR,
            tokenFloor: TFLOOR,
            graduationTarget: TARGET,
            feeBps: FEE_BPS,
            snipeTaxBps: SNIPE_BPS,
            snipeWindow: WINDOW,
            perBuyerCap: 0, // 기본 fixture는 제한 없음
            treasury: treasury
        });
    }

    /// @dev 커브 수학 독립 재구현 — 컨트랙트 뷰와 같은 식을 테스트 쪽에서
    ///      따로 계산해 순환 검증을 피한다. 스나이프 세금 0 가정.
    function _expectedBuyOut(uint256 quoteIn) internal view returns (uint256 out, uint256 fee, uint256 netIn) {
        fee = quoteIn * FEE_BPS / BPS_MAX;
        netIn = quoteIn - fee;
        uint256 vq = quote.balanceOf(address(launchpad)) + QFLOOR;
        uint256 vt = launchpad.curveToken().balanceOf(address(launchpad)) + TFLOOR;
        out = vt * netIn / (vq + netIn);
    }

    function _expectedSellOut(uint256 tokenIn) internal view returns (uint256 received, uint256 fee) {
        uint256 vq = quote.balanceOf(address(launchpad)) + QFLOOR;
        uint256 vt = launchpad.curveToken().balanceOf(address(launchpad)) + TFLOOR;
        uint256 out = vq * tokenIn / (vt + tokenIn);
        fee = out * FEE_BPS / BPS_MAX;
        received = out - fee;
    }

    function _buyAs(address who, uint256 quoteIn) internal returns (uint256 got) {
        uint256 before = launchpad.curveToken().balanceOf(who);
        vm.startPrank(who);
        quote.approve(address(launchpad), quoteIn);
        launchpad.buy(quoteIn, 0);
        vm.stopPrank();
        got = launchpad.curveToken().balanceOf(who) - before;
    }

    function _sellAs(address who, uint256 tokenIn) internal returns (uint256 got) {
        uint256 before = quote.balanceOf(who);
        vm.startPrank(who);
        launchpad.curveToken().approve(address(launchpad), tokenIn);
        launchpad.sell(tokenIn, 0);
        vm.stopPrank();
        got = quote.balanceOf(who) - before;
    }

    /// @dev buyer 2명이 각 600 quote 매수 — raised = 2 x 594 = 1_188 >= 1_000.
    ///      (3명이면 세 번째 매수가 TargetReached로 죽는다 — 2명이 목표를 넘긴다.)
    function _reachTarget() internal returns (address b1, address b2) {
        b1 = makeAddr("buyer1");
        b2 = makeAddr("buyer2");
        address[2] memory buyers = [b1, b2];
        for (uint256 i; i < 2; ++i) {
            vm.prank(alice);
            quote.transfer(buyers[i], 600e18);
            _buyAs(buyers[i], 600e18);
        }
    }

    // ---------------------------------------------------------------- 설정

    function test_setup_curveHoldsAllTokens() public {
        assertEq(launchpad.curveToken().balanceOf(address(launchpad)), SUPPLY);
        assertEq(launchpad.curveToken().totalSupply(), SUPPLY);
        (uint256 vq, uint256 vt) = launchpad.virtualReserves();
        assertEq(vq, QFLOOR);
        assertEq(vt, SUPPLY + TFLOOR);
    }

    function test_setup_revertInvalidConfig() public {
        BondingLaunchpad.Config memory cfg = _cfg();
        cfg.feeBps = 9_000; // fee + snipe = 11_000 > 10_000
        vm.expectRevert(BondingLaunchpad.InvalidConfig.selector);
        new BondingLaunchpad(guardian, quote, factory, cfg);

        cfg = _cfg();
        cfg.treasury = address(0);
        vm.expectRevert(BondingLaunchpad.InvalidConfig.selector);
        new BondingLaunchpad(guardian, quote, factory, cfg);

        cfg = _cfg();
        cfg.tokenSupply = 0;
        vm.expectRevert(BondingLaunchpad.InvalidConfig.selector);
        new BondingLaunchpad(guardian, quote, factory, cfg);

        cfg = _cfg();
        cfg.snipeWindow = 0; // snipeTaxBps > 0 인데 window 0
        vm.expectRevert(BondingLaunchpad.InvalidConfig.selector);
        new BondingLaunchpad(guardian, quote, factory, cfg);

        // F-03: 무코드 quote / 무코드 팩토리
        vm.expectRevert(BondingLaunchpad.InvalidConfig.selector);
        new BondingLaunchpad(guardian, IERC20(address(0xBEEF)), factory, _cfg());
        vm.expectRevert(BondingLaunchpad.InvalidConfig.selector);
        new BondingLaunchpad(guardian, quote, AmmFactory(address(0xBEEF)), _cfg());
    }

    // ---------------------------------------------------------------- 매수

    function test_buy_matchesCurveMath() public {
        (uint256 out, uint256 fee,) = _expectedBuyOut(1_000e18);
        uint256 got = _buyAs(alice, 1_000e18);
        assertEq(got, out);
        // fee 1%만 treasury로 (스나이프 소멸 후)
        assertEq(quote.balanceOf(treasury), fee);
        assertEq(quote.balanceOf(address(launchpad)), 990e18);
    }

    function test_buy_viewMatchesExecution() public {
        uint256 quoted = launchpad.getBuyQuoteOut(500e18);
        uint256 got = _buyAs(alice, 500e18);
        assertEq(quoted, got);
    }

    function test_buy_snipeTaxDecays() public {
        // 자체 배포: launch 직후 세금 최대 → 절반 → 0
        BondingLaunchpad fresh = new BondingLaunchpad(guardian, quote, factory, _cfg());
        vm.prank(alice);
        quote.approve(address(fresh), type(uint256).max);

        uint256 t0 = quote.balanceOf(treasury);
        vm.prank(alice);
        fresh.buy(100e18, 0); // fee 1 + tax 20
        assertEq(quote.balanceOf(treasury) - t0, 21e18);

        vm.warp(fresh.launchTime() + WINDOW / 2);
        vm.prank(alice);
        fresh.buy(100e18, 0); // fee 1 + tax 10
        assertEq(quote.balanceOf(treasury) - t0, 32e18);

        vm.warp(fresh.launchTime() + WINDOW);
        vm.prank(alice);
        fresh.buy(100e18, 0); // fee 1 + tax 0
        assertEq(quote.balanceOf(treasury) - t0, 33e18);
    }

    function test_buy_revertMinOut() public {
        (uint256 out,,) = _expectedBuyOut(1_000e18);
        vm.startPrank(alice);
        quote.approve(address(launchpad), 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(BondingLaunchpad.InsufficientOutput.selector, out + 1, out));
        launchpad.buy(1_000e18, out + 1);
        vm.stopPrank();
    }

    function test_buy_revertZeroInput() public {
        vm.prank(alice);
        vm.expectRevert(BondingLaunchpad.InsufficientInput.selector);
        launchpad.buy(0, 0);
    }

    function test_buy_revertCap() public {
        // 별도 배포: 개인 보유 상한 50_000e18 (공급의 5%)
        BondingLaunchpad.Config memory cfg = _cfg();
        cfg.perBuyerCap = 50_000e18;
        BondingLaunchpad capped = new BondingLaunchpad(guardian, quote, factory, cfg);
        vm.warp(capped.launchTime() + WINDOW);

        vm.startPrank(alice);
        quote.approve(address(capped), type(uint256).max);
        // 유효 5e18: out ~= 1_000_100 * 4.95 / 104.95 ~= 47_175 < 50_000 — 통과
        capped.buy(5e18 + 5e16, 0); // delivered 5.05, netIn 5.0 (fee 1%)
        vm.stopPrank();

        uint256 held = capped.curveToken().balanceOf(alice);
        assertGt(held, 40_000e18);
        // 추가 매수로 한도 초과 — 견적으로 wouldHold를 정확히 예측해 인코딩
        uint256 moreOut = capped.getBuyQuoteOut(1e18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondingLaunchpad.ExcessivePurchase.selector, held + moreOut, 50_000e18));
        capped.buy(1e18, 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 매도

    function test_sell_matchesCurveMath() public {
        uint256 bought = _buyAs(alice, 1_000e18);
        (uint256 received, uint256 fee) = _expectedSellOut(bought);
        uint256 treasuryBefore = quote.balanceOf(treasury);

        uint256 got = _sellAs(alice, bought);
        assertEq(got, received);
        assertEq(quote.balanceOf(treasury) - treasuryBefore, fee);
    }

    function test_sell_revertMinOut() public {
        uint256 bought = _buyAs(alice, 1_000e18);
        (uint256 received,) = _expectedSellOut(bought);
        vm.startPrank(alice);
        launchpad.curveToken().approve(address(launchpad), bought);
        vm.expectRevert(abi.encodeWithSelector(BondingLaunchpad.InsufficientOutput.selector, received + 1, received));
        launchpad.sell(bought, received + 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 불변식 fuzz

    /// @dev 즉시 왕복 매매는 항상 손해다 — fee 2회 + 커브 스프레드.
    ///      round-trip 차익이 생기면 커브 수학이 깨진 것이다.
    function test_fuzz_roundTripNeverProfits(uint256 q) public {
        q = bound(q, 1e16, 900e18);
        uint256 bought = _buyAs(alice, q);
        uint256 received = _sellAs(alice, bought);
        assertLt(received, q);
    }

    /// @dev 유효 리저브 곱 vq*vt는 매매로 줄지 않는다 (fee는 커브 밖).
    function test_fuzz_virtualKNeverDecreases(uint256 q) public {
        q = bound(q, 1e16, 900e18);
        (uint256 vq0, uint256 vt0) = launchpad.virtualReserves();
        uint256 k0 = vq0 * vt0;

        uint256 bought = _buyAs(alice, q);
        (uint256 vq1, uint256 vt1) = launchpad.virtualReserves();
        assertGe(vq1 * vt1, k0);

        _sellAs(alice, bought);
        (uint256 vq2, uint256 vt2) = launchpad.virtualReserves();
        assertGe(vq2 * vt2, vq1 * vt1);
    }

    // ---------------------------------------------------------------- F-02: FoT quote

    function test_fot_quoteMeasuredByDelivery() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(alice, 100_000e18);
        BondingLaunchpad.Config memory cfg = _cfg();
        BondingLaunchpad fotPad = new BondingLaunchpad(guardian, IERC20(address(fot)), factory, cfg);
        vm.warp(fotPad.launchTime() + WINDOW);

        // 1_000 송금 -> 990 도착. fee/tax/가격 전부 도착량 기준.
        vm.startPrank(alice);
        fot.approve(address(fotPad), 1_000e18);
        fotPad.buy(1_000e18, 0);
        vm.stopPrank();

        uint256 delivered = 990e18;
        uint256 fee = delivered * FEE_BPS / BPS_MAX;
        uint256 netIn = delivered - fee;
        // 유입 전 커브 quote 잔액은 0 — vq = 0 + QFLOOR
        uint256 expected = (SUPPLY + TFLOOR) * netIn / (QFLOOR + netIn);
        assertEq(fotPad.curveToken().balanceOf(alice), expected);
        // treasury도 FoT를 받으므로 push 시 1% 재과징: 9.9 송금 -> 9.801 도착.
        // 커브에 남은 차액은 balance 기반 리저브에 자연 편입된다 (좌초 없음).
        assertEq(fot.balanceOf(treasury), fee * 99 / 100);
    }

    // ---------------------------------------------------------------- 졸업

    function test_graduate_seedsPairAndLocksLp() public {
        _reachTarget();
        uint256 raised = quote.balanceOf(address(launchpad));
        uint256 remaining = launchpad.curveToken().balanceOf(address(launchpad));

        launchpad.graduate();
        address pair = launchpad.graduatePair();
        assertEq(pair, factory.getPair(address(launchpad.curveToken()), address(quote)));

        AmmPair p = AmmPair(pair);
        assertTrue(p.balanceOf(0x000000000000000000000000000000000000dEaD) > 0);
        // 커브는 청산 — 남은 자산 없음
        assertEq(quote.balanceOf(address(launchpad)), 0);
        assertEq(launchpad.curveToken().balanceOf(address(launchpad)), 0);
        (uint112 r0, uint112 r1,) = p.getReserves();
        // 페어 예치분 = 졸업 시점 커브 잔액 전액 (주소 정렬 무관 합산)
        assertEq(uint256(r0) + uint256(r1), raised + remaining);
    }

    function test_graduate_thenTradesClosed() public {
        _reachTarget();
        launchpad.graduate();

        vm.prank(alice);
        quote.approve(address(launchpad), 1e18);
        vm.prank(alice);
        vm.expectRevert(BondingLaunchpad.Closed.selector);
        launchpad.buy(1e18, 0);

        vm.prank(alice);
        vm.expectRevert(BondingLaunchpad.Closed.selector);
        launchpad.sell(1e18, 0);
    }

    function test_graduate_revertNotGraduable() public {
        vm.expectRevert(abi.encodeWithSelector(BondingLaunchpad.NotGraduable.selector, 0, TARGET));
        launchpad.graduate();
    }

    function test_graduate_revertTwice() public {
        _reachTarget();
        launchpad.graduate();
        vm.expectRevert(BondingLaunchpad.AlreadyGraduated.selector);
        launchpad.graduate();
    }

    function test_buy_revertTargetReached() public {
        _reachTarget();
        vm.prank(alice);
        quote.approve(address(launchpad), 1e18);
        vm.prank(alice);
        vm.expectRevert(BondingLaunchpad.TargetReached.selector);
        launchpad.buy(1e18, 0);
    }

    /// @dev 목표 도달 후에도 매도는 열려 있다 — 매도로 raised가 목표 밑으로
    ///      내려가면 매수가 다시 열린다 (커브는 계속 유효).
    function test_sellReopensBuying() public {
        (address b1,) = _reachTarget();
        vm.prank(alice);
        quote.approve(address(launchpad), 1e18);
        vm.prank(alice);
        vm.expectRevert(BondingLaunchpad.TargetReached.selector);
        launchpad.buy(1e18, 0);

        _sellAs(b1, launchpad.curveToken().balanceOf(b1)); // 1차 매수자 전량 회수

        vm.prank(alice);
        launchpad.buy(1e18, 0); // 재개
    }

    /// @dev 졸업한 토큰은 예제 4 AMM에서 정상 스왑된다.
    function test_graduatedTokenSwapsOnAmm() public {
        (, address b2) = _reachTarget();
        launchpad.graduate();
        AmmPair pair = AmmPair(launchpad.graduatePair());

        vm.prank(alice);
        quote.transfer(b2, 100e18);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool quoteIsToken0 = address(pair.token0()) == address(quote);
        uint256 rQ = quoteIsToken0 ? r0 : r1;
        uint256 rT = quoteIsToken0 ? r1 : r0;
        uint256 inWithFee = 100e18 * 997;
        uint256 outT = rT * inWithFee / (rQ * 1000 + inWithFee);

        uint256 before = launchpad.curveToken().balanceOf(b2);
        vm.startPrank(b2);
        quote.transfer(address(pair), 100e18);
        if (quoteIsToken0) {
            pair.swap(0, outT, b2);
        } else {
            pair.swap(outT, 0, b2);
        }
        vm.stopPrank();
        assertEq(launchpad.curveToken().balanceOf(b2) - before, outT);
    }

    /// @dev 선점 공격 1: 예치 없는 빈 페어 선생성 — 재사용된다 (LP dead 잠금).
    function test_graduate_reusesPrecreatedEmptyPair() public {
        _reachTarget();
        address pre = factory.createPair(address(launchpad.curveToken()), address(quote));

        launchpad.graduate();
        assertEq(launchpad.graduatePair(), pre);
        AmmPair p = AmmPair(pre);
        assertTrue(p.balanceOf(0x000000000000000000000000000000000000dEaD) > 0);
    }

    /// @dev 선점 공격 2: 소량 예치로 LP를 만들어 둔 페어 — 거부 (유동성 절도 방지).
    function test_graduate_revertPairPoisoned() public {
        address pre = factory.createPair(address(launchpad.curveToken()), address(quote));
        // 공격자 물량: 커브에서 소량 매수해 페어에 선예치(AmmPair.mint은
        // balance-delta 방식 — 미리 전송해두고 mint 호출)
        uint256 got = _buyAs(alice, 50e18);
        vm.startPrank(alice);
        quote.transfer(pre, 10e18);
        launchpad.curveToken().transfer(pre, got);
        AmmPair(pre).mint(alice);
        vm.stopPrank();
        assertGt(AmmPair(pre).totalSupply(), 1000);

        _reachTarget();
        vm.expectRevert(abi.encodeWithSelector(BondingLaunchpad.PairPoisoned.selector, pre));
        launchpad.graduate();
    }

    // ---------------------------------------------------------------- brake

    function test_brake_blocksEntryNotExit() public {
        uint256 bought = _buyAs(alice, 100e18);
        vm.prank(guardian);
        launchpad.engageBrake(1);

        vm.prank(alice);
        quote.approve(address(launchpad), 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        launchpad.buy(1e18, 0);

        // 매도(탈출)는 brake와 무관하게 열려 있다
        uint256 got = _sellAs(alice, bought);
        assertGt(got, 0);
    }

    function test_brake_blocksGraduation() public {
        _reachTarget();
        vm.prank(guardian);
        launchpad.engageBrake(1);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        launchpad.graduate();
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/launchpad/GAS.md 원본)

    function test_meter_deploy() public {
        BondingLaunchpad.Config memory cfg = _cfg();
        (, StateMeter.Result memory r) = StateMeter.measureDeploy(
            abi.encodePacked(
                type(BondingLaunchpad).creationCode, abi.encode(guardian, address(quote), address(factory), cfg)
            )
        );
        emit log_named_uint("launchpadDeploy gasUsed", r.gasUsed);
        emit log_named_uint("launchpadDeploy codeBytes", r.codeBytes);
        emit log_named_uint("launchpadDeploy stateUnits", r.stateUnits);
        // 주의: 커브 토큰(FixedSupplyToken)은 생성자 내부 배포라 여기에
        // 포함되지 않는다 — 예제 1 GAS.md의 토큰 배포 비용을 더할 것.
    }

    function test_meter_buySell() public {
        vm.startPrank(alice);
        quote.approve(address(launchpad), type(uint256).max);
        vm.stopPrank();
        // 주의: getter(launchpad.curveToken())가 external call이라 vm.prank를
        // 소진한다 — 주소를 먼저 읽는다 (AMM 테스트와 같은 함정).
        FixedSupplyToken tok = launchpad.curveToken();

        address[] memory tracked = new address[](1);
        tracked[0] = address(launchpad);
        StateMeter.Result memory r =
            StateMeter.measureCall(alice, tracked, address(launchpad), abi.encodeCall(launchpad.buy, (1_000e18, 0)));
        emit log_named_uint("buy gasUsed", r.gasUsed);
        emit log_named_uint("buy newSlots", r.newSlots);
        emit log_named_uint("buy logBytes", r.logBytes);
        emit log_named_uint("buy stateUnits", r.stateUnits);

        // 매도는 커브 토큰 pull — 승인이 필요하다
        vm.prank(alice);
        tok.approve(address(launchpad), type(uint256).max);

        StateMeter.Result memory r2 = StateMeter.measureCall(
            alice, tracked, address(launchpad), abi.encodeCall(launchpad.sell, (tok.balanceOf(alice), 0))
        );
        emit log_named_uint("sell gasUsed", r2.gasUsed);
        emit log_named_uint("sell newSlots", r2.newSlots);
        emit log_named_uint("sell logBytes", r2.logBytes);
        emit log_named_uint("sell stateUnits", r2.stateUnits);
    }

    function test_meter_graduate() public {
        _reachTarget();
        address[] memory tracked = new address[](1);
        tracked[0] = address(launchpad);
        StateMeter.Result memory r =
            StateMeter.measureCall(alice, tracked, address(launchpad), abi.encodeCall(launchpad.graduate, ()));
        emit log_named_uint("graduate gasUsed", r.gasUsed);
        emit log_named_uint("graduate newSlots", r.newSlots);
        emit log_named_uint("graduate logBytes", r.logBytes);
        emit log_named_uint("graduate stateUnits (launchpad slots only)", r.stateUnits);
        // 페어 배포(약 8,196u)와 토큰 측 잔액 슬롯은 tracked 밖 — AMM 예제 참조.
    }
}
