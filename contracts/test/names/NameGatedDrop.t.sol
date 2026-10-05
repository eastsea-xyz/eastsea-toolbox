// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EastSeaNames} from "src/system/EastSeaNames.sol";
import {NameGatedDrop} from "src/names/NameGatedDrop.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 15 — 이름 자격 드롭 테스트.
/// @dev 여기서는 names를 mock 하지 않는다: 진짜 EastSeaNames를 배포해
///      commit → (60초) → register → setAddr → setReverse 전체 절차로
///      이름을 만든다. 자격 판정을 통째로 위임한 앱은 위임 대상의
///      실제 정확성(정직성 조건·만료·능동 삭제) 위에서 검증되어야
///      한다 — mock 은 "내가 짜 믿는 reverseOf"만 검증한다.
contract NameGatedDropTest is Test {
    EastSeaNames internal names;
    NameGatedDrop internal drop;

    address internal distributor = makeAddr("distributor");
    address internal alice = makeAddr("alice"); // 이름 보유
    address internal bob = makeAddr("bob"); // 이름 없음

    uint256 internal constant DROP = 0.1 ether;
    uint48 internal constant CLAIM_PERIOD = 30 days;

    function setUp() public {
        names = new EastSeaNames();

        _registerName(alice, "alice");

        vm.deal(address(this), 100 ether);
        drop = new NameGatedDrop(address(names), distributor, DROP, CLAIM_PERIOD);
        vm.deal(address(drop), 10 ether); // 풀 충전
    }

    /// @dev 시스템 이름 등록 전체 절차 — 커밋(0.01e 소각) → 61초 →
    ///      리빌(잔여 0.09e 소각, 5자 이상 요율) → addr → reverse.
    ///      relayer 0: 커미터 본인만 리빌.
    function _registerName(address who, string memory name) internal {
        bytes32 salt = keccak256(abi.encode(name, who));
        bytes32 commitment = keccak256(abi.encodePacked(name, who, salt, address(0)));

        vm.deal(who, 1 ether);
        vm.startPrank(who);
        names.commit{value: names.COMMIT_BOND()}(commitment);
        vm.warp(block.timestamp + names.MIN_COMMIT_AGE() + 1);
        names.register{value: names.FEE_5_PLUS() - names.COMMIT_BOND()}(name, who, salt, address(0));
        names.setAddr(name, who);
        names.setReverse(name);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 청구

    function test_claim_paysNamedAccount() public {
        assertTrue(drop.claimed(alice) == false);
        uint256 before = alice.balance;

        vm.expectEmit(true, true, true, true);
        emit NameGatedDrop.Claimed(alice, "alice");
        vm.prank(alice);
        drop.claim();

        assertEq(alice.balance, before + DROP);
        assertTrue(drop.claimed(alice));
        assertEq(drop.claimCount(), 1);
        assertEq(address(drop).balance, 10 ether - DROP);
    }

    function test_claim_reverts() public {
        // primary name 없음 — 자격의 전부
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(NameGatedDrop.NoPrimaryName.selector, bob));
        drop.claim();

        // 이중 청구
        vm.prank(alice);
        drop.claim();
        vm.prank(alice);
        vm.expectRevert(NameGatedDrop.AlreadyClaimed.selector);
        drop.claim();

        // 풀 부족 — 잔액이 dropAmount 미만
        NameGatedDrop poor = new NameGatedDrop(address(names), distributor, 5 ether, CLAIM_PERIOD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NameGatedDrop.InsufficientPool.selector, 5 ether, 0));
        poor.claim();

        // 마감 후 청구 — 검증자는 미청구 이름 보유자여야 한다(alice 는
        // 위에서 이미 청구 — AlreadyClaimed 가 마감보다 먼저다)
        address carol = makeAddr("carol");
        _registerName(carol, "carol");
        bytes memory closed =
            abi.encodeWithSelector(NameGatedDrop.ClaimClosed.selector, drop.deadline() + 1, drop.deadline());
        vm.warp(drop.deadline() + 1);
        vm.prank(carol);
        vm.expectRevert(closed);
        drop.claim();

        // 생성자
        vm.expectRevert(NameGatedDrop.ZeroAmount.selector);
        new NameGatedDrop(address(names), distributor, 0, CLAIM_PERIOD);
        vm.expectRevert(NameGatedDrop.ZeroDistributor.selector);
        new NameGatedDrop(address(names), address(0), DROP, CLAIM_PERIOD);
        vm.expectRevert(NameGatedDrop.ZeroPeriod.selector);
        new NameGatedDrop(address(names), distributor, DROP, 0);
    }

    /// @dev 이름이 만료되면 자격도 즉시 사라진다 — drop 은 만료를
    ///      자체 관리하지 않고 reverseOf 가 조용해지는 것을 따른다.
    function test_claim_nameExpiryRevokesEligibility() public {
        // 유예 마지막 순간까지 산다 — _live 는 now < expires + grace 미만
        uint64 graceEnd = names.expiresOf(names.nodeFor("alice")) + names.GRACE_PERIOD();
        vm.warp(uint256(graceEnd) - 1);
        assertEq(names.reverseOf(alice), "alice"); // 유예 중 — 아직 live

        vm.warp(graceEnd);
        assertEq(names.reverseOf(alice), ""); // 조용해졌다

        // warp 이 1년 뒤까지 갔으므로 원본 drop 은 이미 마감 — 죽은
        // 이름의 거부가 마감 거부(ClaimClosed)와 섞이지 않게 새 drop
        // 을 지금 배포해 청구 창구를 다시 연다
        NameGatedDrop fresh = new NameGatedDrop(address(names), distributor, DROP, CLAIM_PERIOD);
        vm.deal(address(fresh), 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NameGatedDrop.NoPrimaryName.selector, alice));
        fresh.claim();
    }

    /// @dev 정직성 조건 — 이름이 다른 주소를 가리키면 reverseOf 는
    ///      "" 다(setAddr 이 능동 삭제). 클레임은 죽는다.
    function test_claim_addrMovedKillsReverse() public {
        vm.prank(alice);
        names.setAddr("alice", makeAddr("coldstore"));

        assertEq(names.reverseOf(alice), "");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NameGatedDrop.NoPrimaryName.selector, alice));
        drop.claim();
    }

    /// @dev 자격은 "지금 그 이름을 대표하는 계정"이다 — 이름을 받은
    ///      새 소유자가 addr+reverse 를 다시 세우면 청구 가능하다.
    function test_claim_transferredName() public {
        vm.startPrank(alice);
        names.transferPropose("alice", bob);
        vm.stopPrank();

        vm.prank(bob);
        names.transferAccept("alice");
        _setAddrAndReverse(bob, "alice");

        assertEq(names.reverseOf(bob), "alice");
        vm.prank(bob);
        drop.claim();
        assertTrue(drop.claimed(bob));
    }

    function _setAddrAndReverse(address who, string memory name) internal {
        vm.startPrank(who);
        names.setAddr(name, who);
        names.setReverse(name);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 회수

    function test_sweep_afterDeadline() public {
        vm.prank(alice);
        drop.claim();

        vm.expectRevert(abi.encodeWithSelector(NameGatedDrop.SweepTooEarly.selector, block.timestamp, drop.deadline()));
        drop.sweep();

        vm.warp(drop.deadline() + 1);
        uint256 before = distributor.balance;
        vm.expectEmit(true, true, true, true);
        emit NameGatedDrop.Swept(distributor, 10 ether - DROP);
        drop.sweep(); // 누구나

        assertEq(distributor.balance, before + 10 ether - DROP);
        assertEq(address(drop).balance, 0);
    }

    /// @dev 풀 충전은 누구나 — receive 로그 없이 잔액만
    function test_receive_fundsThePool() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok,) = address(drop).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(drop).balance, 11 ether);
    }

    // ---------------------------------------------------------------- 불변식

    /// @dev n명 중 절반만 이름 보유 — 청구자 수·지급액·잔액 보존.
    ///      이름은 각자 61초 간격으로 등록된다(fuzz warp 누적).
    function test_fuzz_claimConservation(uint8 seed) public {
        uint256 named = bound(seed, 1, 6); // 이름 보유자
        uint256 unnamed = bound(uint256(keccak256(abi.encode(seed))), 1, 6);

        for (uint256 i; i < named; ++i) {
            _registerName(address(uint160(0x1000 + i)), string.concat("named", vm.toString(i)));
        }
        for (uint256 i; i < unnamed; ++i) {
            vm.deal(address(uint160(0x2000 + i)), 1 ether);
        }

        uint256 funded = address(drop).balance;

        // I1: 이름 없는 계정은 한 명도 못 받는다
        for (uint256 i; i < unnamed; ++i) {
            address u = address(uint160(0x2000 + i));
            vm.prank(u);
            vm.expectRevert(abi.encodeWithSelector(NameGatedDrop.NoPrimaryName.selector, u));
            drop.claim();
        }

        // I2: 이름 보유자 전원이 정확히 DROP씩 받는다
        for (uint256 i; i < named; ++i) {
            vm.prank(address(uint160(0x1000 + i)));
            drop.claim();
        }

        assertEq(drop.claimCount(), named);
        assertEq(address(drop).balance, funded - named * DROP);
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/namegate/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r) = StateMeter.measureDeploy(
            abi.encodePacked(
                type(NameGatedDrop).creationCode, abi.encode(address(names), distributor, DROP, CLAIM_PERIOD)
            )
        );
        emit log_named_uint("dropDeploy gasUsed", r.gasUsed);
        emit log_named_uint("dropDeploy codeBytes", r.codeBytes);
        emit log_named_uint("dropDeploy stateUnits", r.stateUnits);
    }

    function test_meter_lifecycle() public {
        _registerName(bob, "bobby");
        address[] memory tracked = new address[](1);
        tracked[0] = address(drop);

        StateMeter.Result memory r1 =
            StateMeter.measureCall(alice, tracked, address(drop), abi.encodeCall(drop.claim, ()));
        emit log_named_uint("claimFirst gasUsed", r1.gasUsed);
        emit log_named_uint("claimFirst newSlots", r1.newSlots);
        emit log_named_uint("claimFirst logBytes", r1.logBytes);
        emit log_named_uint("claimFirst stateUnits", r1.stateUnits);

        StateMeter.Result memory r2 =
            StateMeter.measureCall(bob, tracked, address(drop), abi.encodeCall(drop.claim, ()));
        emit log_named_uint("claimSecond gasUsed", r2.gasUsed);
        emit log_named_uint("claimSecond newSlots", r2.newSlots);
        emit log_named_uint("claimSecond stateUnits", r2.stateUnits);

        vm.warp(drop.deadline() + 1);
        StateMeter.Result memory r3 =
            StateMeter.measureCall(distributor, tracked, address(drop), abi.encodeCall(drop.sweep, ()));
        emit log_named_uint("sweep gasUsed", r3.gasUsed);
        emit log_named_uint("sweep stateUnits", r3.stateUnits);
    }
}
