// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20 ^0.8.24;

// lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// src/system/IEastSeaBrake.sol

/// @notice EastSea 앱 레지스트리 §8.2가 정의한 긴급 정지(brake) 인터페이스.
/// 지갑은 선언된 컨트랙트 전부에 대해 brakeState()를 eth_call로 확인한다.
/// 구현 컨트랙트의 규칙:
///   - state는 단조 증가만 한다 (0 정상 -> 1 신규 진입 정지 -> 2 전면 정지).
///   - state 1은 새 진입(스왑·입금·구매 등)만 막고 출금·탈출은 연다.
///   - 출금·환불·클레임 경로는 절대 brake에 묶여서는 안 된다.
interface IEastSeaBrake {
    /// @return state    0 = 정상, 1 = 신규 진입 정지(출금 열림), 2 = 전면 정지(출금은 여전히 열림)
    /// @return guardian brake를 올릴 수 있는 주소
    /// @return since    brake가 발효된 시각 (초, 0 = 없음)
    function brakeState() external view returns (uint8 state, address guardian, uint64 since);

    /// @return uri      brake 규칙 문서 위치 (트리거 조건·가디언·자금 탈출 경로)
    /// @return docSha256 문서의 sha256 (0이면 검증 없음)
    function brakeSpec() external view returns (string memory uri, bytes32 docSha256);
}

// lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/ReentrancyGuard.sol)

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If EIP-1153 (transient storage) is available on the chain you're deploying at,
 * consider using {ReentrancyGuardTransient} instead.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}

// src/common/PersonalTest.sol

interface IPersonalTestPolicy {
    function personalTestPolicy() external view returns (bytes32, address, uint256, uint256);
    function personalTestAuthority() external view returns (address);
    function isPersonalTestInstance(address instance) external view returns (bool);
    function isConstructingPersonalTestInstance(address instance) external view returns (bool);
    function registerChild(address child) external;
    function deployChild(bytes calldata creationCode, bytes32 salt) external returns (address);
    function checkPersonalTestTokenReceipt(address token) external;
}

