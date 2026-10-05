// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";
import {AmmFactory} from "src/amm/AmmFactory.sol";
import {AmmPair} from "src/amm/AmmPair.sol";
import {AmmRouter} from "src/amm/AmmRouter.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice F-02 목업: 이체 시 1%를 과징하는 fee-on-transfer 토큰.
contract FeeOnTransferToken is ERC20 {
    address public constant FEE_SINK = address(0xBEEF);

    constructor() ERC20("Fee on Transfer", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = from == address(0) ? 0 : value / 100;
        super._update(from, to, value - fee);
        if (fee > 0) super._update(from, FEE_SINK, fee);
    }
}

contract AmmPoolTest is Test {
    AmmFactory internal factory;
    FixedSupplyToken internal tokA;
    FixedSupplyToken internal tokB;
    AmmPair internal pair;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal guardian = makeAddr("guardian");

    uint256 internal constant SEED = 1000e18;

    function setUp() public {
        factory = new AmmFactory(guardian);
        tokA = new FixedSupplyToken("Token A", "TKA", 1_000_000e18, alice);
        tokB = new FixedSupplyToken("Token B", "TKB", 1_000_000e18, alice);
        pair = AmmPair(factory.createPair(address(tokA), address(tokB)));
    }

    /// @dev 페어의 (tokenA측, tokenB측) 리저브 — 주소 정렬과 무관하게.
    function _reservesAB() internal view returns (uint256 rA, uint256 rB) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rA, rB) = address(tokA) < address(tokB) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _quote(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 inWithFee = amountIn * 997;
        return (inWithFee * reserveOut) / (reserveIn * 1000 + inWithFee);
    }

    /// @dev alice가 (a, b)를 예치해 초기 유동성을 만든다.
    function _seed(uint256 a, uint256 b) internal returns (uint256 lp) {
        vm.startPrank(alice);
        tokA.transfer(address(pair), a);
        tokB.transfer(address(pair), b);
        lp = pair.mint(alice);
        vm.stopPrank();
    }

    // ---- 팩토리 ----

    function test_factory_createsPairSorted() public {
        assertEq(factory.allPairsLength(), 1);
        assertEq(factory.getPair(address(tokA), address(tokB)), address(pair));
        assertEq(factory.getPair(address(tokB), address(tokA)), address(pair));
        assertEq(address(pair.token0()), address(tokA) < address(tokB) ? address(tokA) : address(tokB));
        assertEq(address(pair.factory()), address(factory));
    }

    function test_factory_revertIdentical() public {
        vm.expectRevert(abi.encodeWithSelector(AmmFactory.IdenticalTokens.selector, address(tokA)));
        factory.createPair(address(tokA), address(tokA));
    }

    function test_factory_revertZeroAddress() public {
        vm.expectRevert(AmmFactory.ZeroTokenAddress.selector);
        factory.createPair(address(0), address(tokB));
    }

    function test_factory_revertNoCode() public {
        address eoa = makeAddr("not-a-token");
        vm.expectRevert(abi.encodeWithSelector(AmmFactory.TokenHasNoCode.selector, eoa));
        factory.createPair(address(tokB), eoa); // 정렬 후 eoa가 token1이어도 검사된다
    }

    function test_factory_revertExists() public {
        vm.expectRevert(abi.encodeWithSelector(AmmFactory.PairExists.selector, address(pair)));
        factory.createPair(address(tokA), address(tokB));
    }

    // ---- 예치(mint) ----

    function test_mint_firstLiquidityLocksMinimum() public {
        uint256 lp = _seed(SEED, SEED);
        // sqrt(1000e18 * 1000e18) = 1000e18, 최소 유동성 1000 차감
        assertEq(lp, SEED - 1000);
        assertEq(pair.balanceOf(alice), SEED - 1000);
        assertEq(pair.balanceOf(address(0x000000000000000000000000000000000000dEaD)), 1000); // 영구 잠김
        (uint256 rA, uint256 rB) = _reservesAB();
        assertEq(rA, SEED);
        assertEq(rB, SEED);
    }

    function test_mint_proportionalSecondDeposit() public {
        _seed(SEED, SEED);
        uint256 lp2 = _seed(SEED / 10, SEED / 10);
        // totalSupply가 이미 SEED(잠금분 포함)이므로 두 번째 LP는 정확히 비례
        assertEq(lp2, SEED / 10);
        (uint256 rA, uint256 rB) = _reservesAB();
        assertEq(rA, SEED + SEED / 10);
        assertEq(rB, SEED + SEED / 10);
    }

    function test_mint_revertNothingDeposited() public {
        vm.expectRevert(AmmPair.InsufficientLiquidityMinted.selector);
        pair.mint(alice);
    }

    // ---- 회수(burn) ----

    function test_burn_proportional() public {
        uint256 lp = _seed(SEED, SEED);
        vm.startPrank(alice);
        pair.transfer(address(pair), lp);
        (uint256 outA, uint256 outB) = pair.burn(alice);
        vm.stopPrank();

        assertEq(outA, SEED - 1000); // 잠긴 최소 유동성 비례분이 남는다
        assertEq(outB, SEED - 1000);
        assertEq(tokA.balanceOf(alice), 1_000_000e18 - 1000);
        assertEq(pair.totalSupply(), 1000); // dead 잠금분만 영구 잔류
    }

    // ---- 스왑 ----

    function test_swap_executesWithFee() public {
        _seed(SEED, SEED);
        uint256 amountIn = 10e18;
        uint256 expectedOut = _quote(amountIn, SEED, SEED);

        vm.prank(alice);
        tokA.transfer(bob, amountIn); // bob에게 스왑 자금 지급
        vm.prank(bob);
        tokA.transfer(address(pair), amountIn);

        uint256 bobBefore = tokB.balanceOf(bob);
        pair.swap(0, expectedOut, bob);
        assertEq(tokB.balanceOf(bob) - bobBefore, expectedOut);

        (uint256 rA, uint256 rB) = _reservesAB();
        assertEq(rA, SEED + amountIn);
        assertEq(rB, SEED - expectedOut);
    }

    function test_swap_revertExcessiveOutput() public {
        _seed(SEED, SEED);
        vm.prank(alice);
        tokA.transfer(address(pair), 10e18);
        uint256 fair = _quote(10e18, SEED, SEED);
        uint256 greedy = fair + (fair / 100) + 1; // 1% 초과 — floor 여유 밖
        vm.expectRevert(AmmPair.ExcessiveOutput.selector);
        pair.swap(0, greedy, bob);
    }

    function test_swap_revertInsufficientLiquidity() public {
        _seed(SEED, SEED);
        vm.expectRevert(AmmPair.InsufficientLiquidity.selector);
        pair.swap(0, SEED, bob); // out >= reserve
    }

    function test_swap_revertInvalidAmounts() public {
        vm.expectRevert(AmmPair.InvalidSwapAmounts.selector);
        pair.swap(0, 0, bob);
    }

    function test_swap_revertNoInput() public {
        _seed(SEED, SEED);
        vm.expectRevert(AmmPair.InsufficientOutput.selector);
        pair.swap(0, 1, bob); // out을 받았지만 유입이 없다
    }

    // ---- F-02: fee-on-transfer ----

    function test_fot_mintUsesDeliveredAmount() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        FixedSupplyToken other = new FixedSupplyToken("Other", "OTH", 1_000_000e18, alice);
        fot.mint(alice, 1000e18);
        AmmPair fotPair = AmmPair(factory.createPair(address(fot), address(other)));

        vm.startPrank(alice);
        fot.transfer(address(fotPair), 1000e18); // 990e18 도착
        other.transfer(address(fotPair), 990e18);
        uint256 lp = fotPair.mint(alice);
        vm.stopPrank();

        // LP와 리저브는 실제 도착량(990) 기준 — 좌초 없음
        assertApproxEqAbs(lp, 990e18, 1001); // sqrt(990e18*990e18) - 1000
        (uint112 r0, uint112 r1,) = fotPair.getReserves();
        assertEq(address(fot) == address(fotPair.token0()) ? uint256(r0) : uint256(r1), 990e18);
        assertEq(address(other) == address(fotPair.token0()) ? uint256(r0) : uint256(r1), 990e18);
    }

    function test_fot_swapUsesDeliveredInput() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        FixedSupplyToken other = new FixedSupplyToken("Other", "OTH", 1_000_000e18, alice);
        fot.mint(alice, 10_000e18);
        AmmPair fotPair = AmmPair(factory.createPair(address(fot), address(other)));

        vm.startPrank(alice);
        fot.transfer(address(fotPair), 1000e18); // 990 도착
        other.transfer(address(fotPair), 990e18);
        fotPair.mint(alice);
        vm.stopPrank();

        // 스왑: fot 1000 송금 → 990 도착 → out은 990 기준 견적과 정확히 일치
        vm.prank(alice);
        fot.transfer(address(fotPair), 100e18); // 99 도착
        (uint112 r0, uint112 r1,) = fotPair.getReserves();
        (uint256 rFot, uint256 rOther) =
            address(fot) == address(fotPair.token0()) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 expectedOut = _quote(99e18, rFot, rOther);
        uint256 before = other.balanceOf(alice);
        (uint256 out0, uint256 out1) =
            address(fot) == address(fotPair.token0()) ? (uint256(0), expectedOut) : (expectedOut, uint256(0));
        fotPair.swap(out0, out1, alice);
        assertEq(other.balanceOf(alice) - before, expectedOut);
    }

    // ---- TWAP ----

    function test_twap_accumulates() public {
        _seed(SEED, SEED);
        uint256 p0Before = pair.price0CumulativeLast();

        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        pair.sync(); // _update 트리거 (timeElapsed = 100)

        uint256 p0After = pair.price0CumulativeLast();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 price0 = uint256(r1) * 1e18 / r0;
        assertApproxEqAbs(p0After - p0Before, price0 * 100, 1); // 적분 오차 1
    }

    // ---- 잔여 회수·재동기화 ----

    function test_skim_recoversExcess() public {
        _seed(SEED, SEED);
        vm.prank(alice);
        tokA.transfer(address(pair), 5e18); // 우연 입금

        uint256 before = tokA.balanceOf(bob);
        pair.skim(bob);
        assertEq(tokA.balanceOf(bob) - before, 5e18);
    }

    function test_sync_resetsReserves() public {
        _seed(SEED, SEED);
        vm.prank(alice);
        tokA.transfer(address(pair), 5e18); // 잔여 — 리저브와 불일치
        pair.sync();
        (uint256 rA,) = _reservesAB();
        assertEq(rA, SEED + 5e18);
    }

    // ---- k 불변식 (fuzz) ----

    function test_fuzz_swapPreservesK(uint96 amountIn) public {
        vm.assume(amountIn >= 1e6 && amountIn <= 100e18);
        _seed(SEED, SEED);
        (uint256 rIn, uint256 rOut) = _reservesAB();
        uint256 kBefore = rIn * rOut;
        uint256 out = _quote(amountIn, rIn, rOut);

        vm.prank(alice);
        tokA.transfer(address(pair), amountIn);
        pair.swap(0, out, bob);

        (uint256 rA2, uint256 rB2) = _reservesAB();
        assertGe(rA2 * rB2, kBefore, "k must not decrease");
    }

    // ---- brake ----

    function test_brake_blocksEntryNotExit() public {
        uint256 lp = _seed(SEED, SEED);
        vm.prank(guardian);
        factory.engageBrake(1);

        // 신규 진입: 예치 차단
        vm.startPrank(alice);
        tokA.transfer(address(pair), 1e18);
        tokB.transfer(address(pair), 1e18);
        vm.expectRevert(abi.encodeWithSelector(AmmPair.FactoryBrakedNewEntry.selector, 1));
        pair.mint(alice);
        vm.stopPrank();

        // 스왑도 진입이다 — 차단
        vm.prank(alice);
        tokA.transfer(address(pair), 1e18);
        vm.expectRevert(abi.encodeWithSelector(AmmPair.FactoryBrakedNewEntry.selector, 1));
        pair.swap(0, 1, bob);

        // 팩토리의 신규 페어 생성도 차단
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        factory.createPair(address(makeAddr("x")), address(makeAddr("y"))); // 코드 없어 TokenHasNoCode가 먼저? — whenEntryOpen이 modifier 체인에서 먼저다

        // 탈출: 회수는 항상 열려 있다
        vm.startPrank(alice);
        pair.transfer(address(pair), lp);
        pair.burn(alice);
        vm.stopPrank();
        // 예치분(1000e18) + 스왑 유입(1e18) 중 잠긴 최소 유동성 비례분만 남는다
        assertGt(tokA.balanceOf(alice), 1_000_000e18 - SEED - 2e18);
    }

    // ---- 상태 계량 (examples/amm/GAS.md 원본 데이터) ----

    function test_meter_deployFactoryAndPair() public {
        StateMeter.Result memory r;
        (, r) = StateMeter.measureDeploy(abi.encodePacked(type(AmmFactory).creationCode, abi.encode(guardian)));
        emit log_named_uint("factoryDeploy gasUsed", r.gasUsed);
        emit log_named_uint("factoryDeploy codeBytes", r.codeBytes);
        emit log_named_uint("factoryDeploy stateUnits", r.stateUnits);

        (, r) = StateMeter.measureDeploy(
            abi.encodePacked(type(AmmPair).creationCode, abi.encode(pair.token0(), pair.token1(), factory))
        );
        emit log_named_uint("pairDeploy gasUsed", r.gasUsed);
        emit log_named_uint("pairDeploy codeBytes", r.codeBytes);
        emit log_named_uint("pairDeploy stateUnits", r.stateUnits);
    }

    function test_meter_poolLifecycle() public {
        address[] memory tracked = new address[](1);
        tracked[0] = address(pair);

        // measureCall이 내부에서 vm.prank를 쓰므로 startPrank 없이 개별 prank로.
        vm.prank(alice);
        tokA.transfer(address(pair), SEED / 10);
        vm.prank(alice);
        tokB.transfer(address(pair), SEED / 10);
        StateMeter.Result memory r =
            StateMeter.measureCall(alice, tracked, address(pair), abi.encodeCall(pair.mint, (alice)));
        emit log_named_uint("mint gasUsed", r.gasUsed);
        emit log_named_uint("mint newSlots", r.newSlots);
        emit log_named_uint("mint stateUnits", r.stateUnits);

        // 스왑: 사전 이체(계량 제외) 후 swap만
        uint256 amountIn = 1e18;
        (uint256 rIn, uint256 rOut) = _reservesAB();
        vm.prank(alice);
        tokA.transfer(address(pair), amountIn);
        StateMeter.Result memory r2 = StateMeter.measureCall(
            alice, tracked, address(pair), abi.encodeCall(pair.swap, (uint256(0), _quote(amountIn, rIn, rOut), bob))
        );
        emit log_named_uint("swap gasUsed", r2.gasUsed);
        emit log_named_uint("swap newSlots", r2.newSlots);
        emit log_named_uint("swap logBytes", r2.logBytes);
        emit log_named_uint("swap stateUnits", r2.stateUnits);

        // 회수 (prank는 다음 호출 1회만 유효 — balanceOf를 먼저 읽는다)
        uint256 lpBalance = pair.balanceOf(alice);
        vm.prank(alice);
        pair.transfer(address(pair), lpBalance);
        StateMeter.Result memory r3 =
            StateMeter.measureCall(alice, tracked, address(pair), abi.encodeCall(pair.burn, (alice)));
        emit log_named_uint("burn gasUsed", r3.gasUsed);
        emit log_named_uint("burn newSlots", r3.newSlots);
        emit log_named_uint("burn stateUnits", r3.stateUnits);
    }
}
