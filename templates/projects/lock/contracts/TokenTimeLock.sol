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

// src/common/SafeToken.sol

/// @notice 감사 결과 F-01/F-02/F-03에 대한 toolbox 공용 ERC-20 안전 프리미티브.
/// @dev
///  F-03 (무코드·불성실 토큰): 모든 이동 전에 token.code.length > 0을 검사하고,
///       반환 데이터가 있으면 bool을 엄격히 확인한다. 빈 반환은 메인 레포 관례를
///       따라 성공으로 본다(일부 구형 토큰). 단 무코드 주소는 즉시 revert.
///  F-02 (수수료 과징 토큰): pull()은 실제 도착량(delivered)을 잔액 차이로 측정해
///       돌려준다. 약속 금액과 정확히 일치해야 하는 흐름은 pullExact()를 쓴다.
///  F-01 (재진입 예치): 이 라이브러리 자체는 가드가 아니다. pull을 호출하는 모든
///       진입점에는 OZ ReentrancyGuard의 nonReentrant를 붙여야 한다. balanceOf
///       측정은 외부 호출 이후에 하므로, 가드가 없으면 중첩 예치가 delta에
///       섞여 들어온다 — 그것이 F-01의 원본 결함이다.
library SafeToken {
    error TokenHasNoCode(address token);
    error TokenTransferFailed(address token);
    error ShortDelivery(uint256 expected, uint256 delivered);

    /// @dev from -> this 로 amount를 끌어오고 실제 도착량을 측정해 돌려준다.
    function pull(IERC20 token, address from, uint256 amount) internal returns (uint256 delivered) {
        if (amount == 0) return 0;
        if (address(token).code.length == 0) revert TokenHasNoCode(address(token));
        uint256 before = token.balanceOf(address(this));
        (bool ok, bytes memory ret) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok) revert TokenTransferFailed(address(token));
        if (ret.length != 0 && !abi.decode(ret, (bool))) revert TokenTransferFailed(address(token));
        delivered = token.balanceOf(address(this)) - before;
        if (delivered == 0) revert ShortDelivery(amount, 0); // 이동 없이 성공을 가장하는 토큰
    }

    /// @dev pull + 도착량 == amount 강제. 캠페인 예산·LP 예치처럼 정확한 금액이
    ///      계약 불변식에 들어가는 곳에만 쓴다(콜드 balanceOf 1회 추가).
    function pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 delivered = pull(token, from, amount);
        if (delivered != amount) revert ShortDelivery(amount, delivered);
    }

    /// @dev this -> to 로 amount를 보낸다. code 검사 + strict bool.
    function push(IERC20 token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (address(token).code.length == 0) revert TokenHasNoCode(address(token));
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) revert TokenTransferFailed(address(token));
        if (ret.length != 0 && !abi.decode(ret, (bool))) revert TokenTransferFailed(address(token));
    }

    /// @dev push + 수취인 잔액 차이 검증. "지급했다"는 사실 자체가 계약상 약속인
    ///      곳(마켓 정산·래플 상금)에서 쓴다. 사악한 토큰이 true만 반환하고
    ///      이동하지 않는 경우를 잡는다(F-03).
    function pushExact(IERC20 token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to.code.length != 0) {
            uint256 before = token.balanceOf(to);
            push(token, to, amount);
            if (token.balanceOf(to) - before != amount) revert ShortDelivery(amount, 0);
        } else {
            push(token, to, amount); // EOA 수취인은 잔액 조회가 무의미한 토큰도 있다
        }
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

// src/lock/TokenTimeLock.sol

