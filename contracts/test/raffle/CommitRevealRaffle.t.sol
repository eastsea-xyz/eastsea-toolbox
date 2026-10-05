// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitRevealRaffle} from "src/raffle/CommitRevealRaffle.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 14 — 커밋-리빌 래플 테스트.
/// @dev fixture: 티켓 1 ether, 참가 7일, 리빌 창구 3일. 시드는
///      keccak256(abi.encodePacked(seed))로 커밋. prevrandao는
///      vm.prevrandao로 고정해 우승자를 결정론적으로 만든다.
contract CommitRevealRaffleTest is Test {
    CommitRevealRaffle internal raffle;

    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant SEED = bytes32(uint256(0x5EED));
    bytes32 internal seedCommit;

    uint256 internal constant PRICE = 1 ether;
    uint48 internal constant ENTER = 7 days;
    uint48 internal constant WINDOW = 3 days;

    function setUp() public {
        seedCommit = keccak256(abi.encodePacked(SEED));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        raffle = new CommitRevealRaffle(guardian, seedCommit, PRICE, ENTER, WINDOW);
    }

    function _enterAs(address who) internal {
        vm.prank(who);
        raffle.enter{value: PRICE}();
    }

    function _toRevealWindow() internal {
        vm.warp(raffle.enterDeadline() + 1);
    }

    // ---------------------------------------------------------------- 참가

    function test_enter_recordsTickets() public {
        _enterAs(alice);
        _enterAs(alice); // 중복 참가 = 2장
        vm.expectEmit(true, true, true, true);
        emit CommitRevealRaffle.Entered(bob, 2, 3);
        _enterAs(bob);

        assertEq(raffle.playerCount(), 3);
        assertEq(raffle.players(0), alice);
        assertEq(raffle.players(2), bob);
        assertEq(address(raffle).balance, 3 ether);
    }

    function test_enter_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealRaffle.WrongPrice.selector, 2 ether, PRICE));
        raffle.enter{value: 2 ether}();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CommitRevealRaffle.WrongPrice.selector, 0, PRICE));
        raffle.enter{value: 0}();

        // 직접 송금도 WrongPrice — 참가비와 정확히 같아도 receive는 거부
        (bool ok,) = address(raffle).call{value: PRICE}("");
        assertFalse(ok);

        // 마감 후
        bytes memory closed = abi.encodeWithSelector(
            CommitRevealRaffle.EntryClosed.selector, raffle.enterDeadline() + 1, raffle.enterDeadline()
        );
        vm.warp(raffle.enterDeadline() + 1);
        vm.prank(alice);
        vm.expectRevert(closed);
        raffle.enter{value: PRICE}();

        // 생성자
        vm.expectRevert(CommitRevealRaffle.ZeroCommit.selector);
        new CommitRevealRaffle(guardian, bytes32(0), PRICE, ENTER, WINDOW);
        vm.expectRevert(CommitRevealRaffle.ZeroPrice.selector);
        new CommitRevealRaffle(guardian, seedCommit, 0, ENTER, WINDOW);
        vm.expectRevert(CommitRevealRaffle.ZeroPeriod.selector);
        new CommitRevealRaffle(guardian, seedCommit, PRICE, 0, WINDOW);
    }

    // ---------------------------------------------------------------- 추첨

    /// @dev prevrandao 고정 — 우승자는 결정론적으로 재현된다
    function test_reveal_paysWinnerDeterministically() public {
        for (uint256 i; i < 5; ++i) {
            _enterAs(i % 2 == 0 ? alice : bob);
        }
        _toRevealWindow();

        vm.prevrandao(bytes32(uint256(7)));
        // 기대 우승자를 로컬로 재현 — 컨트랙트와 같은 산수
        uint256 idx = uint256(keccak256(abi.encode(SEED, bytes32(uint256(7))))) % 5;
        address expectWinner = idx % 2 == 0 ? alice : bob;

        vm.expectEmit(true, true, true, true);
        emit CommitRevealRaffle.Drawn(expectWinner, 5 ether, keccak256(abi.encode(SEED, bytes32(uint256(7)))));
        raffle.reveal(SEED); // 누구나 — 공개된 시드는 누구나 제출

        assertEq(raffle.winner(), expectWinner);
        // alice 3장(100-3+5=102), bob 2장(100-2+5=103)
        assertEq(expectWinner.balance, expectWinner == alice ? 102 ether : 103 ether);
        assertEq(address(raffle).balance, 0);
        assertTrue(raffle.drawn());

        // 재추첨 불가
        vm.expectRevert(CommitRevealRaffle.AlreadyDrawn.selector);
        raffle.reveal(SEED);
    }

    /// @dev 우승자는 정확히 커밋된 시드의 함수다 — 같은 명단·같은
    ///      prevrandao에서 로컬 재현과 인덱스가 일치한다
    function test_reveal_outcomeFollowsCommittedSeed() public {
        bytes32 seedA = bytes32(uint256(1));
        bytes32 seedB = bytes32(uint256(2));
        CommitRevealRaffle rA =
            new CommitRevealRaffle(guardian, keccak256(abi.encodePacked(seedA)), PRICE, ENTER, WINDOW);
        CommitRevealRaffle rB =
            new CommitRevealRaffle(guardian, keccak256(abi.encodePacked(seedB)), PRICE, ENTER, WINDOW);

        for (uint256 i; i < 4; ++i) {
            address p = address(uint160(i + 1));
            vm.deal(p, 2 ether); // rA·rB 두 번 참가
            vm.startPrank(p);
            rA.enter{value: PRICE}();
            rB.enter{value: PRICE}();
            vm.stopPrank();
        }
        vm.warp(rA.enterDeadline() + 1);
        vm.prevrandao(bytes32(uint256(42)));

        rA.reveal(seedA);
        uint256 idxA = uint256(keccak256(abi.encode(seedA, bytes32(uint256(42))))) % 4;
        assertEq(rA.winner(), address(uint160(idxA + 1)));

        rB.reveal(seedB);
        uint256 idxB = uint256(keccak256(abi.encode(seedB, bytes32(uint256(42))))) % 4;
        assertEq(rB.winner(), address(uint160(idxB + 1)));
    }

    function test_reveal_reverts() public {
        _enterAs(alice);
        _toRevealWindow();

        // 잘못된 시드
        bytes32 wrong = keccak256(abi.encodePacked(bytes32(uint256(0xBAD))));
        vm.expectRevert(abi.encodeWithSelector(CommitRevealRaffle.InvalidSeed.selector, wrong, seedCommit));
        raffle.reveal(bytes32(uint256(0xBAD)));

        // 리빌 창구 전 — 아직 참가 마감 전
        CommitRevealRaffle fresh = new CommitRevealRaffle(guardian, seedCommit, PRICE, ENTER, WINDOW);
        bytes memory early = abi.encodeWithSelector(
            CommitRevealRaffle.RevealTooEarly.selector, fresh.enterDeadline(), fresh.enterDeadline()
        );
        vm.warp(fresh.enterDeadline());
        vm.expectRevert(early);
        fresh.reveal(SEED);

        // 리빌 마감 후 reveal은 닫힌다
        bytes memory late = abi.encodeWithSelector(
            CommitRevealRaffle.RevealClosed.selector, raffle.revealDeadline() + 1, raffle.revealDeadline()
        );
        vm.warp(raffle.revealDeadline() + 1);
        vm.expectRevert(late);
        raffle.reveal(SEED);
    }

    /// @dev 참가자가 없으면 추첨 불가 — 잔액도 없다(잠긴 돈 없음)
    function test_draw_noTickets() public {
        _toRevealWindow();
        vm.expectRevert(CommitRevealRaffle.NoTickets.selector);
        raffle.reveal(SEED);
    }

    // ---------------------------------------------------------------- 리빌 거부 강행

    /// @dev operator가 시드를 보류해도 prevrandao로 추첨은 완결된다
    function test_drawWithoutSeed_afterWithholding() public {
        _enterAs(alice);
        _enterAs(bob);
        assertEq(raffle.revealDeadline(), uint256(raffle.enterDeadline()) + WINDOW);

        // 창구 안에서는 아직 강행 불가
        _toRevealWindow();
        bytes memory withheld = abi.encodeWithSelector(
            CommitRevealRaffle.SeedWithheld.selector, raffle.revealDeadline(), raffle.revealDeadline()
        );
        vm.warp(raffle.revealDeadline());
        vm.expectRevert(withheld);
        raffle.drawWithoutSeed();

        // 마감 후 강행 — prevrandao만으로
        vm.warp(raffle.revealDeadline() + 1);
        vm.prevrandao(bytes32(uint256(9)));
        address expectWinner = uint256(bytes32(uint256(9))) % 2 == 0 ? alice : bob;
        raffle.drawWithoutSeed();

        assertEq(raffle.winner(), expectWinner);
        assertEq(expectWinner.balance, 101 ether); // 100 + 상금 2 - 참가비 1
        assertEq(address(raffle).balance, 0);

        vm.expectRevert(CommitRevealRaffle.AlreadyDrawn.selector);
        raffle.drawWithoutSeed();
    }

    // ---------------------------------------------------------------- 불변식

    /// @dev 임의 인원 참가 + 두 추첨 경로 — 상금은 정확히 티켓 수 ×
    ///      가격이고 우승자는 반드시 참가자다. prevrandao 임의값.
    function test_fuzz_drawPaysAParticipantExactly(uint8 playerSeed, bytes32 rand, uint8 routeSeed) public {
        uint256 n = bound(playerSeed, 1, 10);
        address[] memory entrants = new address[](n);
        for (uint256 i; i < n; ++i) {
            entrants[i] = makeAddr(string.concat("p", vm.toString(i)));
            vm.deal(entrants[i], 2 ether);
            vm.prank(entrants[i]);
            raffle.enter{value: PRICE}();
        }

        vm.prevrandao(rand);
        if (routeSeed % 2 == 0) {
            vm.warp(raffle.enterDeadline() + 1); // 리빌 창구 안
            raffle.reveal(SEED);
        } else {
            vm.warp(raffle.revealDeadline() + 1); // 리빌 마감 후 강행
            raffle.drawWithoutSeed();
        }

        // I1: 우승자는 참가자다
        address w = raffle.winner();
        bool found;
        for (uint256 i; i < n; ++i) {
            if (entrants[i] == w) found = true;
        }
        assertTrue(found);

        // I2: 상금 == 티켓 수 × 가격 — 정확한 등식
        assertEq(w.balance, 2 ether - PRICE + n * PRICE);
        assertEq(address(raffle).balance, 0);
    }

    // ---------------------------------------------------------------- brake

    function test_brake_blocksEntryNotDraw() public {
        _enterAs(alice);
        vm.prank(guardian);
        raffle.engageBrake(1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        raffle.enter{value: PRICE}();

        // 추첨·지급은 열려 있다
        _toRevealWindow();
        raffle.reveal(SEED);
        assertEq(raffle.winner(), alice);
        assertEq(alice.balance, 100 ether); // 유일 참가자 — 참가비가 그대로 상금
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/raffle/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r) = StateMeter.measureDeploy(
            abi.encodePacked(
                type(CommitRevealRaffle).creationCode, abi.encode(guardian, seedCommit, PRICE, ENTER, WINDOW)
            )
        );
        emit log_named_uint("raffleDeploy gasUsed", r.gasUsed);
        emit log_named_uint("raffleDeploy codeBytes", r.codeBytes);
        emit log_named_uint("raffleDeploy stateUnits", r.stateUnits);
    }

    function test_meter_lifecycle() public {
        address[] memory tracked = new address[](1);
        tracked[0] = address(raffle);

        StateMeter.Result memory r1 =
            StateMeter.measureCallValue(alice, tracked, address(raffle), abi.encodeCall(raffle.enter, ()), PRICE);
        emit log_named_uint("enter gasUsed", r1.gasUsed);
        emit log_named_uint("enter newSlots", r1.newSlots);
        emit log_named_uint("enter logBytes", r1.logBytes);
        emit log_named_uint("enter stateUnits", r1.stateUnits);

        StateMeter.Result memory r2 =
            StateMeter.measureCallValue(bob, tracked, address(raffle), abi.encodeCall(raffle.enter, ()), PRICE);
        emit log_named_uint("enter2 gasUsed", r2.gasUsed);
        emit log_named_uint("enter2 newSlots", r2.newSlots);
        emit log_named_uint("enter2 stateUnits", r2.stateUnits);

        _toRevealWindow();
        StateMeter.Result memory r3 =
            StateMeter.measureCall(alice, tracked, address(raffle), abi.encodeCall(raffle.reveal, (SEED)));
        emit log_named_uint("reveal gasUsed", r3.gasUsed);
        emit log_named_uint("reveal newSlots", r3.newSlots);
        emit log_named_uint("reveal logBytes", r3.logBytes);
        emit log_named_uint("reveal stateUnits", r3.stateUnits);
    }
}