/// @notice An immutable, wallet-owned deployment policy for local mainnet experiments.
/// @dev Constructors keep their testnet ABI. A personal factory supplies the policy
///      while creating an instance, before any application code can be used. Mutable
///      state lives in a namespace so inheriting this base preserves application slots.
abstract contract PersonalTest {
    bytes32 public constant PERSONAL_TEST_MAGIC = keccak256("eastsea.personal-test/1");
    bytes32 private constant _PERSONAL_STORAGE = keccak256("eastsea.toolbox.personal-test.storage/1");

    bool public immutable personalTestEnabled;
    address public immutable personalTestOwner;
    uint256 public immutable personalTestNativeCap;
    uint256 public immutable personalTestTokenCap;
    address public immutable personalTestAuthority;

    struct PersonalState {
        mapping(address => bool) allowed;
        mapping(address => bool) registered;
        address[] tokens;
    }

    error PersonalTestAccountDenied(address account);
    error PersonalTestOwnerOnly();
    error PersonalTestInvalidPolicy();
    error PersonalTestOwnerRequired();
    error PersonalTestValueCap(uint256 held, uint256 cap);

    event PersonalTestCreated(address indexed owner, uint256 nativeCap, uint256 tokenCap, string mode);
    event PersonalTestAccountChanged(address indexed account, bool allowed);

    constructor() {
        (bool ok, bytes memory policy) =
            msg.sender.staticcall(abi.encodeCall(IPersonalTestPolicy.personalTestPolicy, ()));
        bool enabled;
        address owner;
        uint256 nativeCap;
        uint256 tokenCap;
        address authority;
        if (ok && policy.length == 128) {
            bytes32 magic;
            (magic, owner, nativeCap, tokenCap) = abi.decode(policy, (bytes32, address, uint256, uint256));
            if (magic == PERSONAL_TEST_MAGIC) {
                if (owner == address(0) || nativeCap == 0 || tokenCap == 0) revert PersonalTestInvalidPolicy();
                enabled = true;
                (bool authorityOk, bytes memory authorityData) =
                    msg.sender.staticcall(abi.encodeCall(IPersonalTestPolicy.personalTestAuthority, ()));
                authority =
                    authorityOk && authorityData.length == 32 ? abi.decode(authorityData, (address)) : msg.sender;
                if (authority == address(0)) revert PersonalTestInvalidPolicy();
            }
        }
        personalTestEnabled = enabled;
        personalTestOwner = enabled ? owner : address(0);
        personalTestNativeCap = enabled ? nativeCap : 0;
        personalTestTokenCap = enabled ? tokenCap : 0;
        personalTestAuthority = enabled ? authority : address(0);
        if (enabled) {
            _personalState().allowed[owner] = true;
            emit PersonalTestCreated(owner, nativeCap, tokenCap, "personal-test");
        }
    }

    modifier personalTestAccess() {
        _requirePersonalTestAccount(msg.sender);
        _;
    }

    function instanceMode() public view returns (string memory) {
        return personalTestEnabled ? "personal-test" : "testnet";
    }

    function personalTestPolicy() public view returns (bytes32, address, uint256, uint256) {
        return (
            personalTestEnabled ? PERSONAL_TEST_MAGIC : bytes32(0),
            personalTestOwner,
            personalTestNativeCap,
            personalTestTokenCap
        );
    }

    function personalTestAllowed(address account) public view returns (bool) {
        return _personalState().allowed[account];
    }

    /// @notice Add only your own other accounts. The policy cannot be disabled or enlarged.
    function setPersonalTestAccount(address account, bool allowed) external {
        if (!personalTestEnabled || msg.sender != personalTestOwner) revert PersonalTestOwnerOnly();
        if (account == address(0) || (account == personalTestOwner && !allowed)) revert PersonalTestOwnerRequired();
        _personalState().allowed[account] = allowed;
        emit PersonalTestAccountChanged(account, allowed);
    }

    /// @dev Controlled personal tokens notify recipients after transfer. This also
    ///      caps token funding of DAO/multisig treasuries without an admin deposit API.
    function checkPersonalTestTokenReceipt(address token) external personalTestAccess {
        if (!personalTestEnabled || msg.sender != token) revert PersonalTestInvalidPolicy();
        _checkPersonalTestTokenCap(token);
    }

    function _isPersonalTest() internal view returns (bool) {
        return personalTestEnabled;
    }

    function _exampleDeployer() internal view returns (address) {
        return personalTestEnabled ? personalTestOwner : msg.sender;
    }

    function _requirePersonalTestAccount(address account) internal view {
        if (!personalTestEnabled || account == address(this) || _personalState().allowed[account]) return;
        // A policy-shaped public relay is insufficient: it must actually have been
        // created and verified by this wallet's own deployment authority.
        (bool ok, bytes memory data) =
            personalTestAuthority.staticcall(abi.encodeCall(IPersonalTestPolicy.isPersonalTestInstance, (account)));
        if (ok && data.length == 32 && abi.decode(data, (bool))) return;
        (ok, data) = personalTestAuthority.staticcall(
            abi.encodeCall(IPersonalTestPolicy.isConstructingPersonalTestInstance, (account))
        );
        if (ok && data.length == 32 && abi.decode(data, (bool))) return;
        revert PersonalTestAccountDenied(account);
    }

    function _checkPersonalTestNativeCap() internal view {
        if (personalTestEnabled && address(this).balance > personalTestNativeCap) {
            revert PersonalTestValueCap(address(this).balance, personalTestNativeCap);
        }
    }

    function _registerPersonalTestToken(address token) internal {
        if (!personalTestEnabled || _personalState().registered[token]) return;
        if (token.code.length == 0) revert PersonalTestInvalidPolicy();
        _personalState().registered[token] = true;
        _personalState().tokens.push(token);
    }

    /// @dev Raw token base units are summed, rather than trusting an external price oracle.
    function _checkPersonalTestTokenCaps() internal view {
        if (!personalTestEnabled) return;
        address[] storage tokens = _personalState().tokens;
        uint256 remaining = personalTestTokenCap;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 held = IERC20(tokens[i]).balanceOf(address(this));
            if (held > remaining) {
                revert PersonalTestValueCap(personalTestTokenCap - remaining + held, personalTestTokenCap);
            }
            remaining -= held;
        }
    }

    function _checkPersonalTestTokenCap(address token) internal {
        _registerPersonalTestToken(token);
        _checkPersonalTestTokenCaps();
    }

    function _checkPersonalTestTokenDeposit(address token, uint256 amount) internal {
        if (!personalTestEnabled) return;
        _registerPersonalTestToken(token);
        address[] storage tokens = _personalState().tokens;
        uint256 remaining = personalTestTokenCap;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 held = IERC20(tokens[i]).balanceOf(address(this));
            if (held > remaining) {
                revert PersonalTestValueCap(personalTestTokenCap - remaining + held, personalTestTokenCap);
            }
            remaining -= held;
        }
        if (amount > remaining) {
            revert PersonalTestValueCap(personalTestTokenCap - remaining + amount, personalTestTokenCap);
        }
    }

    function _registerPersonalTestChild(address child) internal {
        if (personalTestEnabled) IPersonalTestPolicy(personalTestAuthority).registerChild(child);
    }

    function _personalState() private pure returns (PersonalState storage state) {
        bytes32 slot = _PERSONAL_STORAGE;
        assembly { state.slot := slot }
    }
}

