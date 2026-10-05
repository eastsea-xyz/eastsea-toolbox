// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MerkleAirdrop} from "src/airdrop/MerkleAirdrop.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 13 — 머클 에어드랍 테스트.
/// @dev fixture: 4인 명단(1·2·4·8 ether)의 완전 이진 머클 트리를
///      직접 계산한다. 리프 = keccak256(abi.encodePacked(account, amount)),
///      형제쌍은 정렬 후 결합한다 (OZ 표준).
contract MerkleAirdropTest is Test {
    MerkleAirdrop internal drop;

    address internal distributor = makeAddr("distributor");

    uint48 internal constant PERIOD = 30 days;
    uint256 internal constant TOTAL = 15 ether; // 명단 합

    address[4] internal users;
    address internal u0 = makeAddr("user0");
    address internal u1 = makeAddr("user1");
    address internal u2 = makeAddr("user2");
    address internal u3 = makeAddr("user3");

    bytes32 internal root;
    bytes32[4] internal leaves;
    /// @dev proofs[i][j]: 리프 i의 j번째 증명 형제
    bytes32[2][4] internal proofs;

    function setUp() public {
        users = [u0, u1, u2, u3];
        for (uint256 i; i < 4; ++i) {
            leaves[i] = keccak256(abi.encodePacked(users[i], _amountOf(i)));
        }

        // 레벨 1 — 형제쌍 정렬 결합
        bytes32 n01 = _parent(leaves[0], leaves[1]);
        bytes32 n23 = _parent(leaves[2], leaves[3]);
        root = _parent(n01, n23);

        proofs[0][0] = leaves[1];
        proofs[0][1] = n23;
        proofs[1][0] = leaves[0];
        proofs[1][1] = n23;
        proofs[2][0] = leaves[3];
        proofs[2][1] = n01;
        proofs[3][0] = leaves[2];
        proofs[3][1] = n01;

        drop = new MerkleAirdrop(root, distributor, PERIOD);
        vm.deal(address(drop), TOTAL); // 풀 충전
    }

    /// @dev 명단 금액 — 1, 2, 4, 8 ether
    function _amountOf(uint256 i) internal pure returns (uint256) {
        return 1 ether << i;
    }

    function _parent(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proofOf(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = proofs[i][0];
        p[1] = proofs[i][1];
    }

    // ---------------------------------------------------------------- 청구

    function test_claim_paysCommittedAmount() public {
        vm.expectEmit(true, true, true, true);
        emit MerkleAirdrop.Claimed(u2, 4 ether);
        vm.prank(u2);
        drop.claim(4 ether, _proofOf(2));

        assertEq(u2.balance, 4 ether);
        assertTrue(drop.claimed(u2));
        assertEq(drop.totalClaimed(), 4 ether);
        assertFalse(drop.claimed(u0)); // 남은 명단은 무관
    }

    /// @dev 다른 금액·남의 증명으로는 자격이 없다 — 리프가 주소+금액으로 묶인다
    function test_claim_rejectsWrongLeaf() public {
        vm.prank(u0);
        vm.expectRevert(MerkleAirdrop.InvalidProof.selector);
        drop.claim(2 ether, _proofOf(0)); // 증명은 u0 것이지만 금액이 다르다

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(MerkleAirdrop.InvalidProof.selector);
        drop.claim(8 ether, _proofOf(3)); // u3의 증명을 그대로 제출
    }

    function test_claim_reverts() public {
        // 이중 청구
        vm.startPrank(u1);
        drop.claim(2 ether, _proofOf(1));
        vm.expectRevert(MerkleAirdrop.AlreadyClaimed.selector);
        drop.claim(2 ether, _proofOf(1));
        vm.stopPrank();

        // 조작된 증명 — 두 번째 노드 교체
        bytes32[] memory badProof = new bytes32[](2);
        badProof[0] = proofs[0][0];
        badProof[1] = bytes32(uint256(1));
        vm.prank(u0);
        vm.expectRevert(MerkleAirdrop.InvalidProof.selector);
        drop.claim(1 ether, badProof);

        // 풀 부족 — 50 ether 단일 리프 트리에 10 ether만 충전
        bytes32 bigLeaf = keccak256(abi.encodePacked(u0, uint256(50 ether)));
        bytes32 n23 = _parent(leaves[2], leaves[3]);
        bytes32 bigRoot = _parent(_parent(bigLeaf, leaves[1]), n23);
        MerkleAirdrop small = new MerkleAirdrop(bigRoot, distributor, PERIOD);
        vm.deal(address(small), 10 ether);
        bytes32[] memory bigProof = new bytes32[](2);
        bigProof[0] = leaves[1];
        bigProof[1] = n23;
        vm.prank(u0);
        vm.expectRevert(abi.encodeWithSelector(MerkleAirdrop.InsufficientPool.selector, 50 ether, 10 ether));
        small.claim(50 ether, bigProof);

        // 마감 후 청구 — 기대 데이터는 prank 전에 계산 (정적 호출이
        // prank를 소비한다)
        bytes memory closed =
            abi.encodeWithSelector(MerkleAirdrop.ClaimClosed.selector, drop.deadline() + 1, drop.deadline());
        vm.warp(drop.deadline() + 1);
        vm.prank(u3);
        vm.expectRevert(closed);
        drop.claim(8 ether, _proofOf(3));
    }

    function test_constructor_reverts() public {
        vm.expectRevert(MerkleAirdrop.ZeroRoot.selector);
        new MerkleAirdrop(bytes32(0), distributor, PERIOD);

        vm.expectRevert(MerkleAirdrop.ZeroDistributor.selector);
        new MerkleAirdrop(root, address(0), PERIOD);

        vm.expectRevert(MerkleAirdrop.DeadlineTooShort.selector);
        new MerkleAirdrop(root, distributor, 0);
    }

    // ---------------------------------------------------------------- 회수

    /// @dev 마감 후 잔여는 distributor에게 — 청구분을 뺀 정확한 차액
    function test_sweep_afterDeadline() public {
        vm.prank(u0);
        drop.claim(1 ether, _proofOf(0));
        vm.prank(u3);
        drop.claim(8 ether, _proofOf(3));

        vm.warp(block.timestamp + PERIOD + 1);
        drop.sweep(); // 누구나 — 수령인은 distributor

        assertEq(distributor.balance, TOTAL - 9 ether); // 미청구 6 ether
        assertEq(address(drop).balance, 0);
    }

    function test_sweep_revertsBeforeDeadline() public {
        // 경계 포함 — deadline 시각에는 아직 닫혀 있다 (<=)
        uint256 until = drop.deadline();
        bytes memory early = abi.encodeWithSelector(MerkleAirdrop.SweepTooEarly.selector, until - 1, until);
        vm.warp(until - 1);
        vm.expectRevert(early);
        drop.sweep();

        bytes memory boundary = abi.encodeWithSelector(MerkleAirdrop.SweepTooEarly.selector, until, until);
        vm.warp(until);
        vm.expectRevert(boundary);
        drop.sweep();
    }

    // ---------------------------------------------------------------- 불변식

    /// @dev 자금 보존 — 임의의 명단 부분집합이 마감 전에 청구하면
    ///      지급 합 + sweep 잔여 == 초기 풀 (정확한 등식).
    function test_fuzz_conservation(uint8 subsetSeed) public {
        uint256 mask = bound(subsetSeed, 0, 15); // 4인 전 부분집합
        uint256 expectPaid;

        for (uint256 i; i < 4; ++i) {
            if (mask & (1 << i) != 0) {
                vm.startPrank(users[i]);
                drop.claim(_amountOf(i), _proofOf(i));
                vm.stopPrank();
                expectPaid += _amountOf(i);
            }
        }
        assertEq(drop.totalClaimed(), expectPaid); // 스칼라 집계 정확

        vm.warp(block.timestamp + PERIOD + 1);
        drop.sweep();
        assertEq(expectPaid + distributor.balance, TOTAL); // I1: 보존
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/airdrop/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r) = StateMeter.measureDeploy(
            abi.encodePacked(type(MerkleAirdrop).creationCode, abi.encode(root, distributor, PERIOD))
        );
        emit log_named_uint("dropDeploy gasUsed", r.gasUsed);
        emit log_named_uint("dropDeploy codeBytes", r.codeBytes);
        emit log_named_uint("dropDeploy stateUnits", r.stateUnits);
    }

    function test_meter_lifecycle() public {
        address[] memory tracked = new address[](1);
        tracked[0] = address(drop);

        bytes32[] memory p0 = _proofOf(0);
        StateMeter.Result memory r1 =
            StateMeter.measureCall(u0, tracked, address(drop), abi.encodeCall(drop.claim, (1 ether, p0)));
        emit log_named_uint("claim gasUsed", r1.gasUsed);
        emit log_named_uint("claim newSlots", r1.newSlots);
        emit log_named_uint("claim logBytes", r1.logBytes);
        emit log_named_uint("claim stateUnits", r1.stateUnits);

        vm.warp(block.timestamp + PERIOD + 1);
        StateMeter.Result memory r2 = StateMeter.measureCall(u1, tracked, address(drop), abi.encodeCall(drop.sweep, ()));
        emit log_named_uint("sweep gasUsed", r2.gasUsed);
        emit log_named_uint("sweep newSlots", r2.newSlots);
        emit log_named_uint("sweep logBytes", r2.logBytes);
        emit log_named_uint("sweep stateUnits", r2.stateUnits);
    }
}
