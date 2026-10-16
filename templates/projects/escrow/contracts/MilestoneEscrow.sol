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

// src/escrow/MilestoneEscrow.sol

/// @title 예제 9 — 마일스톤 에스크로
/// @notice 구매자가 native coin을 예치하고, 결과에 만족할 때마다
///         마일스톤 승인으로 판매자에게 인출권을 넘긴다. 미승인 잔여는
///         언제든 구매자가 회수한다.
/// @dev
///  설계 결정 — 상태를 마일스톤 배열에 두지 않는다:
///   - 마일스톤 금액 배열을 스토리지에 저장하지 않는다. 금액은
///     승인 시점에 구매자가 amount로 지정한다 — "승인된 누적"만
///     상태로 남는다 (approvedTotal). 배열 N개 대신 스칼라 1개.
///   - 인덱스별 중복 승인만 해시 슬롯으로 막는다:
///     milestoneApproved[keccak256(dealId, index)].
///   - 마일스톤 개수는 생성 시 고정 — 예치 시점의 합의 구조가
///     거래 중 바뀌지 않게 하는 가드일 뿐, 금액 목록은 오프체인
///     계약서가 진실이다.
///
///  자금 흐름:
///   deposited == approvedTotal + refundable — 불변식.
///   판매자 인출 가능 = approvedTotal - withdrawnTotal.
///   구매자 환불 가능 = deposited - approvedTotal (승인분은 못 되돌린다).
///
///  F 매핑:
///   F-01: 상태변경 함수 전부 nonReentrant + CEI(스토리지 먼저,
///         native 전송 마지막).
///   F-02/F-03: native만 다룬다 — FoT·무코드 문제 영역 밖.
///   F-04: 뷰 상수 시간.
///   F-07: ApproveMilestone 이벤트 ≠ 승인 — 진실은 상태다.
contract MilestoneEscrow is SimpleBrake, ReentrancyGuard {
    /// @param buyer            예치자
    /// @param seller           인출권자
    /// @param deposited        남은 예치 (환불 시 감소 — 처분 가능 원금)
    /// @param approvedTotal    승인 누적 (단조 증가, 취소 없음)
    /// @param withdrawnTotal   판매자 인출 누적
    /// @param milestoneCount   합의된 마일스톤 수 (중복 승인 가드 상한)
    struct Deal {
        address buyer;
        address seller;
        uint128 deposited;
        uint128 approvedTotal;
        uint128 withdrawnTotal;
        uint64 milestoneCount;
    }

    uint256 public nextDealId = 1; // 0은 미사용 — 존재 검사를 위해

    mapping(uint256 => Deal) public deals;

    /// @dev keccak256(dealId, index) → 승인 여부. 인덱스당 1회 승인.
    mapping(bytes32 => bool) public milestoneApproved;

    error NotDealParty();
    error DealNotFound(uint256 dealId);
    error ZeroAmount();
    error ZeroMilestones();
    error ExceedsDeposit(uint256 wanted, uint256 refundable);
    error MilestoneAlreadyApproved(uint256 dealId, uint64 index);
    error IndexOutOfRange(uint64 index, uint64 count);
    error NothingToWithdraw();
    error NothingToRefund();
    error NativeTransferFailed();

    event DealCreated(
        uint256 indexed dealId, address indexed buyer, address indexed seller, uint256 amount, uint64 milestones
    );
    event MilestoneApproved(uint256 indexed dealId, uint64 index, uint256 amount);
    event SellerWithdrawn(uint256 indexed dealId, uint256 amount);
    event BuyerRefunded(uint256 indexed dealId, uint256 amount);

    constructor(address guardian) SimpleBrake(guardian) {}

    /// @dev 직접 송금 거부 — 자금은 createDeal의 회계를 거쳐야 한다.
    receive() external payable personalTestAccess {
        revert NativeTransferFailed();
    }

    // ---------------------------------------------------------------- 거래

    /// @notice 에스크로를 열고 전액을 예치한다 (진입 — brake 차단).
    ///         마일스톤 금액 목록은 오프체인 계약서에 두고, 여기는
    ///         개수만 고정한다.
    function createDeal(address seller, uint64 milestoneCount)
        external
        payable
        personalTestAccess
        nonReentrant
        whenEntryOpen
    {
        _checkPersonalTestNativeCap();
        _requirePersonalTestAccount(seller);
        if (msg.value == 0) revert ZeroAmount();
        if (seller == address(0) || seller == msg.sender) revert NotDealParty();
        if (milestoneCount == 0) revert ZeroMilestones();

        uint256 dealId = nextDealId;
        nextDealId = dealId + 1;
        deals[dealId] = Deal(msg.sender, seller, uint128(msg.value), 0, 0, milestoneCount);
        emit DealCreated(dealId, msg.sender, seller, msg.value, milestoneCount);
    }

    /// @notice 마일스톤 승인 — 이후 그 금액은 판매자 몫이 된다.
    ///         승인은 취소할 수 없다 (되돌림은 별도 합의·환불 절차).
    function approveMilestone(uint256 dealId, uint64 index, uint256 amount) external personalTestAccess nonReentrant {
        Deal storage d = deals[dealId];
        if (d.deposited == 0) revert DealNotFound(dealId);
        if (msg.sender != d.buyer) revert NotDealParty();
        if (amount == 0) revert ZeroAmount();
        if (index >= d.milestoneCount) revert IndexOutOfRange(index, d.milestoneCount);

        bytes32 key = keccak256(abi.encode(dealId, index));
        if (milestoneApproved[key]) revert MilestoneAlreadyApproved(dealId, index);

        uint256 refundable = uint256(d.deposited) - d.approvedTotal;
        if (amount > refundable) revert ExceedsDeposit(amount, refundable);

        milestoneApproved[key] = true;
        d.approvedTotal += uint128(amount); // 승인 즉시 판매자 귀속
        emit MilestoneApproved(dealId, index, amount);
    }

    // ---------------------------------------------------------------- 인출 (탈출 — brake 무관)

    /// @notice 승인 누적 중 아직 인출하지 않은 분을 판매자가 받는다.
    function sellerWithdraw(uint256 dealId) external personalTestAccess nonReentrant {
        Deal storage d = deals[dealId];
        if (d.deposited == 0) revert DealNotFound(dealId);
        if (msg.sender != d.seller) revert NotDealParty();

        uint256 due = uint256(d.approvedTotal) - d.withdrawnTotal;
        if (due == 0) revert NothingToWithdraw();

        d.withdrawnTotal = d.approvedTotal; // CEI: 스토리지 먼저
        _pay(d.seller, due);
        emit SellerWithdrawn(dealId, due);
    }

    /// @notice 미승인 잔여를 구매자가 회수한다. 승인분은 유지된다.
    function buyerRefund(uint256 dealId) external personalTestAccess nonReentrant {
        Deal storage d = deals[dealId];
        if (d.deposited == 0) revert DealNotFound(dealId);
        if (msg.sender != d.buyer) revert NotDealParty();

        uint256 refundable = uint256(d.deposited) - d.approvedTotal;
        if (refundable == 0) revert NothingToRefund();

        d.deposited = d.approvedTotal; // 회수분 제거 — 잔여는 승인분뿐
        _pay(d.buyer, refundable);
        emit BuyerRefunded(dealId, refundable);
    }

    // ---------------------------------------------------------------- 뷰 (F-04)

    function dealInfo(uint256 dealId)
        external
        view
        returns (address buyer, address seller, uint256 refundable, uint256 withdrawable)
    {
        Deal storage d = deals[dealId];
        return (d.buyer, d.seller, uint256(d.deposited) - d.approvedTotal, uint256(d.approvedTotal) - d.withdrawnTotal);
    }

    // ---------------------------------------------------------------- 내부

    function _pay(address to, uint256 amount) private {
        _requirePersonalTestAccount(to);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }
}