// src/system/SimpleBrake.sol

/// @notice IEastSeaBrake의 최소 구현. 상속해서 쓴다.
/// @dev 가디언은 생성 시 고정되며 state는 단조 증가만 한다. 출금 경로에
///      whenBrakeBelow를 붙이는 것을 금지한다 — brake는 진입만 막는다.
abstract contract SimpleBrake is IEastSeaBrake, PersonalTest {
    /// @dev 0 = 정상, 1 = 신규 진입 정지, 2 = 전면 정지
    uint8 private _brakeState;
    uint64 private _brakeSince;
    address public immutable brakeGuardian;

    error NotBrakeGuardian(address caller);
    error BrakeOnlyStronger(uint8 current, uint8 requested);
    error BrakedNewEntry(uint8 state);
    error BrakedFull(uint8 state);

    event BrakeEngaged(uint8 indexed state, address indexed guardian, uint64 since);

    modifier onlyBrakeGuardian() {
        if (msg.sender != brakeGuardian) revert NotBrakeGuardian(msg.sender);
        _;
    }

    /// @param guardian brake를 올릴 주소. 0이면 브레이크를 쓸 수 없다(선언만).
    constructor(address guardian) {
        brakeGuardian = guardian;
    }

    /// @notice 가디언만 호출. state는 현재보다 커야 한다 (되돌림 불가).
    function engageBrake(uint8 state) external personalTestAccess onlyBrakeGuardian {
        if (state == 0 || state > 2) revert BrakeOnlyStronger(_brakeState, state);
        if (state <= _brakeState) revert BrakeOnlyStronger(_brakeState, state);
        _brakeState = state;
        _brakeSince = uint64(block.timestamp);
        emit BrakeEngaged(state, msg.sender, _brakeSince);
    }

    /// @dev 새 진입(입금·스왑·구매·발행) 경로에 붙인다. state 1 이상이면 막힌다.
    modifier whenEntryOpen() {
        if (_brakeState >= 1) revert BrakedNewEntry(_brakeState);
        _;
    }

    /// @dev 진입+상태 변경(출금 외 대부분)을 막는다. 출금·환불·클레임에는 쓰지 않는다.
    modifier whenFullyOpen() {
        if (_brakeState >= 2) revert BrakedFull(_brakeState);
        _;
    }

    function brakeState() external view returns (uint8 state, address guardian, uint64 since) {
        return (_brakeState, brakeGuardian, _brakeSince);
    }

    function brakeSpec() external pure returns (string memory uri, bytes32 docSha256) {
        return ("eastsea-toolbox://brake", bytes32(0));
    }
}

