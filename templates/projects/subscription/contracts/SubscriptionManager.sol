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

// src/subscription/SubscriptionManager.sol

/// @title 예제 10 — 구독 관리자
/// @notice 초당 요율로 시간을 사는 선불 기간권. 보낸 금액만큼 만료
///         시각이 늘어나고, 취소하면 남은 초를 비례 환불한다.
///         소비된 시간은 운영 수익이 되어 누구나 정산 트리거로
///         수취인에게 인도할 수 있다.
/// @dev
///  설계 결정 — 운영자 키가 없다:
///   - ratePerSecond는 생성자 고정(immutable). 요금 변경은 새
///     컨트랙트 배포로 한다 — 요금 조작 권한 자체가 공격면이다.
///   - guardian은 brake(신규 구독 차단)만 가능. 자금·기간 변경 불가.
///   - payee는 수익 수취 주소(immutable). claimRevenue는 permissionless
///     — 지갑이 행동하지 않아도 누구나 정산을 대신 트리거한다.
///
///  회계 — 대칭 산수와 준비금 스칼라:
///   subscribe: seconds = msg.value / ratePerSecond (버림)
///   cancel:    refund  = remainingSec * ratePerSecond
///   지불과 환불이 같은 곱셈식이라 dust가 양쪽에서 1초 미만으로
///   대칭을 이룬다. 잔여 <1초치(value % rate)는 기간에 못 들어가
///   거부 없이 흡수된다 — 정확 배수를 강제하는 것보다 UX 오류가 적다.
///
///   소비 수익의 회수가 설계의 관건이다. 모든 활성 구독의 "납입
///   원금" 합(refundReserve)을 글로벌 스칼라 하나로 유지하면:
///     인도 가능 수익 = balance - refundReserve
///   을 사용자 목록 반복 없이(O(1), F-04) 계산할 수 있다. 준비금은
///   cancel/settle에서만 줄어든다 — 시간이 흘러 실제 부채가 더 줄어도
///   값은 그대로라 항상 보수적(상한)이다. 환불은 언제나 전액 뒷받침된다.
///
///  상태 — 사용자당 1슬롯:
///   Subscriber { uint64 expiry; uint88 contributed; } 팩 — 만료 시각과
///   이번 이어달기 납입액이 32바이트에 함께 산다. 기간 연장은 재기록,
///   새 슬롯은 첫 구독 1회뿐이다.
///
///  F 매핑:
///   F-01: subscribe/cancel/claim nonReentrant + CEI(스토리지 먼저,
///         native 전송 마지막). settle/settleExpired는 외부 호출 없음.
///   F-02/F-03: native만 — FoT·무코드 영역 밖. receive()는 거부.
///   F-04: 모든 뷰·준비금 상계 상수 시간 — 사용자 수와 무관하다.
///   F-06: 요금·수취인 불변 — registrar성 권한 없음.
///   F-07: Subscribed 이벤트 ≠ 구독 상태 — 진실은 subscribers다.
contract SubscriptionManager is SimpleBrake, ReentrancyGuard {
    /// @custom:member expiry      만료 시각 (unix 초)
    /// @custom:member contributed 이번 이어달기(streak)에 낸 금액 —
    ///                           정산 전까지 환불 준비금을 구성한다
    struct Subscriber {
        uint64 expiry;
        uint88 contributed;
    }

    /// @dev 초당 요율 (wei) — 배포 시 영구 고정
    uint256 public immutable ratePerSecond;

    /// @dev 수익 수취 주소 — 고정. 키 행사가 아닌 지급 목적지다.
    address public immutable payee;

    mapping(address => Subscriber) public subscribers;

    /// @dev 활성 구독 납입 원금의 합(상계 상한). balance >= refundReserve
    ///      불변 — 환불 가능액은 항상 잔액으로 뒷받침된다.
    uint256 public refundReserve;

    error ZeroPayee();
    error PaymentTooSmall(uint256 paid, uint256 minimum);
    error NotSubscribed();
    error RefundFailed();
    error PayoutFailed();
    error NothingToSettle();
    error NothingToClaim();
    error AmountTooLarge();

    event Subscribed(address indexed user, uint256 paid, uint256 secondsAdded, uint64 newExpiry);
    event Cancelled(address indexed user, uint256 refund, uint64 oldExpiry);
    event Settled(address indexed user, uint256 amount);
    event RevenueClaimed(address payee, uint256 amount);

    constructor(address guardian, address payee_, uint256 ratePerSecond_) SimpleBrake(guardian) {
        if (payee_ == address(0)) revert ZeroPayee();
        _requirePersonalTestAccount(payee_);
        if (ratePerSecond_ == 0) revert PaymentTooSmall(0, 1);
        payee = payee_;
        ratePerSecond = ratePerSecond_;
    }

    /// @dev 직접 송금 거부 — 기간 매수는 subscribe의 회계를 거친다.
    receive() external payable personalTestAccess {
        revert PaymentTooSmall(0, ratePerSecond);
    }

    // ---------------------------------------------------------------- 구독

    /// @notice 보낸 금액만큼 구독 기간을 연장한다 (진입 — brake 차단).
    ///         미구독이면 지금부터, 구독 중이면 만료 시각에 이어서.
    ///         이전 기간이 이미 만료였다면 먼저 수익으로 정산한다.
    function subscribe() external payable personalTestAccess nonReentrant whenEntryOpen {
        _checkPersonalTestNativeCap();
        uint256 secondsToAdd = msg.value / ratePerSecond;
        if (secondsToAdd == 0) revert PaymentTooSmall(msg.value, ratePerSecond);

        Subscriber storage s = subscribers[msg.sender];
        if (s.expiry <= block.timestamp) _settle(msg.sender, s); // 죽은 기간 정산

        // 기존 만료가 미래면 이어서, 과거(또는 없으면)면 지금부터
        uint64 base = s.expiry > block.timestamp ? s.expiry : uint64(block.timestamp);
        uint256 value = secondsToAdd * ratePerSecond;
        // 팩 필드 둘 다 지불 전액을 온전히 표현해야 한다. 축소 캐스트는
        // 상위 비트를 조용히 버린다 — contributed를 잘라내면서 refundReserve를
        // 늘리면 인도 불가능한 원금이 남는다. 캐스트 전에 잔여 범위를 검사한다.
        if (secondsToAdd > uint256(type(uint64).max) - base || value > uint256(type(uint88).max) - s.contributed) {
            revert AmountTooLarge();
        }
        uint64 newExpiry = base + uint64(secondsToAdd);

        s.expiry = newExpiry;
        s.contributed += uint88(value);
        refundReserve += value; // CEI: 스토리지 먼저
        emit Subscribed(msg.sender, msg.value, secondsToAdd, newExpiry);
    }

    /// @notice 남은 기간을 비례 환불받고 구독을 끊는다 (탈출 — brake 무관).
    ///         납입 원금 전액이 준비금에서 해제된다 — 소비분은 이 순간
    ///         수익이 된다.
    function cancel() external personalTestAccess nonReentrant {
        Subscriber storage s = subscribers[msg.sender];
        uint256 remaining = s.expiry > block.timestamp ? s.expiry - block.timestamp : 0;
        if (remaining == 0) revert NotSubscribed();

        uint64 oldExpiry = s.expiry;
        uint256 refund = remaining * ratePerSecond;

        s.expiry = uint64(block.timestamp); // CEI: 먼저 끊는다
        uint256 contributed = s.contributed;
        s.contributed = 0;
        refundReserve -= contributed; // 납입 전액 해제

        (bool ok,) = msg.sender.call{value: refund}("");
        if (!ok) revert RefundFailed(); // 환불 실패 — 상태는 롤백된다
        emit Cancelled(msg.sender, refund, oldExpiry);
    }

    // ---------------------------------------------------------------- 정산 (탈출 — brake 무관)

    /// @notice 만료된 구독의 납입 잔고를 수익으로 확정한다.
    ///         누구나 호출 가능 — 보상을 붙이고 싶은 키퍼의 기본 재료.
    function settleExpired(address user) external personalTestAccess nonReentrant {
        _requirePersonalTestAccount(user);
        Subscriber storage s = subscribers[user];
        if (s.expiry > block.timestamp || s.contributed == 0) revert NothingToSettle();
        _settle(user, s);
    }

    /// @notice 준비금으로 뒷받침되지 않는 잔액(=소비 확정 수익 + dust)을
    ///         payee에게 인도한다. 누구나 호출 가능 — payee는 온체인 행동이
    ///         필요 없다.
    function claimRevenue() external personalTestAccess nonReentrant {
        _requirePersonalTestAccount(payee);
        uint256 amount = address(this).balance - refundReserve;
        if (amount == 0) revert NothingToClaim();

        (bool ok,) = payee.call{value: amount}("");
        if (!ok) revert PayoutFailed();
        emit RevenueClaimed(payee, amount);
    }

    // ---------------------------------------------------------------- 뷰 (F-04)

    function isSubscribed(address user) external view returns (bool) {
        return subscribers[user].expiry > block.timestamp;
    }

    /// @dev 현재 인도 가능한 수익 — 잔액에서 환불 준비금을 뺀 값.
    function claimableRevenue() external view returns (uint256) {
        return address(this).balance - refundReserve;
    }

    // ---------------------------------------------------------------- 내부

    /// @dev 납입 잔고를 준비금에서 해제해 수익으로 확정한다.
    function _settle(address user, Subscriber storage s) private {
        uint256 value = s.contributed;
        if (value == 0) return; // 이미 정산된 빈 기록 — 조용히 넘어간다

        s.contributed = 0;
        refundReserve -= value;
        emit Settled(user, value);
    }
}

