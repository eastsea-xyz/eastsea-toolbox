// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";
import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "openzeppelin/utils/cryptography/SignatureChecker.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";

/// @title 예제 11 — 단순 DAO (가중 투표 + 타임락 실행)
/// @notice 투표권 토큰 보유량을 무게로 하는 제안-실행 거버넌스.
///         EIP-712 서명(EOA/ERC-1271) 또는 계정의 직접 vote로 승인하고,
///         쿼럼을 넘은 제안은 타임락 창구가 열리면 누구나 실행한다.
/// @dev
///  설계 결정 — 서명 투표 1건당 상태 0슬롯:
///   - 유권자는 EIP-712 제안 해시에 서명해 오프체인으로 전달하고,
///     실행자가 서명 묶음을 한 번에 제출한다. 서명 경로는 제안
///     2슬롯만 남기며, 직접 vote 경로는 유권자·제안당 1슬롯을 쓴다.
///   - 온체인 투표 모델(Governor 계열)은 유권자당 1슬롯씩 쌓는다 —
///     참여 1만 명이면 100만 units. 유료 상태 체인에서 그 값은
///     국고(모든 보유자)가 낸다. 여기서 서명 수집 비용은 제출자가
///     오프체인에서 진다.
///   - 제안은 실행 내용의 해시만 커밋한다(executionHash). calldata를
///     스토리지에 저장하지 않는다 — 전문은 오프체인 공개(포럼·IPFS),
///     체인은 약속과 증명만 보관한다.
///
///  무게는 실행 시점 잔액이다 (교환 가능한 트레이드오프):
///   - 체크포인트 토큰(이전 블록 잔액 조회)은 투표 시점 지분을 정확히
///     고정하지만 계좌당 슬롯을 지속적으로 쌓는다.
///   - 이 예제는 balanceOf(실행 시점)를 무게로 쓴다. 서명 후 토큰을
///     팔면 그 표는 줄고, 투표 기간 중 매수하면 늘어난다. 타임락 창구
///     (votingEnds → executableFrom)가 이 이동을 관찰할 시간이다.
///
///  타임락의 역할:
///   - 쿼럼이 확인된 뒤에도 즉시 실행하지 않는다. 반대 투표자가
///     토큰을 델거나 프로토콜 측 대응을 준비할 exit 창구다.
///   - 고전 Governor+Timelock 두 컨트랙트를 하나로 합쳤다 — 실행
///     권한이 이미 "쿼럼 서명 보유자"로 좁혀져 있어 별도 관리자
///     컨트랙트가 추가하는 보증이 없다.
///
///  F 매핑:
///   F-01: executed 플래그를 외부 호출보다 먼저 올린다(CEI) +
///         nonReentrant. 국고 native 전송도 같은 경로.
///   F-02: 투표권 토큰은 FoT면 안 된다 — balanceOf 기반 무게가
///         왜곡된다. 배포 시 code 존재만 검사 가능하므로 README가
///         요구사항을 명시한다.
///   F-03: 국고는 native만 직접 받는다(receive 허용 — 기부·자금).
///   F-04: state/getVoteHash 상수 시간. 투표 검증은 실행 calldata
///         길이에 비례 — 상태 크기와 무관하다.
///   F-05: code가 있는 계정은 ERC-1271 정책을 따른다(7702 포함).
///   F-06: propose는 누구나(F-07과 구분). quorum·기간은 immutable.
///   F-07: Proposed 이벤트 ≠ 유효 제안 — 진실은 proposals 매핑이다.
///   F-08: 무작위성 없음.
contract SimpleDAO is SimpleBrake, ReentrancyGuard, EIP712 {
    /// @custom:member executionHash  keccak256(abi.encode(target, value, data)) — 제안이 커밋한 행동
    /// @custom:member votingEnds     투표 종료 (제안 시각 + votingPeriod)
    /// @custom:member executableFrom 실행 가능 시각 (votingEnds + timelockDelay) — exit 창구 종료
    /// @custom:member expires        폐기 시각 (executableFrom + grace)
    /// @custom:member executed       실행 완료 — 제안당 1회
    struct Proposal {
        bytes32 executionHash;
        uint48 votingEnds;
        uint48 executableFrom;
        uint48 expires;
        bool executed;
    }

    /// @dev proposalId가 제안별 nonce다. 실행 내용과 투표/실행 기한도 서명에 묶는다.
    bytes32 public constant VOTE_TYPEHASH =
        keccak256("Vote(uint256 proposalId,bytes32 executionHash,uint48 votingEnds,uint48 expires)");

    IERC20 public immutable votesToken;
    uint256 public immutable quorum;
    uint48 public immutable votingPeriod;
    uint48 public immutable timelockDelay;
    uint48 public immutable gracePeriod;

    uint256 public nextProposalId = 1; // 0은 미사용 — 존재 검사를 위해

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public approvedVotes;

    error VotesTokenHasNoCode(address token);
    error ZeroQuorum();
    error ZeroPeriod();
    error ProposalNotFound(uint256 proposalId);
    error HashMismatch(bytes32 expected);
    error NotExecutableYet(uint256 at, uint256 from);
    error ProposalExpired(uint256 at, uint256 until);
    error AlreadyExecuted(uint256 proposalId);
    error InvalidSignature();
    error SignatureCountMismatch();
    error VotingClosed(uint256 at, uint256 until);
    error VoteAlreadyApproved(uint256 proposalId, address voter);
    error QuorumNotReached(uint256 got, uint256 needed);
    error InsufficientTreasury(uint256 needed, uint256 have);
    error ExecutionFailed(bytes ret);

    event Proposed(
        uint256 indexed proposalId,
        address indexed proposer,
        bytes32 executionHash,
        uint48 votingEnds,
        uint48 executableFrom
    );
    event VoteApproved(uint256 indexed proposalId, address indexed voter);
    event Executed(uint256 indexed proposalId, address indexed target, uint256 value, uint256 weight);

    /// @param votesToken_     투표권 ERC-20 (FoT 금지 — 무게 왜곡)
    /// @param quorum_         실행에 필요한 토큰 무게 합 (절대량)
    /// @param votingPeriod_   제안 후 투표 기간 (초)
    /// @param timelockDelay_  투표 종료 후 실행 대기 (초) — exit 창구
    /// @param gracePeriod_    실행 가능 기간 (초) — 놓치면 폐기·재제안
    constructor(
        address guardian,
        IERC20 votesToken_,
        uint256 quorum_,
        uint48 votingPeriod_,
        uint48 timelockDelay_,
        uint48 gracePeriod_
    ) SimpleBrake(guardian) EIP712("EastSeaSimpleDAO", "2") {
        if (address(votesToken_).code.length == 0) {
            revert VotesTokenHasNoCode(address(votesToken_));
        }
        if (quorum_ == 0) revert ZeroQuorum();
        if (votingPeriod_ == 0 || timelockDelay_ == 0 || gracePeriod_ == 0) revert ZeroPeriod();

        votesToken = votesToken_;
        quorum = quorum_;
        votingPeriod = votingPeriod_;
        timelockDelay = timelockDelay_;
        gracePeriod = gracePeriod_;
    }

    /// @dev 국고 — 제안이 집행할 native를 받는다. 누구나 충전 가능.
    receive() external payable {}

    // ---------------------------------------------------------------- 제안 (진입 — brake 차단)

    /// @notice 실행할 행동의 해시를 커밋해 제안을 연다.
    ///         executionHash = keccak256(abi.encode(target, value, data)).
    ///         제안 등록은 누구나 — 승인은 쿼럼의 몫이다 (F-07).
    function propose(bytes32 executionHash) external whenEntryOpen returns (uint256 proposalId) {
        proposalId = nextProposalId;
        nextProposalId = proposalId + 1;

        uint48 ends = uint48(block.timestamp) + votingPeriod;
        proposals[proposalId] =
            Proposal(executionHash, ends, ends + timelockDelay, ends + timelockDelay + gracePeriod, false);

        emit Proposed(proposalId, msg.sender, executionHash, ends, ends + timelockDelay);
    }

    /// @notice 오프체인 서명 없이 msg.sender 계정으로 찬성한다.
    ///         투표 종료 전만 가능하며 무게는 다른 표와 함께 실행 시 읽는다.
    function vote(uint256 proposalId) external whenEntryOpen {
        Proposal storage p = proposals[proposalId];
        if (p.executionHash == bytes32(0)) revert ProposalNotFound(proposalId);
        if (block.timestamp >= p.votingEnds) revert VotingClosed(block.timestamp, p.votingEnds);
        if (approvedVotes[proposalId][msg.sender]) revert VoteAlreadyApproved(proposalId, msg.sender);

        approvedVotes[proposalId][msg.sender] = true;
        emit VoteApproved(proposalId, msg.sender);
    }

    // ---------------------------------------------------------------- 실행 (탈출 — brake 무관)

    /// @notice 기존 EOA용 ABI — 쿼럼 서명 묶음으로 제안을 실행한다.
    /// @param target    호출 대상 — executionHash의 첫 성분
    /// @param value     함께 보낼 native (국고에서)
    /// @param data      호출 데이터
    /// @param signatures 오름차순(주소순) 정렬된 65바이트 투표 서명
    function execute(
        uint256 proposalId,
        address target,
        uint256 value,
        bytes calldata data,
        bytes[] calldata signatures
    ) external nonReentrant returns (bytes memory) {
        _validateExecution(proposalId, target, value, data);
        uint256 weight = _checkVotes(proposalId, signatures);
        return _execute(proposalId, target, value, data, weight);
    }

    /// @notice EOA·ERC-1271·직접 승인 표를 섞어 실행한다. 실행자는 누구든.
    /// @param signers 엄격 주소 오름차순의 유권자 주소 — 0·중복 금지
    /// @param signatures 유권자와 대응하는 서명. 빈 바이트는 기존 vote 승인만 허용.
    function executeWithSigners(
        uint256 proposalId,
        address target,
        uint256 value,
        bytes calldata data,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external nonReentrant returns (bytes memory) {
        _validateExecution(proposalId, target, value, data);
        uint256 weight = _checkExplicitVotes(proposalId, signers, signatures);
        return _execute(proposalId, target, value, data, weight);
    }

    // ---------------------------------------------------------------- 뷰 (F-04)

    /// @notice 제안 상태 — 프론트용. 0 없음, 1 투표중, 2 타임락,
    ///         3 실행가능, 4 실행됨, 5 만료.
    function state(uint256 proposalId) external view returns (uint8) {
        Proposal storage p = proposals[proposalId];
        if (p.executionHash == bytes32(0)) return 0;
        if (p.executed) return 4;
        if (block.timestamp > p.expires) return 5;
        if (block.timestamp < p.votingEnds) return 1;
        if (block.timestamp < p.executableFrom) return 2;
        return 3;
    }

    /// @notice EIP-712 투표 digest — EOA는 typed data를, 계정은 ERC-1271 정책으로 서명한다.
    ///         도메인(chainId + 자기 주소), 제안 id(nonce), 내용, 기한을 묶는다.
    function getVoteHash(uint256 proposalId) public view returns (bytes32) {
        Proposal storage p = proposals[proposalId];
        return
            _hashTypedDataV4(keccak256(abi.encode(VOTE_TYPEHASH, proposalId, p.executionHash, p.votingEnds, p.expires)));
    }

    /// @notice 현재 chainId를 반영한 EIP-712 도메인 separator.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------- 내부

    function _validateExecution(uint256 proposalId, address target, uint256 value, bytes calldata data) private view {
        Proposal storage p = proposals[proposalId];
        if (p.executionHash == bytes32(0)) revert ProposalNotFound(proposalId);
        if (p.executed) revert AlreadyExecuted(proposalId);
        if (block.timestamp < p.executableFrom) revert NotExecutableYet(block.timestamp, p.executableFrom);
        if (block.timestamp > p.expires) revert ProposalExpired(block.timestamp, p.expires);
        if (keccak256(abi.encode(target, value, data)) != p.executionHash) revert HashMismatch(p.executionHash);
        if (address(this).balance < value) revert InsufficientTreasury(value, address(this).balance);
    }

    function _execute(uint256 proposalId, address target, uint256 value, bytes calldata data, uint256 weight)
        private
        returns (bytes memory)
    {
        proposals[proposalId].executed = true; // CEI: 재진입해도 두 번째는 죽는다
        emit Executed(proposalId, target, value, weight);

        (bool ok, bytes memory retData) = target.call{value: value}(data);
        if (!ok) revert ExecutionFailed(retData);
        return retData;
    }

    /// @dev 기존 EOA ABI에서도 low-s 검증과 code 계정의 ERC-1271 정책을 강제한다.
    function _checkVotes(uint256 proposalId, bytes[] calldata signatures) private view returns (uint256 weight) {
        bytes32 h = getVoteHash(proposalId);
        address last = address(0);

        for (uint256 i; i < signatures.length; ++i) {
            bytes calldata sig = signatures[i];
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(h, sig);
            if (
                err != ECDSA.RecoverError.NoError || recovered <= last
                    || !SignatureChecker.isValidSignatureNow(recovered, h, sig)
            ) {
                revert InvalidSignature();
            }
            last = recovered;
            weight += votesToken.balanceOf(recovered); // FoT면 왜곡 — README 요구사항
        }

        if (weight < quorum) revert QuorumNotReached(weight, quorum);
    }

    /// @dev 주소별로 딱 한 번 현재 잔액을 합산한다 — 직접 승인·서명 중복 집계 금지.
    function _checkExplicitVotes(uint256 proposalId, address[] calldata signers, bytes[] calldata signatures)
        private
        view
        returns (uint256 weight)
    {
        if (signers.length != signatures.length) revert SignatureCountMismatch();
        bytes32 h = getVoteHash(proposalId);
        address last = address(0);

        for (uint256 i; i < signers.length; ++i) {
            address signer = signers[i];
            if (signer <= last) revert InvalidSignature();
            bytes calldata sig = signatures[i];
            if (sig.length == 0) {
                if (!approvedVotes[proposalId][signer]) revert InvalidSignature();
            } else if (!SignatureChecker.isValidSignatureNow(signer, h, sig)) {
                revert InvalidSignature();
            }
            last = signer;
            weight += votesToken.balanceOf(signer);
        }

        if (weight < quorum) revert QuorumNotReached(weight, quorum);
    }
}