// src/crowdfund/AllOrNothingCrowdfund.sol

/// @title 예제 12 — 올오어낫싱 크라우드펀드
/// @notice 마감까지 목표 금액을 채우면 전액이 수혜자에게 인도되고,
///         못 채우면 기여자 전원이 전액 환불받는다. 중간 지점은 없다.
/// @dev
///  설계 결정 — 상태는 기여 회계가 전부다:
///   - 목표 달성 판정은 스칼라 하나(raised >= goal) — 목록 순회
///     없이(F-04) 어느 시점이든 판정된다.
///   - 기여자당 슬롯 1개는 환불 회계에 필수다 — "누가 얼마 냈는가"를
///     잔액이나 이벤트에서 유도하면 안 된다(예제 7의 잔액 유도 함정과
///     같은 이유). 다만 이 슬롯은 **일시적**이다: 캠페인 실패 시
///     환불이 슬롯을 지운다(delete). 성공 시에만 기여자 수만큼
///     영구 상태로 남는다 — 그 상태의 가치(출처 증명)는 국고 회계로
///     필요하다.
///   - 조기 달성: 목표를 채우는 순간 contribute는 막히고(AlreadyFunded)
///     withdraw는 마감 전이라도 연다. 기여자는 "달성 = 성공"을
///     이미 알고 있으므로 마감까지 기다릴 이유가 없다.
///   - 초과 기여: 마지막 기여가 목표를 넘어도 전액 수용한다.
///     초과분은 후원으로 처리 — 초과분 비례 환불은 회계를 복잡하게
///     하고(부분 성공) all-or-nothing 정신이 아니다.
///
///  F 매핑:
///   F-01: refund/withdraw CEI(슬롯/플래그 갱신 먼저, native 전송
///         마지막) + nonReentrant. contribute는 외부 호출이 없다.
///   F-02/F-03: native만 — FoT·무코드 영역 밖. receive()는 거부.
///   F-04: 목표 달성 판정 스칼라 비교 — 상수 시간.
///   F-07: Contributed 이벤트 ≠ 기여 — 진실은 contributions 매핑.
///   F-08: 사용하지 않음.
contract AllOrNothingCrowdfund is SimpleBrake, ReentrancyGuard {
    /// @dev 수혜자 — 성공 시 수령인 (배포 시 고정)
    address public immutable beneficiary;

    /// @dev 목표 금액 (wei) — 달성 판정의 기준
    uint128 public immutable goal;

    /// @dev 마감 시각 — 이후 미달이면 환불 개방
    uint48 public immutable deadline;

    /// @custom:member raised    지금까지 모인 금액 (목표 판정 스칼라)
    /// @custom:member withdrawn 성공 인도 완료 — 1회
    struct Campaign {
        uint128 raised;
        bool withdrawn;
    }

    Campaign public campaign;

    /// @dev 기여자별 납입액 — 환불 회계. 실패 시 환불이 지운다(일시적 슬롯)
    mapping(address => uint128) public contributions;

    error ZeroAmount();
    error GoalTooLow();
    error DeadlineTooShort();
    error DeadlinePassed(uint256 at, uint256 until);
    error AlreadyFunded(uint256 raised, uint256 goal);
    error RefundNotAllowed(uint256 raised, uint256 goal, uint256 until);
    error NothingToRefund();
    error NothingToWithdraw();
    error NativeTransferFailed();

    event Contributed(address indexed user, uint128 amount, uint128 raised);
    event Refunded(address indexed user, uint128 amount);
    event Withdrawn(address indexed beneficiary, uint128 amount);

    /// @param beneficiary_ 성공 시 수령인
    /// @param goal_        목표 금액
    /// @param durationSec  마감까지의 기간 (배포 시각부터)
    constructor(address guardian, address beneficiary_, uint128 goal_, uint48 durationSec) SimpleBrake(guardian) {
        if (beneficiary_ == address(0)) revert ZeroAmount();
        _requirePersonalTestAccount(beneficiary_);
        if (goal_ == 0) revert GoalTooLow();
        if (durationSec == 0) revert DeadlineTooShort();

        beneficiary = beneficiary_;
        goal = goal_;
        deadline = uint48(block.timestamp) + durationSec;
    }

    /// @dev 직접 송금 거부 — 기여는 contribute의 회계를 거친다.
    receive() external payable personalTestAccess {
        revert NativeTransferFailed();
    }

    // ---------------------------------------------------------------- 기여 (진입 — brake 차단)

    /// @notice 목표가 채울 때까지 기여한다. 마감 후·달성 후 거부.
    function contribute() external payable personalTestAccess nonReentrant whenEntryOpen {
        _checkPersonalTestNativeCap();
        if (msg.value == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert DeadlinePassed(block.timestamp, deadline);

        uint128 raised = campaign.raised;
        if (raised >= goal) revert AlreadyFunded(raised, goal);

        // 목표를 넘는 마지막 기여도 전압 수용 — 초과분은 후원
        uint128 newRaised = raised + uint128(msg.value);
        campaign.raised = newRaised;
        contributions[msg.sender] += uint128(msg.value);
        emit Contributed(msg.sender, uint128(msg.value), newRaised);
    }

    // ---------------------------------------------------------------- 환불 (탈출 — brake 무관)

    /// @notice 캠페인 실패(마감 + 목표 미달) 시 전액 환불받는다.
    ///         환불은 기여 슬롯을 지운다 — 캠페인의 상태는 정리된다.
    function refund() external personalTestAccess nonReentrant {
        uint128 c = contributions[msg.sender];
        if (c == 0) revert NothingToRefund();

        uint128 raised = campaign.raised;
        // 성공했거나 아직 진행중이면 환불 없다 — one-shot 판정
        if (raised >= goal || block.timestamp <= deadline) {
            revert RefundNotAllowed(raised, goal, deadline);
        }

        delete contributions[msg.sender]; // CEI: 슬롯 소거 먼저
        (bool ok,) = msg.sender.call{value: c}("");
        if (!ok) revert NativeTransferFailed();
        emit Refunded(msg.sender, c);
    }

    // ---------------------------------------------------------------- 인도 (탈출 — brake 무관)

    /// @notice 목표 달성 시 모금액 전액을 beneficiary에게 인도한다.
    ///         누구나 호출 가능 (가스 대낭) — 수령인은 항상 beneficiary.
    function withdraw() external personalTestAccess nonReentrant {
        _requirePersonalTestAccount(beneficiary);
        Campaign storage c = campaign;
        if (c.withdrawn || c.raised < goal) revert NothingToWithdraw();

        uint128 amount = c.raised;
        c.withdrawn = true; // CEI: 플래그 먼저
        (bool ok,) = beneficiary.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit Withdrawn(beneficiary, amount);
    }

    // ---------------------------------------------------------------- 뷰 (F-04)

    /// @dev 0 진행중, 1 성공(달성), 2 실패(마감+미달), 3 성공·인도 완료
    function state() external view returns (uint8) {
        Campaign storage c = campaign;
        if (c.raised >= goal) return c.withdrawn ? 3 : 1;
        if (block.timestamp > deadline) return 2;
        return 0;
    }
}

