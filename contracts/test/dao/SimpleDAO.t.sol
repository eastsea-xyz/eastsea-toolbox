// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleDAO} from "src/dao/SimpleDAO.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 실행 대상 스파이 — 받은 native와 calldata를 기록한다.
contract Counterparty {
    uint256 public paid;
    uint256 public noted;

    receive() external payable {
        paid += msg.value;
    }

    function note(uint256 v) external {
        noted = v;
    }
}

/// @notice 예제 11 — 단순 DAO 테스트.
/// @dev fixture: 공급 1M vote 토큰을 5인에게 균등(200k) 분배,
///      quorum 400k(2인으로 부족, 3인이면 통과), 투표 3일 + 타임락 2일
///      + 유예 7일. 서명은 주소 오름차순으로 정렬해 제출한다.
contract SimpleDAOTest is Test {
    SimpleDAO internal dao;
    FixedSupplyToken internal vote;
    Counterparty internal target;

    address[] internal voters = new address[](5);

    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");

    uint256 internal constant SUPPLY = 1_000_000e18;
    uint256 internal constant QUORUM = 400_000e18;
    uint256 internal constant VOTE_DAYS = 3 days;
    uint256 internal constant DELAY = 2 days;
    uint256 internal constant GRACE = 7 days;

    function setUp() public {
        vote = new FixedSupplyToken("Vote", "VOTE", SUPPLY, alice);
        dao = new SimpleDAO(guardian, vote, QUORUM, uint48(VOTE_DAYS), uint48(DELAY), uint48(GRACE));
        target = new Counterparty();

        for (uint256 i; i < 5; ++i) {
            voters[i] = vm.addr(i + 1);
        }
        vm.startPrank(alice);
        for (uint256 i; i < 5; ++i) {
            vote.transfer(voters[i], SUPPLY / 5); // 200k씩
        }
        vm.stopPrank();

        vm.deal(address(dao), 100 ether); // 국고
    }

    // ---------------------------------------------------------------- 헬퍼

    function _sign(uint256 proposalId, uint256 key) internal view returns (bytes memory) {
        bytes32 h = dao.getVoteHash(proposalId);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, h);
        return abi.encodePacked(r, s, v);
    }

    /// @dev 선택한 키들의 서명을 주소 오름차순으로 정렬해 반환
    function _sigs(uint256 proposalId, uint256[] memory keys) internal view returns (bytes[] memory out) {
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j = i + 1; j < keys.length; ++j) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
            }
        }
        out = new bytes[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            out[i] = _sign(proposalId, keys[i]);
        }
    }

    function _keys3() internal pure returns (uint256[] memory k) {
        k = new uint256[](3);
        k[0] = 1;
        k[1] = 2;
        k[2] = 3;
    }

    function _keys5() internal pure returns (uint256[] memory k) {
        k = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            k[i] = i + 1;
        }
    }

    function _executionHash() internal view returns (bytes32) {
        return keccak256(abi.encode(address(target), 1 ether, bytes("")));
    }

    function _propose() internal returns (uint256 proposalId) {
        proposalId = dao.propose(_executionHash());
    }

    function _timeline(uint256 proposalId)
        internal
        view
        returns (uint48 votingEnds, uint48 executableFrom, uint48 expires)
    {
        (, votingEnds, executableFrom, expires,) = dao.proposals(proposalId);
    }

    function _matured(uint256 proposalId) internal {
        (uint48 ends, uint48 from,) = _timeline(proposalId);
        assertEq(from, ends + DELAY); // 타임락 산수 고정
        vm.warp(uint256(from));
    }

    // ---------------------------------------------------------------- 제안

    function test_propose_opensCommitment() public {
        uint256 id = _propose();
        (bytes32 h, uint48 ends, uint48 from, uint48 expires, bool executed) = dao.proposals(id);
        assertEq(h, _executionHash());
        assertEq(ends, block.timestamp + VOTE_DAYS);
        assertEq(from, ends + DELAY);
        assertEq(expires, from + GRACE);
        assertFalse(executed);
        assertEq(dao.nextProposalId(), id + 1);
        assertEq(uint8(dao.state(id)), 1); // 투표중

        vm.warp(ends - 1);
        assertEq(uint8(dao.state(id)), 1); // 투표 마지막 순간
        vm.warp(ends);
        assertEq(uint8(dao.state(id)), 2); // 경계는 타임락 — 투표 종료
        vm.warp(from - 1);
        assertEq(uint8(dao.state(id)), 2);
        vm.warp(from);
        assertEq(uint8(dao.state(id)), 3); // 실행 가능
        vm.warp(expires + 1);
        assertEq(uint8(dao.state(id)), 5); // 만료
        assertEq(uint8(dao.state(999)), 0); // 없음
    }

    // ---------------------------------------------------------------- 실행

    function test_execute_fullFlow() public {
        uint256 id = _propose();
        bytes[] memory sigs = _sigs(id, _keys3()); // 3인 × 200k = 600k
        _matured(id);

        vm.expectEmit(true, true, true, true);
        emit SimpleDAO.Executed(id, address(target), 1 ether, 3 * (SUPPLY / 5));
        dao.execute(id, address(target), 1 ether, "", sigs);

        assertEq(target.paid(), 1 ether);
        assertEq(address(dao).balance, 99 ether);
        assertEq(uint8(dao.state(id)), 4); // 실행됨
    }

    /// @dev calldata가 있는 실행 — 해시는 정확히 abi.encode(target, value, data)
    function test_execute_withCalldata() public {
        bytes memory data = abi.encodeCall(Counterparty.note, (42));
        uint256 id = dao.propose(keccak256(abi.encode(address(target), 0, data)));
        _matured(id);

        dao.execute(id, address(target), 0, data, _sigs(id, _keys5()));

        assertEq(target.noted(), 42);
        assertEq(target.paid(), 0);
    }

    // ---------------------------------------------------------------- 거부 경로

    function test_execute_reverts() public {
        uint256 id = _propose();
        (uint48 ends, uint48 from,) = _timeline(id);

        // 서명 묶음은 expectRevert보다 먼저 계산 — 인자 평가가
        // "다음 호출" 슬롯을 소비하기 때문이다
        bytes[] memory sigs3 = _sigs(id, _keys3());
        uint256[] memory one = new uint256[](1);
        one[0] = 1;
        bytes[] memory sigs1 = _sigs(id, one);
        uint256[] memory dup = new uint256[](2);
        dup[0] = 1;
        dup[1] = 1;
        bytes[] memory sigsDup = _sigs(id, dup);
        bytes[] memory sigsUnsorted = new bytes[](2);
        // addr(1)=0x7E5F… > addr(4)=0x1efF… — 실제 내림차순 쌍
        sigsUnsorted[0] = _sign(id, 1);
        sigsUnsorted[1] = _sign(id, 4);

        // 타임락 전
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.NotExecutableYet.selector, block.timestamp, from));
        dao.execute(id, address(target), 1 ether, "", sigs3);

        vm.warp(uint256(from));

        // 알 수 없는 제안
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.ProposalNotFound.selector, 999));
        dao.execute(999, address(target), 1 ether, "", sigs3);

        // 해시 불일치 — 다른 value
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.HashMismatch.selector, _executionHash()));
        dao.execute(id, address(target), 2 ether, "", sigs3);

        // 쿼럼 미달 — 1인 200k
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.QuorumNotReached.selector, SUPPLY / 5, QUORUM));
        dao.execute(id, address(target), 1 ether, "", sigs1);

        // 중복 서명 — 같은 키 2회는 recovered 정렬 검사에서 죽는다
        vm.expectRevert(SimpleDAO.InvalidSignature.selector);
        dao.execute(id, address(target), 1 ether, "", sigsDup);

        // 미정렬 제출
        vm.expectRevert(SimpleDAO.InvalidSignature.selector);
        dao.execute(id, address(target), 1 ether, "", sigsUnsorted);

        // 국고 부족 — 해시가 value를 고정하므로 101 ether를 커밋한 별도 제안
        uint256 idBig = dao.propose(keccak256(abi.encode(address(target), 101 ether, bytes(""))));
        (, uint48 bigFrom,) = _timeline(idBig);
        vm.warp(uint256(bigFrom));
        bytes[] memory sigsBig = _sigs(idBig, _keys3());
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.InsufficientTreasury.selector, 101 ether, 100 ether));
        dao.execute(idBig, address(target), 101 ether, "", sigsBig);

        // 정상 실행 후 재실행
        dao.execute(id, address(target), 1 ether, "", sigs3);
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.AlreadyExecuted.selector, id));
        dao.execute(id, address(target), 1 ether, "", sigs3);
    }

    function test_execute_revertsWhenExpired() public {
        uint256 id = _propose();
        (, uint48 from, uint48 expires) = _timeline(id);
        bytes[] memory sigs = _sigs(id, _keys5());
        vm.warp(uint256(expires) + 1);
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.ProposalExpired.selector, block.timestamp, expires));
        dao.execute(id, address(target), 1 ether, "", sigs);
        assertEq(from, expires - GRACE); // 유예 산수 고정
    }

    function test_constructor_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.VotesTokenHasNoCode.selector, address(0xBEEF)));
        new SimpleDAO(guardian, FixedSupplyToken(address(0xBEEF)), QUORUM, 3, 2, 7);

        vm.expectRevert(SimpleDAO.ZeroQuorum.selector);
        new SimpleDAO(guardian, vote, 0, 3, 2, 7);

        vm.expectRevert(SimpleDAO.ZeroPeriod.selector);
        new SimpleDAO(guardian, vote, QUORUM, 0, 2, 7);
    }

    // ---------------------------------------------------------------- 무게는 실행 시점 (문서화된 트레이드오프)

    /// @dev 서명 후 토큰을 팔면 표가 줄어든다 — 실행 시점 잔액 원칙.
    function test_soldTokensLoseWeight() public {
        uint256 id = _propose();
        bytes[] memory sigs = _sigs(id, _keys3()); // 서명 시점 무게 600k
        _matured(id);

        // 유권자 3이 전량 매도 → 실행 시점 무게 400k = 쿼럼과 정확히 같다
        vm.prank(voters[2]);
        vote.transfer(alice, SUPPLY / 5);
        dao.execute(id, address(target), 1 ether, "", sigs); // 400k ≥ 400k 통과
        assertEq(target.paid(), 1 ether);

        // 한 명 더 매도하면 미달 — 서명은 그대로여도 무게가 사라졌다
        uint256 id2 = _propose();
        bytes[] memory sigs2 = _sigs(id2, _keys3());
        _matured(id2);
        vm.prank(voters[1]);
        vote.transfer(alice, SUPPLY / 5);
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.QuorumNotReached.selector, 200_000e18, QUORUM));
        dao.execute(id2, address(target), 1 ether, "", sigs2);
    }

    /// @dev 반대 방향: 제안 공개 후 매수해 단독 쿼럼을 채울 수 있다 —
    ///      체크포인트 상태를 사지 않은 대가 (README·SECURITY 문서화).
    function test_lateAccumulationCanVote() public {
        uint256 id = _propose();
        _matured(id);

        // 고래가 투표 기간 중 시장 매수(유권자 2인에게서 200k씩) 후 단독 서명
        uint256 whaleKey = 0xA11CE;
        address whale = vm.addr(whaleKey);
        vm.prank(voters[0]);
        vote.transfer(whale, SUPPLY / 5);
        vm.prank(voters[1]);
        vote.transfer(whale, SUPPLY / 5);

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(id, whaleKey);
        dao.execute(id, address(target), 1 ether, "", sigs); // 단독 통과 — 알려진 속성
        assertEq(target.paid(), 1 ether);
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev 쿼럼 판정 불변식 — 실행 성공 ⟺ 서명 무게 합 ≥ quorum.
    ///      임의의 유권자 부분집합(키 1..5의 비트마스크)에 대해
    ///      (무게 ≥ quorum) ⟺ execute 성공이 정확히 대응한다.
    function test_fuzz_quorumIffWeight(uint8 subsetSeed) public {
        uint256 id = _propose();
        _matured(id);

        uint256 mask = bound(subsetSeed, 1, 31); // 최소 1인
        uint256[] memory keys = new uint256[](5);
        uint256 n;
        for (uint256 i; i < 5; ++i) {
            if (mask & (1 << i) != 0) {
                keys[n] = i + 1;
                ++n;
            }
        }
        assembly {
            mstore(keys, n) // 실제 크기로 축소
        }

        uint256 weight = n * (SUPPLY / 5); // 균등 분배 fixture
        bytes[] memory sigs = _sigs(id, keys);

        if (weight >= QUORUM) {
            dao.execute(id, address(target), 1 ether, "", sigs);
            assertEq(target.paid(), 1 ether);
        } else {
            vm.expectRevert(abi.encodeWithSelector(SimpleDAO.QuorumNotReached.selector, weight, QUORUM));
            dao.execute(id, address(target), 1 ether, "", sigs);
        }
    }

    // ---------------------------------------------------------------- brake

    /// @dev guardian은 새 제안만 막는다 — 진행 중 제안의 실행(국고 지출)은
    ///      brake 하에서도 열려 있다. 실행을 막으면 자금이 잠긴다.
    function test_brake_blocksProposalsNotExecution() public {
        uint256 id = _propose();
        bytes[] memory sigs = _sigs(id, _keys3());
        _matured(id);

        vm.prank(guardian);
        dao.engageBrake(1);

        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        dao.propose(bytes32(uint256(1)));

        dao.execute(id, address(target), 1 ether, "", sigs); // 실행은 개방
        assertEq(target.paid(), 1 ether);
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/dao/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r) = StateMeter.measureDeploy(
            abi.encodePacked(
                type(SimpleDAO).creationCode,
                abi.encode(guardian, vote, QUORUM, uint48(VOTE_DAYS), uint48(DELAY), uint48(GRACE))
            )
        );
        emit log_named_uint("daoDeploy gasUsed", r.gasUsed);
        emit log_named_uint("daoDeploy codeBytes", r.codeBytes);
        emit log_named_uint("daoDeploy stateUnits", r.stateUnits);
    }

    function test_meter_lifecycle() public {
        address[] memory tracked = new address[](1);
        tracked[0] = address(dao);

        StateMeter.Result memory r1 =
            StateMeter.measureCall(alice, tracked, address(dao), abi.encodeCall(dao.propose, (_executionHash())));
        emit log_named_uint("propose gasUsed", r1.gasUsed);
        emit log_named_uint("propose newSlots", r1.newSlots);
        emit log_named_uint("propose logBytes", r1.logBytes);
        emit log_named_uint("propose stateUnits", r1.stateUnits);

        uint256 id = dao.nextProposalId() - 1;
        _matured(id);
        bytes[] memory sigs = _sigs(id, _keys5());

        StateMeter.Result memory r2 = StateMeter.measureCall(
            alice, tracked, address(dao), abi.encodeCall(dao.execute, (id, address(target), 1 ether, "", sigs))
        );
        emit log_named_uint("execute5sigs gasUsed", r2.gasUsed);
        emit log_named_uint("execute5sigs newSlots", r2.newSlots);
        emit log_named_uint("execute5sigs logBytes", r2.logBytes);
        emit log_named_uint("execute5sigs stateUnits", r2.stateUnits);
    }
}
