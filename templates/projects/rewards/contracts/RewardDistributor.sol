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

// src/rewards/RewardDistributor.sol

/// @title 예제 6 — 스테이킹 보상 분배기
/// @notice ERC-20을 스테이크하면 보상 토큰을 시간 비례로 분배한다.
///         후원자가 fundRewards(amount, duration)로 보상 풀을 채우면
///         duration 동안 선형 방출된다.
/// @dev
///  회계 — 잔액 기반(유료 상태 철학: 잔액이 진실):
///   totalDebt = 사용자에게 귀속됐지만 아직 지급되지 않은 총액.
///   rewardToken 잔액 - totalDebt = 아직 방출되지 않은 미래분.
///   다음 fund는 이 "남은 분"을 새 기간에 다시 반영한다 — 스테이커가
///   아무도 없던 구간의 방출 예정분이 소실되지 않는다.
///
///  분배 수학 (Synthetix StakingRewards 형식 + 함정 제거):
///   rewardPerTokenStored += elapsed * rate * 1e18 / totalStaked
///   earned(user) = userOwed + staked * (rewardPerToken - userRewardPaid) / 1e18
///   Synthetix 원본은 전액 인출 시 staked=0이 되며 미청구 보상이 소실된다
///   (유명한 함정). 여기는 checkpoint 시점마다 진행분을 userOwed로 이월해
///   unstake 이후에도 보상이 살아 있다.
///
///  불변식:
///   I1 balance(reward) == totalDebt + 미방출분 — 결코 부족 지급하지 않는다
///   I2 totalDebt == Sum(earned) — 전원 claim이 잔액을 전부 소진한다
///
///  F 매핑:
///   F-01: stake/unstake/claim/fund 전부 nonReentrant + CEI(스냅샷 후 push).
///   F-02: 스테이크 유입은 pull의 도착량 기준 — FoT 스테이크 토큰도
///         실제 도착량만 크레딧된다 (좌초 없음).
///   F-03: 토큰 이동은 SafeToken(무코드 거부 + strict bool).
///   F-04: 뷰는 상수 시간.
contract RewardDistributor is SimpleBrake, ReentrancyGuard {
    uint256 private constant _PRECISION = 1e18;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public totalStaked;
    /// @dev 누적 보상/토큰 (1e18 스케일)
    uint256 public rewardPerTokenStored;
    /// @dev 귀속 미지급 총액 — balance - totalDebt가 미방출분
    uint256 public totalDebt;
    /// @dev 초당 보상 (finish 전까지)
    uint256 public rewardRate;
    uint256 public finishAt;
    uint256 public updatedAt;

    mapping(address => uint256) public userStaked;
    /// @dev 사용자별 마지막 상호작용 시점의 rewardPerToken 스냅샷
    mapping(address => uint256) public userRewardPaid;
    /// @dev checkpoint 시점까지 확정된 보상 — unstake 후에도 소실되지 않는다
    mapping(address => uint256) public userOwed;

    error ZeroAmount();
    error ZeroDuration();
    error InvalidToken();
    error InsufficientStake(uint256 wanted, uint256 staked);

    event RewardsFunded(uint256 amount, uint256 duration, uint256 rate, uint256 finishAt);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    constructor(address guardian, IERC20 stakingToken_, IERC20 rewardToken_) SimpleBrake(guardian) {
        // F-03: 무코드 주소 거부 — 배포 단계에서 잡는다.
        if (address(stakingToken_).code.length == 0 || address(rewardToken_).code.length == 0) {
            revert InvalidToken();
        }
        stakingToken = stakingToken_;
        rewardToken = rewardToken_;
        _registerPersonalTestToken(address(stakingToken_));
        _registerPersonalTestToken(address(rewardToken_));
    }

    // ---------------------------------------------------------------- 보상 풀

    /// @notice 보상 토큰을 풀에 추가하고 duration 동안 선형 방출한다.
    ///         이미 채워진 풀의 미방출분과 합쳐서 새 rate을 계산한다.
    /// @dev 누구나 호출 가능 (후원 모델). 신규 예치 = 진입이라 brake에 걸린다.
    function fundRewards(uint256 amount, uint256 durationSec) external personalTestAccess nonReentrant whenEntryOpen {
        if (amount == 0) revert ZeroAmount();
        if (durationSec == 0) revert ZeroDuration();

        _updateGlobal(); // fund 시점까지의 귀속을 먼저 마감한다
        _checkPersonalTestTokenDeposit(address(rewardToken), amount);
        SafeToken.pullExact(rewardToken, msg.sender, amount);
        _checkPersonalTestTokenCaps();

        // 잔액 기반 remaining: 스테이커 부재 구간의 방출 예정분도 회수된다
        uint256 remaining = rewardToken.balanceOf(address(this)) - totalDebt;
        rewardRate = remaining / durationSec;
        finishAt = block.timestamp + durationSec;
        updatedAt = block.timestamp;
        emit RewardsFunded(amount, durationSec, rewardRate, finishAt);
    }

    // ---------------------------------------------------------------- 스테이킹

    /// @notice 스테이크 토큰을 예치한다 (진입 — brake 차단).
    function stake(uint256 amount) external personalTestAccess nonReentrant whenEntryOpen {
        if (amount == 0) revert ZeroAmount();
        _updateGlobal();
        _checkpoint(msg.sender);
        // F-02: 도착량 기준 — FoT 스테이크 토큰도 실제 도착만 크레딧
        _checkPersonalTestTokenDeposit(address(stakingToken), amount);
        uint256 delivered = SafeToken.pull(stakingToken, msg.sender, amount);
        _checkPersonalTestTokenCaps();
        totalStaked += delivered;
        userStaked[msg.sender] += delivered;
        emit Staked(msg.sender, delivered);
    }

    /// @notice 스테이크를 회수한다 (탈출 — brake와 무관하게 항상 열려 있다).
    ///         checkpoint가 진행분을 userOwed로 이월하므로 전액 인출 후에도
    ///         귀속 보상은 유지된다 (claim으로 수령).
    function unstake(uint256 amount) external personalTestAccess nonReentrant {
        if (amount > userStaked[msg.sender]) revert InsufficientStake(amount, userStaked[msg.sender]);
        _updateGlobal();
        _checkpoint(msg.sender);
        userStaked[msg.sender] -= amount;
        totalStaked -= amount;
        SafeToken.push(stakingToken, msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice 귀속된 보상을 수령한다 (탈출 — brake와 무관).
    /// @dev CEI: owed 소거와 totalDebt 감소를 먼저, 지급(push)을 마지막에.
    function claim() external personalTestAccess nonReentrant returns (uint256 paid) {
        _updateGlobal();
        _checkpoint(msg.sender);
        paid = userOwed[msg.sender];
        if (paid > 0) {
            userOwed[msg.sender] = 0;
            totalDebt -= paid;
            SafeToken.push(rewardToken, msg.sender, paid);
        }
        emit Claimed(msg.sender, paid);
    }

    // ---------------------------------------------------------------- 뷰 (F-04: 상수 시간)

    /// @notice 현재까지 귀속된 사용자 보상 (이월분 + 진행분).
    function earned(address user) external view returns (uint256) {
        uint256 rpt = _rewardPerToken();
        return userOwed[user] + ((userStaked[user] * (rpt - userRewardPaid[user])) / _PRECISION);
    }

    /// @notice 현재 시점까지의 누적 rewardPerToken.
    function rewardPerToken() external view returns (uint256) {
        return _rewardPerToken();
    }

    // ---------------------------------------------------------------- 내부

    /// @dev 전역 누적치를 현재 시각까지 반영한다. totalStaked == 0인 구간은
    ///      분모가 없어 반영하지 않는다 — 그 예정분은 잔액에 남아 다음
    ///      fund의 remaining에 편입된다 (소실 없음).
    function _updateGlobal() private {
        uint256 nowTs = block.timestamp;
        uint256 t = nowTs < finishAt ? nowTs : finishAt;
        if (t > updatedAt && totalStaked != 0 && rewardRate != 0) {
            uint256 accrued = (t - updatedAt) * rewardRate;
            rewardPerTokenStored += (accrued * _PRECISION) / totalStaked;
            totalDebt += accrued;
        }
        updatedAt = nowTs;
    }

    function _rewardPerToken() private view returns (uint256) {
        if (totalStaked == 0 || rewardRate == 0) return rewardPerTokenStored;
        uint256 t = block.timestamp < finishAt ? block.timestamp : finishAt;
        if (t <= updatedAt) return rewardPerTokenStored;
        return rewardPerTokenStored + ((t - updatedAt) * rewardRate * _PRECISION) / totalStaked;
    }

    /// @dev 사용자 진행분을 userOwed로 확정하고 스냅샷을 당긴다.
    ///      _updateGlobal(전역 rpt 갱신) 직후에만 호출한다.
    function _checkpoint(address user) private {
        userOwed[user] += (userStaked[user] * (rewardPerTokenStored - userRewardPaid[user])) / _PRECISION;
        userRewardPaid[user] = rewardPerTokenStored;
    }
}

