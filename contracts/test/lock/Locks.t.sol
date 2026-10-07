// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";
import {TokenTimeLock} from "src/lock/TokenTimeLock.sol";
import {LinearVesting} from "src/lock/LinearVesting.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 7 — 배치형 타임락 + 자립형 베스팅 테스트.
/// @dev fixture: cliff 100s / duration 400s — cliff 직후 1/3 해제,
///      종료 시 전량. 배치형은 수혜자당 잠금 1개.
contract LocksTest is Test {
    FixedSupplyToken internal token;
    TokenTimeLock internal timelock;

    address internal alice = makeAddr("alice"); // 예치자
    address internal bob = makeAddr("bob"); // 수혜자
    address internal guardian = makeAddr("guardian");

    uint256 internal constant CLIFF = 100;
    uint256 internal constant DURATION = 400;
    uint256 internal constant LOCK_AMT = 1_000e18; // 타입 고정 — 이하 나눗셈은 런타임 버림

    function setUp() public {
        token = new FixedSupplyToken("Isle Coin", "ISLE", 10_000_000e18, alice);
        timelock = new TokenTimeLock(guardian, token);
    }

    /// @dev bob에게 1_000e18을 CLIFF/DURATION으로 잠근다.
    function _lockForBob(uint256 amount) internal {
        vm.startPrank(alice);
        token.approve(address(timelock), amount);
        timelock.lockFor(bob, amount, CLIFF, DURATION);
        vm.stopPrank();
    }

    // ================================================================ 배치형 타임락

    function test_lock_recordsSchedule() public {
        _lockForBob(1_000e18);
        (uint128 amount, uint128 released,,,) = timelock.locks(bob);
        assertEq(amount, 1_000e18);
        assertEq(released, 0);
        assertEq(token.balanceOf(address(timelock)), 1_000e18);
    }

    function test_lock_reverts() public {
        vm.startPrank(alice);
        token.approve(address(timelock), type(uint256).max);
        vm.expectRevert(TokenTimeLock.ZeroAmount.selector);
        timelock.lockFor(bob, 0, CLIFF, DURATION);
        vm.expectRevert(TokenTimeLock.ZeroDuration.selector);
        timelock.lockFor(bob, 1e18, 0, 0);
        vm.expectRevert(TokenTimeLock.ZeroDuration.selector);
        timelock.lockFor(bob, 1e18, DURATION + 1, DURATION); // cliff > duration
        vm.stopPrank();

        _lockForBob(1_000e18);
        vm.prank(alice);
        token.approve(address(timelock), 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenTimeLock.AlreadyLocked.selector, bob));
        timelock.lockFor(bob, 1e18, CLIFF, DURATION); // 두 번째 그랜트 — 거부

        // F-03: 무코드 토큰
        vm.expectRevert(TokenTimeLock.ZeroAmount.selector);
        new TokenTimeLock(guardian, IERC20(address(0xBEEF)));
    }

    /// @dev 스케줄 수학: cliff 경계 0 → 1초 후 최초 해제 → 종료 전 비례.
    function test_release_followsSchedule() public {
        _lockForBob(1_000e18);

        vm.warp(block.timestamp + CLIFF); // cliff 경계 — 아직 0
        assertEq(timelock.vested(bob), 0);
        vm.prank(bob);
        vm.expectRevert(TokenTimeLock.NothingToRelease.selector);
        timelock.release();

        vm.warp(block.timestamp + 1); // 1초 후: (101-100)/300 x 1_000
        assertEq(timelock.releasable(bob), LOCK_AMT / 300);
        vm.prank(bob);
        timelock.release();
        assertEq(token.balanceOf(bob), LOCK_AMT / 300);

        vm.warp(block.timestamp + 99); // 중간(200s): 100/300 지급 누적
        assertEq(timelock.vested(bob), LOCK_AMT * 100 / 300);
        assertEq(timelock.releasable(bob), LOCK_AMT * 100 / 300 - LOCK_AMT / 300);

        vm.warp(block.timestamp + DURATION); // 종료 후 전량
        vm.prank(bob);
        timelock.release();
        assertEq(token.balanceOf(bob), 1_000e18);
        assertEq(token.balanceOf(address(timelock)), 0);

        vm.prank(bob); // 재release는 없다
        vm.expectRevert(TokenTimeLock.NothingToRelease.selector);
        timelock.release();
    }

    /// @dev 여러 수혜자가 섞여도 각자의 스케줄만 받는다.
    function test_release_isolatedPerBeneficiary() public {
        _lockForBob(1_000e18);
        vm.startPrank(alice);
        token.approve(address(timelock), 500e18);
        timelock.lockFor(alice, 500e18, 0, DURATION); // cliff 0 즉시 해제형
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION);
        vm.prank(bob);
        timelock.release();
        vm.prank(alice);
        timelock.release();
        assertEq(token.balanceOf(bob), 1_000e18);
        assertEq(token.balanceOf(alice), 10_000_000e18 - 1_000e18); // 본인 예치분 회수
    }

    /// @dev 임의 시점 release는 (a) vested 이하, (b) 총지급 == amount,
    ///      (c) 재release 직후 0 — 이중지급 없음.
    function test_fuzz_releaseNeverOverpays(uint256 t1, uint256 t2) public {
        t1 = bound(t1, 0, 3 * DURATION);
        t2 = bound(t2, 0, 3 * DURATION);
        _lockForBob(1_000e18);

        vm.warp(block.timestamp + t1);
        uint256 v1 = timelock.vested(bob);
        _releaseIfDue();
        assertLe(token.balanceOf(bob), v1);

        vm.warp(block.timestamp + t2);
        uint256 v2 = timelock.vested(bob);
        _releaseIfDue();
        assertLe(token.balanceOf(bob), v2); // 총지급 <= 최종 vested

        // 종료 — 정확히 전량 (이미 받았으면 releasable==0이라 스킵)
        vm.warp(block.timestamp + 5 * DURATION);
        _releaseIfDue();
        assertEq(token.balanceOf(bob), 1_000e18);
        assertEq(timelock.releasable(bob), 0);
    }

    /// @dev due==0인 release는 NothingToRelease로 revert하는 정상 동작 —
    ///      fuzz 시퀀스에서는 due가 있는 때만 인출한다.
    function _releaseIfDue() internal {
        if (timelock.releasable(bob) == 0) return;
        vm.prank(bob);
        timelock.release();
    }

    function test_brake_blocksLockNotRelease() public {
        _lockForBob(1_000e18);
        vm.prank(guardian);
        timelock.engageBrake(1);

        vm.startPrank(alice);
        token.approve(address(timelock), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        timelock.lockFor(alice, 1e18, 0, 100);
        vm.stopPrank();

        vm.warp(block.timestamp + DURATION);
        vm.prank(bob); // 탈출은 열려 있다
        timelock.release();
        assertEq(token.balanceOf(bob), 1_000e18);
    }

    // ================================================================ 자립형 베스팅

    /// @dev alice(후원자)가 직접 배포 — 생성자 pullExact의 msg.sender는
    ///      alice다. CREATE 주소는 nonce로 예측 가능하므로 미리 승인한다.
    function _deployVesting(uint256 amount) internal returns (LinearVesting v) {
        uint64 n = vm.getNonce(alice);
        address predicted = vm.computeCreateAddress(alice, n);
        vm.startPrank(alice);
        token.approve(predicted, amount);
        // forge >= 1.8 counts a pranked call as alice's transaction and bumps
        // her nonce; put it back so the CREATE lands on the approved address.
        vm.setNonceUnsafe(alice, n);
        v = new LinearVesting(token, bob, amount, CLIFF, DURATION);
        vm.stopPrank();
    }

    function test_vesting_constructorEscrowsFullGrant() public {
        LinearVesting v = _deployVesting(5_000e18);
        assertEq(token.balanceOf(address(v)), 5_000e18);
        assertEq(v.total(), 5_000e18);
        assertEq(v.beneficiary(), bob);
    }

    function test_vesting_reverts() public {
        vm.expectRevert(LinearVesting.ZeroAmount.selector);
        new LinearVesting(IERC20(address(0xBEEF)), bob, 1e18, 0, 100); // F-03
        vm.prank(alice);
        token.approve(address(this), 1e18);
        vm.expectRevert(LinearVesting.ZeroAmount.selector);
        new LinearVesting(token, address(0), 1e18, 0, 100);
        vm.prank(alice);
        token.approve(address(this), 1e18);
        vm.expectRevert(LinearVesting.ZeroDuration.selector);
        new LinearVesting(token, bob, 1e18, 0, 0);
    }

    function test_vesting_claimSchedule() public {
        LinearVesting v = _deployVesting(3_000e18);
        vm.warp(block.timestamp + CLIFF);
        assertEq(v.claimable(), 0);

        vm.warp(block.timestamp + 100); // 절반: 100/300
        vm.prank(alice); // 누구나 가스 대낭 가능
        uint256 paid = v.claim();
        assertEq(paid, 3_000e18 * 100 / 300);
        assertEq(token.balanceOf(bob), paid);

        vm.warp(block.timestamp + 200); // 종료
        v.claim();
        assertEq(token.balanceOf(bob), 3_000e18);
        assertEq(v.claimable(), 0);
    }

    /// @dev 임의 시점 두 번 claim — 총지급은 vested 이하, 종료 후 전량.
    function test_fuzz_vestingNeverOverpays(uint256 t1, uint256 t2) public {
        t1 = bound(t1, 0, 3 * DURATION);
        t2 = bound(t2, 0, 3 * DURATION);
        LinearVesting v = _deployVesting(3_000e18);

        vm.warp(block.timestamp + t1);
        v.claim();
        assertLe(token.balanceOf(bob), v.vested());

        vm.warp(block.timestamp + t2);
        v.claim();
        assertLe(token.balanceOf(bob), v.vested());

        vm.warp(block.timestamp + 5 * DURATION);
        v.claim();
        assertEq(token.balanceOf(bob), 3_000e18);
        assertEq(v.claimable(), 0);
        assertEq(token.balanceOf(address(v)), 0);
    }

    /// @dev 기부(계약 외 전송)가 claim을 막거나 초과지급하지 않는다.
    function test_vesting_toleratesDonation() public {
        LinearVesting v = _deployVesting(1_000e18);
        vm.warp(block.timestamp + DURATION / 2);
        v.claim();
        uint256 paid1 = token.balanceOf(bob);

        vm.prank(alice);
        token.transfer(address(v), 500e18); // 잔액 > total — 유도 지급누적 포화
        vm.warp(block.timestamp + DURATION);
        v.claim();
        // vested 전액 1_000 + 기부분은 잔액에서 남는다 (vested까지만 지급)
        assertEq(token.balanceOf(bob), paid1 + (1_000e18 - paid1));
        assertEq(token.balanceOf(address(v)), 500e18); // 기부분은 잔여
    }

    // ================================================================ 상태 계량 (examples/lock/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r1) = StateMeter.measureDeploy(
            abi.encodePacked(type(TokenTimeLock).creationCode, abi.encode(guardian, address(token)))
        );
        emit log_named_uint("timeLockDeploy gasUsed", r1.gasUsed);
        emit log_named_uint("timeLockDeploy codeBytes", r1.codeBytes);
        emit log_named_uint("timeLockDeploy stateUnits", r1.stateUnits);

        uint64 n = vm.getNonce(alice);
        address predicted = vm.computeCreateAddress(alice, n);
        vm.startPrank(alice);
        token.approve(predicted, 1_000e18);
        vm.setNonceUnsafe(alice, n); // see _deployVesting
        (, StateMeter.Result memory r2) = StateMeter.measureDeploy(
            abi.encodePacked(
                type(LinearVesting).creationCode, abi.encode(address(token), bob, 1_000e18, CLIFF, DURATION)
            )
        );
        vm.stopPrank();
        emit log_named_uint("vestingDeploy gasUsed", r2.gasUsed);
        emit log_named_uint("vestingDeploy codeBytes", r2.codeBytes);
        emit log_named_uint("vestingDeploy stateUnits", r2.stateUnits);
    }

    function test_meter_lockRelease() public {
        vm.startPrank(alice);
        token.approve(address(timelock), type(uint256).max);
        vm.stopPrank();
        address[] memory tracked = new address[](1);
        tracked[0] = address(timelock);

        StateMeter.Result memory r1 = StateMeter.measureCall(
            alice, tracked, address(timelock), abi.encodeCall(timelock.lockFor, (bob, 1_000e18, CLIFF, DURATION))
        );
        emit log_named_uint("lockFor gasUsed", r1.gasUsed);
        emit log_named_uint("lockFor newSlots", r1.newSlots);
        emit log_named_uint("lockFor logBytes", r1.logBytes);
        emit log_named_uint("lockFor stateUnits", r1.stateUnits);

        vm.warp(block.timestamp + DURATION);
        StateMeter.Result memory r2 =
            StateMeter.measureCall(bob, tracked, address(timelock), abi.encodeCall(timelock.release, ()));
        emit log_named_uint("release gasUsed", r2.gasUsed);
        emit log_named_uint("release newSlots", r2.newSlots);
        emit log_named_uint("release logBytes", r2.logBytes);
        emit log_named_uint("release stateUnits", r2.stateUnits);
    }

    function test_meter_vestingClaim() public {
        vm.prank(alice);
        token.transfer(address(this), 1_000e18);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        token.approve(predicted, 1_000e18);
        LinearVesting v = new LinearVesting(token, bob, 1_000e18, 0, DURATION);
        address[] memory tracked = new address[](1);
        tracked[0] = address(v);

        vm.warp(block.timestamp + DURATION / 2);
        StateMeter.Result memory r = StateMeter.measureCall(alice, tracked, address(v), abi.encodeCall(v.claim, ()));
        emit log_named_uint("vestingClaim gasUsed", r.gasUsed);
        emit log_named_uint("vestingClaim newSlots", r.newSlots);
        emit log_named_uint("vestingClaim logBytes", r.logBytes);
        emit log_named_uint("vestingClaim stateUnits", r.stateUnits);
    }
}
