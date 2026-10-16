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

// src/raffle/CommitRevealRaffle.sol

/// @title 예제 14 — 커밋-리빌 래플
/// @notice 참가비 풀 추첨. 주최자는 참가 모집 전에 시드를 해시로
///         커밋하고, 참가 마감 후 공개한다. 우승 인덱스는 시드와
///         블록 prevrandao를 섞어 뽑는다.
/// @dev
///  설계 결정 — 무작위성은 두 주체의 합작이어야 한다 (F-08):
///   - prevrandao 단독: 블록 제안 검증자가 결과를 조작할 수 있다.
///   - operator 시드 단독: operator가 미리 시뮬레이션하고 유리한
///     시드만 공개할 수 있다.
///   - 이 예제: winner = players[hash(seed ⊕ prevrandao) % N].
///     operator는 참가자 명단이 확정되기 **전에** 시드를 커밋하고
///     (keccak(seed)만 배포 시 고정), 검증자는 시드를 모른다.
///     어느 한쪽도 단독으로 결과를 고를 수 없다.
///
///  리빌 거부(withholding)의 완결 보장:
///   - operator가 불리한 결과를 보고 리빌을 거부할 수 있다.
///   - 리빌 마감 후 누구나 drawWithoutSeed()로 prevrandao만으로
///     추첨을 강행한다 — operator의 시드는 버려지고 참가비는
///     반드시 참가자에게 간다. "안 뽑힌 채로 굶는" 상태가 없다.
///
///  1회성 라이프사이클:
///   - 참가(진입) → 리빌/추첨(판정) → 지급(탈출). 추첨은 되돌릴
///     수 없으므로 컨트랙트 자체를 1회용으로 쓴다 — 재추첨 키를
///     만드는 대신 새 라플을 새로 배포한다.
///   - 참가자는 배열에 push한다(티켓당 1슬롯). 중복 참가 = 여러
///     티켓. 우승자 판정은 인덱스 산수 1회 — 순회 없음(F-04).
///
///  F 매핑:
///   F-01: reveal/draw CEI(drawn 플래그 먼저, 상금 전송 마지막)
///         + nonReentrant.
///   F-02/F-03: native만. receive()는 참가비 밖 송금을 거부.
///   F-04: 참가자 순회·합계 뷰 없음 — length와 인덱스 산수만.
///   F-05: 7702 위임 EOA 참가·수령 동일 — 주소 비교뿐.
///   F-06: operator는 시드 보유자일 뿐 — 커밋·마감·참가비 전부
///         immutable로 박혀 교체·개입 불가.
///   F-07: Entered 이벤트 ≠ 참가 — 진실은 players 배열이다.
///   F-08: 위 혼합 설계가 이 예제의 주제다.
contract CommitRevealRaffle is SimpleBrake, ReentrancyGuard {
    /// @dev operator 시드의 해시 — keccak256(abi.encodePacked(seed))
    bytes32 public immutable seedCommit;

    /// @dev 참가 마감 — 이후 참가 불가, 리빌 창구가 열린다
    uint48 public immutable enterDeadline;

    /// @dev 리빌 마감 — 이후 drawWithoutSeed로 추첨 강행
    uint48 public immutable revealDeadline;

    /// @dev 티켓 1장 가격 (wei)
    uint256 public immutable ticketPrice;

    /// @dev 참가 순서 그대로 — 우승 인덱스의 원본
    address[] public players;

    /// @dev 추첨 완료 — 1회. 우승자 주소가 곧 증명이다
    address public winner;
    bool public drawn;

    error ZeroCommit();
    error ZeroPrice();
    error ZeroPeriod();
    error ZeroTickets();
    error WrongPrice(uint256 paid, uint256 price);
    error EntryClosed(uint256 at, uint256 until);
    error NoTickets();
    error RevealTooEarly(uint256 at, uint256 from);
    error RevealClosed(uint256 at, uint256 until);
    error InvalidSeed(bytes32 got, bytes32 want);
    error SeedWithheld(uint256 at, uint256 until);
    error AlreadyDrawn();
    error PayoutFailed();

    event Entered(address indexed player, uint256 indexed ticket, uint256 total);
    event Drawn(address indexed winner, uint256 prize, bytes32 mixedSeed);

    /// @param guardian      비상 제동(신규 참가 차단만)
    /// @param seedCommit_   keccak256(abi.encodePacked(seed)) — 참가 모집 전 커밋
    /// @param ticketPrice_  티켓 가격
    /// @param enterPeriod_  참가 기간 (배포 시각부터)
    /// @param revealWindow_ 리빌 창구 (참가 마감부터)
    constructor(address guardian, bytes32 seedCommit_, uint256 ticketPrice_, uint48 enterPeriod_, uint48 revealWindow_)
        SimpleBrake(guardian)
    {
        if (seedCommit_ == bytes32(0)) revert ZeroCommit();
        if (ticketPrice_ == 0) revert ZeroPrice();
        if (enterPeriod_ == 0 || revealWindow_ == 0) revert ZeroPeriod();

        seedCommit = seedCommit_;
        ticketPrice = ticketPrice_;
        enterDeadline = uint48(block.timestamp) + enterPeriod_;
        revealDeadline = uint48(block.timestamp) + enterPeriod_ + revealWindow_;
    }

    /// @dev 참가비 밖 송금 거부 — 풀은 티켓 판매로만 커진다
    receive() external payable personalTestAccess {
        revert WrongPrice(msg.value, ticketPrice);
    }

    // ---------------------------------------------------------------- 참가 (진입 — brake 차단)

    /// @notice 티켓 1장을 산다. 여러 장은 여러 번 호출한다.
    function enter() external payable personalTestAccess nonReentrant whenEntryOpen {
        _checkPersonalTestNativeCap();
        if (msg.value != ticketPrice) revert WrongPrice(msg.value, ticketPrice);
        if (block.timestamp > enterDeadline) revert EntryClosed(block.timestamp, enterDeadline);

        players.push(msg.sender);
        emit Entered(msg.sender, players.length - 1, players.length);
    }

    // ---------------------------------------------------------------- 추첨 (판정)

    /// @notice 참가 마감 후 operator 시드를 공개해 추첨한다.
    ///         누구나 호출 가능 — 공개된 시드는 누구나 제출할 수 있다.
    function reveal(bytes32 seed) external personalTestAccess nonReentrant {
        if (drawn) revert AlreadyDrawn();
        if (block.timestamp <= enterDeadline) revert RevealTooEarly(block.timestamp, enterDeadline);
        if (block.timestamp > revealDeadline) revert RevealClosed(block.timestamp, revealDeadline);

        bytes32 got = keccak256(abi.encodePacked(seed));
        if (got != seedCommit) revert InvalidSeed(got, seedCommit);

        uint256 n = players.length;
        if (n == 0) revert NoTickets();

        bytes32 mixed = keccak256(abi.encode(seed, block.prevrandao));
        _payout(players[uint256(mixed) % n], mixed);
    }

    /// @notice 리빌 마감 후 추첨을 강행한다 — operator가 시드를
    ///         보류하면 시드 없이 prevrandao만으로 뽑는다.
    function drawWithoutSeed() external personalTestAccess nonReentrant {
        if (drawn) revert AlreadyDrawn();
        if (block.timestamp <= revealDeadline) revert SeedWithheld(block.timestamp, revealDeadline);

        uint256 n = players.length;
        if (n == 0) revert NoTickets();

        _payout(players[uint256(block.prevrandao) % n], bytes32(0));
    }

    // ---------------------------------------------------------------- 지급 (탈출 — brake 무관)

    /// @dev drawn 플래그를 먼저 올리고(CEI) 상금 전액을 보낸다.
    function _payout(address who, bytes32 mixed) private {
        _requirePersonalTestAccount(who);
        drawn = true; // CEI: 두 번째 추첨은 죽는다
        winner = who;
        emit Drawn(who, address(this).balance, mixed);

        (bool ok,) = who.call{value: address(this).balance}("");
        if (!ok) revert PayoutFailed();
    }

    // ---------------------------------------------------------------- 뷰 (F-04)

    function playerCount() external view returns (uint256) {
        return players.length;
    }
}

