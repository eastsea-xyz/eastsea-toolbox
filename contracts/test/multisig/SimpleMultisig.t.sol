// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleMultisig} from "src/multisig/SimpleMultisig.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 8 — 단순 멀티시그 테스트.
/// @dev fixture: 소유자 5명(고정 키 1..5) 중 임계치 3. 서명은 항상
///      주소 오름차순으로 제출한다 (컨트랙트 강제 사항).
contract SimpleMultisigTest is Test {
    uint256 internal constant N = 5;
    uint256 internal constant THRESHOLD = 3;

    SimpleMultisig internal ms;
    FixedSupplyToken internal token;

    /// @dev 정렬된 소유자 주소 — 인덱스 = 서명 순서
    address[N] internal owners;
    /// @dev 주소 → 개인키 (서명 생성용)
    mapping(address => uint256) internal keyOf;

    address internal alice = makeAddr("alice"); // 수신자/relayer

    function setUp() public {
        // 키 1..5로 주소 생성 후 주소순 정렬 — 서명 검증 규칙과 동일
        address[N] memory addrs;
        uint256[N] memory keys = [uint256(1), 2, 3, 4, 5];
        for (uint256 i; i < N; ++i) {
            addrs[i] = vm.addr(keys[i]);
            keyOf[addrs[i]] = keys[i];
        }
        // 선택 정렬 (5개라 성능 무의미)
        for (uint256 i; i < N; ++i) {
            for (uint256 j = i + 1; j < N; ++j) {
                if (addrs[j] < addrs[i]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                }
            }
        }
        owners = addrs;

        ms = new SimpleMultisig(_asArray(owners), THRESHOLD);
        token = new FixedSupplyToken("Isle Coin", "ISLE", 10_000_000e18, alice);
        vm.deal(address(ms), 10 ether);
        deal(address(token), address(ms), 1_000e18);
    }

    // ---------------------------------------------------------------- 헬퍼

    function _asArray(address[N] memory src) internal pure returns (address[] memory out) {
        out = new address[](N);
        for (uint256 i; i < N; ++i) {
            out[i] = src[i];
        }
    }

    /// @dev 선택 인덱스(오름차순)의 소유자들이 서명한 묶음을 만든다.
    function _sigs(uint256 a, uint256 b, uint256 c) internal view returns (bytes[] memory) {
        bytes32 h = ms.getTransactionHash(alice, 1 ether, "", 1);
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _sign(keyOf[owners[a]], h);
        sigs[1] = _sign(keyOf[owners[b]], h);
        sigs[2] = _sign(keyOf[owners[c]], h);
        return sigs;
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev 표준 송금 tx — (alice, 1 ether, "", nonce 1) 서명 3개.
    function _sendTx() internal returns (bytes memory) {
        return ms.execute(alice, 1 ether, "", 1, _sigs(0, 1, 2));
    }

    // ---------------------------------------------------------------- 생성자

    function test_constructor_reverts() public {
        address[] memory five = _asArray(owners);
        vm.expectRevert(abi.encodeWithSelector(SimpleMultisig.OwnerCountMismatch.selector, 5, 6));
        new SimpleMultisig(five, 6);

        address[] memory zero = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(SimpleMultisig.OwnerCountMismatch.selector, 0, 0));
        new SimpleMultisig(zero, 0);

        // 미정렬 + 중복
        address[] memory bad = new address[](3);
        bad[0] = owners[1];
        bad[1] = owners[0];
        bad[2] = owners[2];
        vm.expectRevert(SimpleMultisig.OwnersNotSorted.selector);
        new SimpleMultisig(bad, 2);

        bad[0] = owners[0];
        bad[1] = owners[0]; // 중복
        vm.expectRevert(SimpleMultisig.OwnersNotSorted.selector);
        new SimpleMultisig(bad, 2);

        address[] memory withZero = new address[](2);
        withZero[0] = address(0);
        withZero[1] = owners[1];
        vm.expectRevert(SimpleMultisig.OwnersNotSorted.selector);
        new SimpleMultisig(withZero, 1);
    }

    function test_constructor_storesOwners() public {
        for (uint256 i; i < N; ++i) {
            assertTrue(ms.isOwner(owners[i]));
        }
        assertFalse(ms.isOwner(alice));
        assertEq(ms.threshold(), THRESHOLD);
    }

    // ---------------------------------------------------------------- 실행

    function test_execute_sendsNative() public {
        uint256 before = alice.balance;
        _sendTx();
        assertEq(alice.balance, before + 1 ether);
        assertEq(address(ms).balance, 9 ether);
    }

    /// @dev 임의 호출 — multisig 보유 토큰의 transfer를 실행한다.
    function test_execute_arbitraryCall() public {
        bytes memory data = abi.encodeCall(token.transfer, (alice, 400e18));
        bytes32 h = ms.getTransactionHash(address(token), 0, data, 7);
        uint256[3] memory pick = [uint256(0), 2, 4];
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            sigs[i] = _sign(keyOf[owners[pick[i]]], h);
        }
        ms.execute(address(token), 0, data, 7, sigs);
        assertEq(token.balanceOf(alice), 10_000_000e18 + 400e18); // 민트분 + 이체
        assertEq(token.balanceOf(address(ms)), 600e18);
    }

    /// @dev relayer는 누구든 — 소유자 아닌 alice가 제출해도 실행된다.
    function test_execute_anyoneCanRelay() public {
        vm.prank(alice);
        _sendTx();
        assertEq(alice.balance, 1 ether);
    }

    /// @dev 대상이 실패하면 전체가 revert — 조용한 실패 없음.
    function test_execute_revertWhenTargetFails() public {
        bytes memory data = abi.encodeCall(token.transfer, (alice, 5_000e18)); // 잔액 1_000 초과
        bytes32 h = ms.getTransactionHash(address(token), 0, data, 1);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            sigs[i] = _sign(keyOf[owners[i]], h);
        }
        vm.expectRevert();
        ms.execute(address(token), 0, data, 1, sigs);
        assertEq(token.balanceOf(address(ms)), 1_000e18); // 자금 보존
    }

    // ---------------------------------------------------------------- 서명 검증

    function test_execute_belowThreshold() public {
        bytes32 h = ms.getTransactionHash(alice, 1 ether, "", 1);
        bytes[] memory two = new bytes[](2);
        two[0] = _sign(keyOf[owners[0]], h);
        two[1] = _sign(keyOf[owners[1]], h);
        vm.expectRevert(abi.encodeWithSelector(SimpleMultisig.InsufficientConfirmations.selector, 2, 3));
        ms.execute(alice, 1 ether, "", 1, two);
    }

    function test_execute_duplicateSignatureRejected() public {
        bytes32 h = ms.getTransactionHash(alice, 1 ether, "", 1);
        bytes[] memory dup = new bytes[](3);
        dup[0] = _sign(keyOf[owners[0]], h);
        dup[1] = _sign(keyOf[owners[0]], h); // 같은 사람 2회
        dup[2] = _sign(keyOf[owners[1]], h);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        ms.execute(alice, 1 ether, "", 1, dup);
        assertEq(alice.balance, 0); // 실행 안 됨
    }

    function test_execute_unsortedSignaturesRejected() public {
        bytes32 h = ms.getTransactionHash(alice, 1 ether, "", 1);
        bytes[] memory unsorted = new bytes[](3);
        unsorted[0] = _sign(keyOf[owners[2]], h); // 내림차순
        unsorted[1] = _sign(keyOf[owners[1]], h);
        unsorted[2] = _sign(keyOf[owners[0]], h);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        ms.execute(alice, 1 ether, "", 1, unsorted);
    }

    function test_execute_nonOwnerSignatureRejected() public {
        bytes32 h = ms.getTransactionHash(alice, 1 ether, "", 1);
        uint256 strangerKey = 0xBAD;
        bytes[] memory mixed = new bytes[](3);
        mixed[0] = _sign(keyOf[owners[0]], h);
        mixed[1] = _sign(strangerKey, h); // 비소유자 — 스킵이 아니라 전체 거부
        mixed[2] = _sign(keyOf[owners[2]], h);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        ms.execute(alice, 1 ether, "", 1, mixed);
    }

    function test_execute_tamperedSignatureRejected() public {
        bytes32 h = ms.getTransactionHash(alice, 1 ether, "", 1);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            sigs[i] = _sign(keyOf[owners[i]], h);
        }
        sigs[1][64] = bytes1(uint8(uint256(uint8(sigs[1][64])) ^ 1)); // v 비트 반전
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        ms.execute(alice, 1 ether, "", 1, sigs);
    }

    /// @dev 해시가 달라지면(내용 위조) 서명은 무효.
    function test_execute_wrongPayloadRejected() public {
        bytes[] memory sigs = _sigs(0, 1, 2); // (alice, 1 ether, "", 1)에 서명
        // 같은 서명으로 다른 수신자·금액 실행 시도
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        ms.execute(address(0xBEEF), 2 ether, "", 1, sigs);
    }

    // ---------------------------------------------------------------- 재생 방지

    /// @dev CEI 증명 — executed 슬롯이 call보다 먼저 기록된다.
    ///      같은 tx의 두 번째 실행(재진입 포함)은 AlreadyExecuted로 죽는다.
    function test_execute_replayRejected() public {
        _sendTx();
        bytes[] memory sigs = _sigs(0, 1, 2);
        vm.expectRevert(SimpleMultisig.AlreadyExecuted.selector);
        ms.execute(alice, 1 ether, "", 1, sigs);
        assertEq(alice.balance, 1 ether); // 한 번만 지급
    }

    /// @dev nonce를 바꾸면 다른 해시 — 재발의 합법 경로.
    function test_execute_newNonceIsNewTransaction() public {
        bytes32 h = ms.getTransactionHash(alice, 1 ether, "", 2);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            sigs[i] = _sign(keyOf[owners[i]], h);
        }
        ms.execute(alice, 1 ether, "", 2, sigs);
        assertEq(alice.balance, 1 ether); // nonce 2 실행 1회
    }

    /// @dev 도메인 분리 — 다른 multisig 인스턴스의 서명은 쓸 수 없다.
    function test_execute_crossInstanceRejected() public {
        SimpleMultisig other = new SimpleMultisig(_asArray(owners), THRESHOLD);
        vm.deal(address(other), 10 ether);
        // ms의 tx에 서명했지만 other에서 실행 시도 — domainSeparator가 다르다
        bytes[] memory sigs = _sigs(0, 1, 2);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        other.execute(alice, 1 ether, "", 1, sigs);
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev 임의의 3인 부분집합(주소순 정렬)이면 언제나 실행된다 —
    ///      임계치가 "누구 3명"이 아니라 "3인의 정족수"임의 검증.
    function test_fuzz_anyQuorumExecutes(uint8 seed) public {
        uint256 a = uint256(seed) % N;
        uint256 b = uint256(seed / N) % N;
        uint256 c = uint256(seed / (N * N)) % N;
        vm.assume(a != b && b != c && a != c);

        // 주소 오름차순으로 정렬된 (a,b,c)
        uint256[3] memory pick = [a, b, c];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (owners[pick[j]] < owners[pick[i]]) {
                    (pick[i], pick[j]) = (pick[j], pick[i]);
                }
            }
        }

        bytes32 h = ms.getTransactionHash(alice, 1 ether, "", 1);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            sigs[i] = _sign(keyOf[owners[pick[i]]], h);
        }
        ms.execute(alice, 1 ether, "", 1, sigs);
        assertEq(alice.balance, 1 ether);
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/multisig/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r) = StateMeter.measureDeploy(
            abi.encodePacked(type(SimpleMultisig).creationCode, abi.encode(_asArray(owners), THRESHOLD))
        );
        emit log_named_uint("multisigDeploy gasUsed", r.gasUsed);
        emit log_named_uint("multisigDeploy codeBytes", r.codeBytes);
        emit log_named_uint("multisigDeploy stateUnits", r.stateUnits);
    }

    function test_meter_execute() public {
        bytes32 h = ms.getTransactionHash(alice, 1 ether, "", 1);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            sigs[i] = _sign(keyOf[owners[i]], h);
        }

        address[] memory tracked = new address[](1);
        tracked[0] = address(ms);
        StateMeter.Result memory r = StateMeter.measureCall(
            alice, tracked, address(ms), abi.encodeCall(ms.execute, (alice, 1 ether, "", 1, sigs))
        );
        emit log_named_uint("execute gasUsed", r.gasUsed);
        emit log_named_uint("execute newSlots", r.newSlots);
        emit log_named_uint("execute logBytes", r.logBytes);
        emit log_named_uint("execute stateUnits", r.stateUnits);
    }
}
