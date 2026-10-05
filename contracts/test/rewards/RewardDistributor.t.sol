// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";
import {RewardDistributor} from "src/rewards/RewardDistributor.sol";
import {SafeToken} from "src/common/SafeToken.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {FeeOnTransferToken} from "test/amm/Amm.t.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 6 — 스테이킹 보상 분배기 테스트.
/// @dev fixture 수치:
///      fund 100_000e18 / 10_000s (rate 10e18/s, 균등 나눗셈 — 버림 0),
///      alice/bob 스테이크 300/100 (총 400).
contract RewardDistributorTest is Test {
    FixedSupplyToken internal staking;
    FixedSupplyToken internal reward;
    RewardDistributor internal dist;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal guardian = makeAddr("guardian");

    uint256 internal constant FUND = 100_000e18;
    uint256 internal constant DURATION = 10_000;

    function setUp() public {
        staking = new FixedSupplyToken("Isle LP", "ILP", 10_000_000e18, alice);
        reward = new FixedSupplyToken("Isle Coin", "ISLE", 10_000_000e18, alice);
        dist = new RewardDistributor(guardian, staking, reward);
        _fundAs(alice, FUND, DURATION); // rate = 10e18/s
    }

    // ---------------------------------------------------------------- 헬퍼

    function _fundAs(address who, uint256 amount, uint256 durationSec) internal {
        vm.startPrank(who);
        reward.approve(address(dist), amount);
        dist.fundRewards(amount, durationSec);
        vm.stopPrank();
    }

    function _stakeAs(address who, uint256 amount) internal {
        vm.startPrank(who);
        staking.approve(address(dist), amount);
        dist.stake(amount);
        vm.stopPrank();
    }

    /// @dev alice 300 + bob 100 = 총 400 (비율 3:1).
    function _stakeBoth() internal {
        vm.prank(alice);
        staking.transfer(bob, 100e18);
        _stakeAs(alice, 300e18);
        _stakeAs(bob, 100e18);
    }

    function _claimAs(address who) internal returns (uint256 paid) {
        uint256 before = reward.balanceOf(who);
        vm.prank(who);
        paid = dist.claim();
        assertEq(reward.balanceOf(who) - before, paid);
    }

    // ---------------------------------------------------------------- 설정

    function test_setup_revertInvalidToken() public {
        vm.expectRevert(RewardDistributor.InvalidToken.selector);
        new RewardDistributor(guardian, IERC20(address(0xBEEF)), reward);
        vm.expectRevert(RewardDistributor.InvalidToken.selector);
        new RewardDistributor(guardian, staking, IERC20(address(0xBEEF)));
    }

    // ---------------------------------------------------------------- 보상 풀

    function test_fund_setsRateAndFinish() public {
        // setUp이 이미 fund했다 — 별도 컨트랙트에서 초기 상태 검증
        RewardDistributor fresh = new RewardDistributor(guardian, staking, reward);
        vm.prank(alice);
        reward.approve(address(fresh), 1_000e18);
        vm.prank(alice);
        fresh.fundRewards(1_000e18, 100);
        assertEq(fresh.rewardRate(), 10e18);
        assertEq(fresh.finishAt(), block.timestamp + 100);
        assertEq(reward.balanceOf(address(fresh)), 1_000e18);
    }

    function test_fund_revertsZero() public {
        vm.prank(alice);
        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        dist.fundRewards(0, 100);
        vm.prank(alice);
        vm.expectRevert(RewardDistributor.ZeroDuration.selector);
        dist.fundRewards(1e18, 0);
    }

    /// @dev 병합: fund 시점의 미방출분 + 신규분을 새 기간에 다시 나눈다.
    function test_fund_mergesRemaining() public {
        _stakeAs(alice, 400e18);
        vm.warp(block.timestamp + 500); // 방출 5_000 귀속
        _fundAs(alice, 5_000e18, 500);
        // remaining = 100_000 - 5_000(귀속) + 5_000(신규) = 100_000 over 500s
        assertEq(dist.rewardRate(), 200e18);
        assertEq(dist.finishAt(), block.timestamp + 500);
    }

    /// @dev 핵심 차별 — 스테이커 부재 구간의 방출 예정분이 소실되지 않고
    ///      다음 fund의 remaining에 편입된다 (잔액 기반 회계).
    function test_fund_recoversSkippedEmission() public {
        // setUp 시각 t=1: fund(100_000, 10_000s) — rate 10/s, finishAt 10_001
        vm.warp(block.timestamp + 100); // t=101
        _stakeAs(alice, 100e18);

        vm.warp(block.timestamp + 100); // t=201
        vm.prank(alice);
        dist.unstake(100e18); // 방출 1_000 확정(userOwed), totalStaked=0
        assertEq(dist.earned(alice), 1_000e18);

        // t=201..9_701 부재 구간 — 방출 정지 (finishAt은 그대로 흐른다)
        vm.warp(dist.finishAt() - 300); // t=9_701
        _stakeAs(alice, 100e18); // 재진입, t=9_701..10_001 방출 3_000

        vm.warp(dist.finishAt()); // 방출 종료
        assertEq(dist.earned(alice), 4_000e18); // 1_000(이월) + 3_000(진행)
        assertEq(reward.balanceOf(address(dist)), FUND);

        // 부재 구간의 미방출 96_000은 다음 fund가 회수한다:
        // remaining = (100_000 + 2_000) - 4_000 = 98_000 over 100s
        _fundAs(alice, 2_000e18, 100);
        assertEq(dist.rewardRate(), 980e18);
        assertEq(_claimAs(alice), 4_000e18);
    }

    // ---------------------------------------------------------------- 스테이킹

    function test_stake_creditsBalance() public {
        _stakeAs(alice, 300e18);
        assertEq(dist.userStaked(alice), 300e18);
        assertEq(dist.totalStaked(), 300e18);
        assertEq(staking.balanceOf(address(dist)), 300e18);
    }

    function test_stake_revertZero() public {
        vm.prank(alice);
        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        dist.stake(0);
    }

    /// @dev F-02 — FoT 스테이크 토큰은 도착량만 크레딧된다 (좌초 없음).
    function test_stake_fotCreditedByDelivery() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(alice, 100_000e18);
        RewardDistributor fotDist = new RewardDistributor(guardian, IERC20(address(fot)), reward);
        vm.startPrank(alice);
        fot.approve(address(fotDist), 1_000e18);
        fotDist.stake(1_000e18); // 990 도착
        vm.stopPrank();
        assertEq(fotDist.userStaked(alice), 990e18);
        assertEq(fot.balanceOf(address(fotDist)), 990e18);
    }

    function test_unstake_returnsTokensAndKeepsEarned() public {
        _stakeBoth();
        vm.warp(block.timestamp + 200); // 방출 2_000: alice 1_500, bob 500
        vm.prank(alice);
        dist.unstake(300e18);
        assertEq(staking.balanceOf(alice), 10_000_000e18 - 100e18); // bob에게 준 100 제외 전량 회수
        assertEq(dist.earned(alice), 1_500e18); // 귀속 보존
        assertEq(_claimAs(alice), 1_500e18);
    }

    function test_unstake_revertExcessive() public {
        _stakeAs(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RewardDistributor.InsufficientStake.selector, 101e18, 100e18));
        dist.unstake(101e18);
    }

    // ---------------------------------------------------------------- 분배

    function test_claim_paysProRata() public {
        _stakeBoth();
        vm.warp(block.timestamp + 100); // 방출 1_000 → rpt += 2.5e18
        assertEq(dist.earned(alice), 750e18);
        assertEq(dist.earned(bob), 250e18);
        assertEq(_claimAs(alice), 750e18);
        assertEq(_claimAs(bob), 250e18);
        assertEq(dist.totalDebt(), 0); // I2: 전 귀속 지급
    }

    function test_claim_viewMatchesExecution() public {
        _stakeBoth();
        vm.warp(block.timestamp + 333);
        uint256 quoted = dist.earned(alice);
        assertEq(_claimAs(alice), quoted);
        // 재claim은 0 — 스냅샷 갱신됨
        assertEq(_claimAs(alice), 0);
    }

    /// @dev I1/I2 통합 — 기간 완주 후 전원 claim이 풀을 정확히 소진한다.
    function test_claim_exhaustsPoolAfterFinish() public {
        _stakeBoth();
        vm.warp(dist.finishAt() + 5_000); // 종료 후에도 claim 가능
        assertEq(_claimAs(alice), 75_000e18);
        assertEq(_claimAs(bob), 25_000e18);
        assertEq(reward.balanceOf(address(dist)), 0);
        assertEq(dist.totalDebt(), 0);
    }

    function test_claim_zeroIsNoopBeforeAnyStake() public {
        vm.prank(bob);
        uint256 paid = dist.claim();
        assertEq(paid, 0);
    }

    function test_emission_stopsAfterFinish() public {
        _stakeAs(alice, 100e18);
        vm.warp(dist.finishAt());
        uint256 atFinish = dist.earned(alice);
        vm.warp(dist.finishAt() + 10_000);
        assertEq(dist.earned(alice), atFinish); // 추가 방출 없음
    }

    // ---------------------------------------------------------------- 불변식 fuzz

    /// @dev I1(지급 가능성) + I2(전 귀속 지급) + 토큰 보존 —
    ///      무작위 stake/unstake/claim/warp 시퀀스 후 풀은 정확히 정산된다.
    function test_fuzz_poolAlwaysSolvent(
        uint256 s1,
        uint256 s2,
        uint256 s3,
        uint256 s4,
        uint256 t1,
        uint256 t2,
        uint256 t3,
        uint256 t4
    ) public {
        address[2] memory users = [alice, bob];
        uint256[4] memory seeds = [s1, s2, s3, s4];
        uint256[4] memory times = [t1, t2, t3, t4];

        vm.prank(alice);
        staking.transfer(bob, 1_000e18);
        // 시퀀스 중간 claim까지 포함한 전체 지급 추적 (잔액 기반)
        uint256[2] memory rewardBefore = [reward.balanceOf(alice), reward.balanceOf(bob)];

        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + bound(times[i], 1, 3_000));
            address who = users[seeds[i] % 2];
            uint256 action = (seeds[i] >> 8) % 3;
            if (action == 0) {
                _stakeAs(who, bound(seeds[i], 1e18, 100e18));
            } else if (action == 1) {
                uint256 staked = dist.userStaked(who);
                if (staked > 0) {
                    vm.prank(who);
                    dist.unstake(bound(seeds[i], 1, staked));
                }
            } else {
                vm.prank(who);
                dist.claim();
            }
        }

        // 방출 종료 후 전원 claim — 부족 지급(revert) 없이 전 귀속 정산.
        vm.warp(dist.finishAt() + 1);
        for (uint256 i; i < 2; ++i) {
            vm.prank(users[i]);
            dist.claim();
        }

        uint256 totalClaimed;
        for (uint256 i; i < 2; ++i) {
            totalClaimed += reward.balanceOf(users[i]) - rewardBefore[i];
        }

        // 토큰 보존: fund 총액 == 총지급 + 잔여. 잔여의 정체는
        // (a) 스테이커 부재 구간의 미방출분 + (b) 정수 버림 dust 다.
        assertEq(totalClaimed + reward.balanceOf(address(dist)), FUND);
        // I1: 잔액이 항상 부채를 덮는다 — 결코 부족 지급하지 않는다
        assertGe(reward.balanceOf(address(dist)), dist.totalDebt());
        // I2(근사): 전원 claim 후 부채는 정수 버림 dust만 남는다.
        // 매 귀속마다 rpt/earned 나눗셈 버림이 사용자당 <1 wei 씩 누적되므로
        // 20회 내외 상호작용에서 1_000 wei면 넉넉한 상한이다.
        assertLe(dist.totalDebt(), 1_000);
        // 스테이크 전량 인출 가능
        for (uint256 i; i < 2; ++i) {
            uint256 staked = dist.userStaked(users[i]);
            if (staked > 0) {
                vm.prank(users[i]);
                dist.unstake(staked);
            }
        }
        assertEq(staking.balanceOf(address(dist)), 0);
    }

    // ---------------------------------------------------------------- F-01: 재진입

    /// @dev 악성 스테이크 토큰이 transferFrom 중 stake를 재호출한다 —
    ///      nonReentrant가 막는다 (F-01 PoC). guard의 revert는 SafeToken의
    ///      low-level call을 거쳐 TokenTransferFailed로 표면화된다 —
    ///      stake가 전체 실패하고 totalStaked==0인 것이 방어 증명이다.
    function test_reentrancy_stakeBlocked() public {
        ReentrantStakeToken evil = new ReentrantStakeToken();
        evil.mint(alice, 1_000e18);
        RewardDistributor evilDist = new RewardDistributor(guardian, IERC20(address(evil)), reward);
        evil.arm(evilDist);

        vm.startPrank(alice);
        // max 승인 — 전송 중 allowance 차감으로 재진입 transferFrom이
        // allowance 고갈로 죽는 걸 막고 guard 자체를 시험한다
        evil.approve(address(evilDist), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SafeToken.TokenTransferFailed.selector, address(evil)));
        evilDist.stake(100e18);
        vm.stopPrank();
        assertEq(evilDist.totalStaked(), 0);
    }

    // ---------------------------------------------------------------- brake

    function test_brake_blocksEntryNotExit() public {
        _stakeAs(alice, 100e18);
        vm.warp(block.timestamp + 100);
        vm.prank(guardian);
        dist.engageBrake(1);

        vm.prank(alice);
        staking.approve(address(dist), 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        dist.stake(1e18);

        vm.prank(alice);
        reward.approve(address(dist), 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        dist.fundRewards(1e18, 100);

        // 탈출은 항상 열려 있다
        vm.prank(alice);
        dist.unstake(100e18);
        assertEq(_claimAs(alice), 1_000e18); // 100s x 10/s
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/rewards/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r) = StateMeter.measureDeploy(
            abi.encodePacked(
                type(RewardDistributor).creationCode, abi.encode(guardian, address(staking), address(reward))
            )
        );
        emit log_named_uint("distributorDeploy gasUsed", r.gasUsed);
        emit log_named_uint("distributorDeploy codeBytes", r.codeBytes);
        emit log_named_uint("distributorDeploy stateUnits", r.stateUnits);
    }

    function test_meter_lifecycle() public {
        RewardDistributor fresh = new RewardDistributor(guardian, staking, reward);
        vm.startPrank(alice);
        staking.approve(address(fresh), type(uint256).max);
        reward.approve(address(fresh), type(uint256).max);
        vm.stopPrank();

        address[] memory tracked = new address[](1);
        tracked[0] = address(fresh);

        StateMeter.Result memory rf =
            StateMeter.measureCall(alice, tracked, address(fresh), abi.encodeCall(fresh.fundRewards, (FUND, DURATION)));
        emit log_named_uint("fund gasUsed", rf.gasUsed);
        emit log_named_uint("fund newSlots", rf.newSlots);
        emit log_named_uint("fund logBytes", rf.logBytes);
        emit log_named_uint("fund stateUnits", rf.stateUnits);

        StateMeter.Result memory rs =
            StateMeter.measureCall(alice, tracked, address(fresh), abi.encodeCall(fresh.stake, (100e18)));
        emit log_named_uint("stake gasUsed", rs.gasUsed);
        emit log_named_uint("stake newSlots", rs.newSlots);
        emit log_named_uint("stake logBytes", rs.logBytes);
        emit log_named_uint("stake stateUnits", rs.stateUnits);

        vm.warp(block.timestamp + 1_000);

        StateMeter.Result memory rc =
            StateMeter.measureCall(alice, tracked, address(fresh), abi.encodeCall(fresh.claim, ()));
        emit log_named_uint("claim gasUsed", rc.gasUsed);
        emit log_named_uint("claim newSlots", rc.newSlots);
        emit log_named_uint("claim logBytes", rc.logBytes);
        emit log_named_uint("claim stateUnits", rc.stateUnits);

        StateMeter.Result memory ru =
            StateMeter.measureCall(alice, tracked, address(fresh), abi.encodeCall(fresh.unstake, (100e18)));
        emit log_named_uint("unstake gasUsed", ru.gasUsed);
        emit log_named_uint("unstake newSlots", ru.newSlots);
        emit log_named_uint("unstake logBytes", ru.logBytes);
        emit log_named_uint("unstake stateUnits", ru.stateUnits);
    }
}

/// @dev F-01 PoC — transfer 중 stake 재진입을 시도하는 악성 스테이크 토큰.
contract ReentrantStakeToken is ERC20 {
    RewardDistributor public target;
    bool internal armed;

    constructor() ERC20("Evil Stake", "EVL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(RewardDistributor t) external {
        target = t;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && to == address(target) && from != address(0)) {
            armed = false; // 1회만 시도 (무한 루프 방지)
            target.stake(value); // nonReentrant에 막힌다
        }
    }
}
