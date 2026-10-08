// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "openzeppelin/utils/cryptography/SignatureChecker.sol";

/// @title 예제 8 — 단순 멀티시그 (K-of-N)
/// @notice EOA·ERC-1271 소유자의 서명 또는 직접 승인이 임계치를 채우면
///         누구나 트랜잭션을 실행할 수 있는 정적 소유자 멀티시그.
/// @dev
///  설계 결정 — 유료 상태 최소화:
///   - 오프체인 서명 경로는 executed[hash] 슬롯 1개만 남긴다.
///     오프체인 서명이 불가능한 지갑은 approve로 추가 슬롯을 쓴다.
///   - 소유자 주소의 오름차순·고유 정렬이 중복 카운팅을 막는다.
///   - 소유자 목록은 정적이다. 교체는 멀티시그가 새 multisig를
///     배포해 잔액을 옮기는 방식 — 변경 로직 자체가 공격면이 된다.
///
///  EIP-712 해시는 nonce·deadline·현재 chainId·자기 주소를 포함한다.
///  nonce는 순차 카운터가 아닌 임의 작업 식별자이며 전체 해시가 1회 실행된다.
///
///  F 매핑:
///   F-01: executed[hash]를 ERC-1271 staticcall과 대상 call 전에 기록(CEI).
///         같은 해시의 재진입은 AlreadyExecuted로 거부한다.
///   F-02: 토큰 전송은 data 필드의 임의 호출로 처리 — 멀티시그 자체는
///         토큰 회계를 갖지 않아 좌초 문제가 없다.
///   F-03: 대상 call은 EOA 송금(value>0, data 빈)도 정상 처리한다.
///   F-04: getTransactionHash 상수 시간.
///   F-05: 코드가 있는 소유자는 SignatureChecker의 ERC-1271 경로를 따른다.
contract SimpleMultisig is EIP712 {
    bytes32 public constant TRANSACTION_TYPEHASH =
        keccak256("Transaction(address to,uint256 value,bytes data,uint256 nonce,uint256 deadline)");

    uint256 public immutable threshold;

    mapping(address => bool) public isOwner;

    /// @dev 오프체인 서명 경로의 실행당 상태 증가는 이 1슬롯뿐이다.
    mapping(bytes32 => bool) public executed;

    /// @dev 직접 승인만 소유자·해시별 유료 상태를 추가한다.
    mapping(bytes32 => mapping(address => bool)) public approvals;

    error ZeroThreshold();
    error OwnerCountMismatch(uint256 owners, uint256 threshold);
    error OwnersNotSorted();
    error ZeroAddress();
    error InvalidSignature();
    error AlreadyExecuted();
    error InsufficientConfirmations(uint256 got, uint256 want);
    error ExecutionFailed(bytes ret);
    error NotOwner();
    error TransactionExpired(uint256 deadline);

    event Executed(bytes32 indexed txHash, address indexed to, uint256 value, uint256 nonce, uint256 confirmations);
    event Approved(bytes32 indexed txHash, address indexed owner);

    constructor(address[] memory owners_, uint256 threshold_) EIP712("EastSeaSimpleMultisig", "2") {
        uint256 n = owners_.length;
        if (threshold_ == 0 || threshold_ > n) revert OwnerCountMismatch(n, threshold_);
        if (n == 0) revert ZeroThreshold();

        address last = address(0);
        for (uint256 i; i < n; ++i) {
            address o = owners_[i];
            if (o == address(0) || o <= last) revert OwnersNotSorted(); // 고유+정렬 강제
            isOwner[o] = true;
            last = o;
        }

        threshold = threshold_;
    }

    /// @notice 이후 승인된 지급에 쓸 native 자금을 받는다.
    receive() external payable {}

    // ---------------------------------------------------------------- 실행

    /// @notice 기존 EOA 서명 배열 API. 현재 서명 대상은 EIP-712이며
    ///         deadline은 uint256 최대값이다. 계약 소유자는 executeWithSigners를 쓴다.
    /// @param to         호출 대상
    /// @param value      함께 보낼 native coin
    /// @param data       호출 데이터 (토큰 transfer, 배포, 무엇이든)
    /// @param nonce      서명 시점에 지정한 값 — 재실행 방지 식별자
    /// @param signatures 복구된 소유자 주소 기준 오름차순 EOA 서명 배열
    function execute(address to, uint256 value, bytes calldata data, uint256 nonce, bytes[] calldata signatures)
        external
        returns (bytes memory)
    {
        bytes32 h = _consume(to, value, data, nonce, type(uint256).max);
        uint256 confirmations = _checkRecoveredSignatures(h, signatures);
        emit Executed(h, to, value, nonce, confirmations);
        return _callTarget(to, value, data);
    }

    /// @notice EOA·ERC-1271 서명과 직접 승인을 함께 제출한다 (만료 없음).
    function executeWithSigners(
        address to,
        uint256 value,
        bytes calldata data,
        uint256 nonce,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external returns (bytes memory) {
        return _executeWithSigners(to, value, data, nonce, type(uint256).max, signers, signatures);
    }

    /// @notice 각 signer는 오름차순·고유 소유자여야 한다. 비어 있지 않은
    ///         서명은 SignatureChecker로 검증하고 빈 서명은 직접 승인을 요구한다.
    function executeWithSigners(
        address to,
        uint256 value,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external returns (bytes memory) {
        return _executeWithSigners(to, value, data, nonce, deadline, signers, signatures);
    }

    /// @notice 소유자 자신의 트랜잭션으로 승인한다 (만료 없음).
    function approve(address to, uint256 value, bytes calldata data, uint256 nonce) external {
        _approve(to, value, data, nonce, type(uint256).max);
    }

    /// @notice 오프체인 서명이 불가능한 소유자도 계정 호출로 승인할 수 있다.
    function approve(address to, uint256 value, bytes calldata data, uint256 nonce, uint256 deadline) external {
        _approve(to, value, data, nonce, deadline);
    }

    // ---------------------------------------------------------------- 뷰 (F-04)

    /// @notice 현재 체인의 EIP-712 도메인 — 포크 시 chainId 변경도 반영한다.
    function domainSeparator() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice EIP-712 Transaction 해시 (deadline은 uint256 최대값).
    function getTransactionHash(address to, uint256 value, bytes calldata data, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return getTransactionHash(to, value, data, nonce, type(uint256).max);
    }

    /// @notice 서명과 직접 승인이 공유하는 EIP-712 Transaction 해시.
    function getTransactionHash(address to, uint256 value, bytes calldata data, uint256 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(TRANSACTION_TYPEHASH, to, value, keccak256(data), nonce, deadline))
        );
    }

    // ---------------------------------------------------------------- 내부

    function _executeWithSigners(
        address to,
        uint256 value,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline,
        address[] calldata signers,
        bytes[] calldata signatures
    ) private returns (bytes memory) {
        bytes32 h = _consume(to, value, data, nonce, deadline);
        uint256 confirmations = _checkSignatures(h, signers, signatures);
        emit Executed(h, to, value, nonce, confirmations);
        return _callTarget(to, value, data);
    }

    function _approve(address to, uint256 value, bytes calldata data, uint256 nonce, uint256 deadline) private {
        if (!isOwner[msg.sender]) revert NotOwner();
        if (block.timestamp > deadline) revert TransactionExpired(deadline);
        bytes32 h = getTransactionHash(to, value, data, nonce, deadline);
        if (executed[h]) revert AlreadyExecuted();
        approvals[h][msg.sender] = true;
        emit Approved(h, msg.sender);
    }

    function _consume(address to, uint256 value, bytes calldata data, uint256 nonce, uint256 deadline)
        private
        returns (bytes32 h)
    {
        if (block.timestamp > deadline) revert TransactionExpired(deadline);
        h = getTransactionHash(to, value, data, nonce, deadline);
        if (executed[h]) revert AlreadyExecuted();
        executed[h] = true; // CEI; 검증·대상 실패 시 전체 기록은 롤백된다.
    }

    function _callTarget(address to, uint256 value, bytes calldata data) private returns (bytes memory) {
        (bool ok, bytes memory retData) = to.call{value: value}(data);
        if (!ok) revert ExecutionFailed(retData);
        return retData;
    }

    /// @dev 기존 배열 API도 OZ의 low-s·v 검사와 ERC-1271 분기를 따른다.
    function _checkRecoveredSignatures(bytes32 h, bytes[] calldata signatures) private view returns (uint256 count) {
        address last = address(0);
        uint256 n = signatures.length;
        if (n < threshold) revert InsufficientConfirmations(n, threshold);

        for (uint256 i; i < n; ++i) {
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(h, signatures[i]);
            if (
                err != ECDSA.RecoverError.NoError || recovered <= last || !isOwner[recovered]
                    || !SignatureChecker.isValidSignatureNow(recovered, h, signatures[i])
            ) revert InvalidSignature();
            last = recovered;
            ++count;
        }
    }

    function _checkSignatures(bytes32 h, address[] calldata signers, bytes[] calldata signatures)
        private
        view
        returns (uint256 count)
    {
        uint256 n = signers.length;
        if (n != signatures.length) revert InvalidSignature();
        if (n < threshold) revert InsufficientConfirmations(n, threshold);
        address last = address(0);
        for (uint256 i; i < n; ++i) {
            address signer = signers[i];
            if (signer <= last || !isOwner[signer]) revert InvalidSignature();
            bool valid = signatures[i].length == 0
                ? approvals[h][signer]
                : SignatureChecker.isValidSignatureNow(signer, h, signatures[i]);
            if (!valid) revert InvalidSignature();
            last = signer;
            ++count;
        }
    }
}