/// @title 예제 7-A — 배치형 토큰 타임락
/// @notice 누구나 토큰을 예치하고 수혜자의 클리프·기간을 지정해 잠근다.
///         수혜자는 cliff 후 선형 해제분을 release()로 인출한다.
///         운영자 키가 없다 — 예치자 본인이 자금을 넣고 파라미터를 정한다.
/// @dev
///  설계 결정:
///   - 수혜자당 활성 잠금 1개(AlreadyLocked). 병합은 cliff/duration이
///     섞이는 회계를 만들므로 금지 — 다음 그랜트는 인출 후 가능.
///   - released를 잔액이 아닌 슬롯에 유지한다: 배치 컨트랙트의 잔액은
///     여러 수혜자가 공유해 누가 얼마나 뺐는지 잔액만으로 알 수 없다.
///   - Lock 1개를 2슬롯(uint128+uint128 / uint48x3)에 팩한다.
///
///  F 매핑:
///   F-01: lock/release 모두 nonReentrant + CEI(스냅샷 후 push).
///   F-02: 예치는 pullExact — 정확한 금액이 잠금 계약의 근거다.
///   F-03: 생성자 무코드 거부, 이동은 SafeToken.
///   F-04: vested/releasable 상수 시간.
contract TokenTimeLock is SimpleBrake, ReentrancyGuard {
    uint256 private constant _MAX_UINT128 = type(uint128).max;

    IERC20 public immutable token;

    /// @param amount   잠긴 총액
    /// @param released 지금까지 지급된 누적
    /// @param start    lock 시각 (초)
    /// @param cliff    start 이후 클리프까지 상대 초
    /// @param duration start 이후 전량 해제까지 상대 초 (cliff 포함, >= cliff)
    struct Lock {
        uint128 amount;
        uint128 released;
        uint48 start;
        uint48 cliff;
        uint48 duration;
    }

    mapping(address => Lock) public locks;

    error ZeroAmount();
    error ZeroDuration();
    error AmountTooLarge(uint256 amount);
    error AlreadyLocked(address beneficiary);
    error NothingToRelease();

    event Locked(
        address indexed depositor, address indexed beneficiary, uint256 amount, uint256 cliff, uint256 duration
    );
    event Released(address indexed beneficiary, uint256 amount);

    constructor(address guardian, IERC20 token_) SimpleBrake(guardian) {
        // F-03: 무코드 주소는 배포 단계에서 거부한다.
        if (address(token_).code.length == 0) revert ZeroAmount();
        token = token_;
        _registerPersonalTestToken(address(token_));
    }

    // ---------------------------------------------------------------- 잠금

    /// @notice 토큰을 예치해 수혜자의 잠금을 만든다 (진입 — brake 차단).
    ///         수혜자당 활성 잠금은 1개다.
    function lockFor(address beneficiary, uint256 amount, uint256 cliffSec, uint256 durationSec)
        external
        personalTestAccess
        nonReentrant
        whenEntryOpen
    {
        _requirePersonalTestAccount(beneficiary);
        if (amount == 0) revert ZeroAmount();
        if (durationSec == 0 || cliffSec > durationSec) revert ZeroDuration();
        if (amount > _MAX_UINT128) revert AmountTooLarge(amount);
        Lock storage existing = locks[beneficiary];
        if (existing.amount != 0 && existing.released < existing.amount) revert AlreadyLocked(beneficiary);

        _checkPersonalTestTokenDeposit(address(token), amount);
        SafeToken.pullExact(token, msg.sender, amount); // F-02: 정확한 금액
        _checkPersonalTestTokenCaps();
        locks[beneficiary] = Lock(uint128(amount), 0, uint48(block.timestamp), uint48(cliffSec), uint48(durationSec));
        emit Locked(msg.sender, beneficiary, amount, cliffSec, durationSec);
    }

    /// @notice 해제분을 인출한다 (탈출 — brake와 무관하게 항상 열려 있다).
    ///         수혜자 본인만 호출한다.
    function release() external personalTestAccess nonReentrant {
        Lock storage l = locks[msg.sender];
        // vested는 단조 증가, released는 vested에서만 나가므로 차 >= 0
        uint256 due = _vested(msg.sender) - l.released;
        if (due == 0) revert NothingToRelease();
        l.released = uint128(l.released + due); // CEI: 스냅샷 먼저
        SafeToken.push(token, msg.sender, due);
        emit Released(msg.sender, due);
    }

    // ---------------------------------------------------------------- 뷰 (F-04)

    /// @notice t=현재까지의 선형 해제 누적 (cliff 전 0).
    function vested(address beneficiary) external view returns (uint256) {
        return _vested(beneficiary);
    }

    /// @notice 지금 release()하면 나오는 양.
    function releasable(address beneficiary) external view returns (uint256) {
        Lock storage l = locks[beneficiary];
        if (l.amount == 0) return 0;
        return _vested(beneficiary) - l.released;
    }

    function _vested(address beneficiary) private view returns (uint256) {
        Lock storage l = locks[beneficiary];
        if (l.amount == 0) return 0;
        uint256 elapsed = block.timestamp - l.start;
        if (elapsed <= l.cliff) return 0; // 클리프 전: 0 (경계 포함)
        if (elapsed >= l.duration) return l.amount;
        return (uint256(l.amount) * (elapsed - l.cliff)) / (uint256(l.duration) - l.cliff);
    }
}

