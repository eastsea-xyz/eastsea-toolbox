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

// src/lock/LinearVesting.sol

/// @title 예제 7-B — 자립형 선형 베스팅 (단일 그랜트)
/// @notice 배포 시 그랜트 전액을 예치하고 그대로 방치하는 1회성 베스팅.
///         운영자·회수·관리자가 없다 — 컨트랙트가 곧 그랜트다.
///         (투자자 어카운트, 창업자 보유분 잠금 등 1인용 인스턴스)
/// @dev
///  TokenTimeLock(배치 관리형)과의 대비:
///   - 사용자 상태가 claimed 1슬롯뿐이다. 초기 설계는 이마저 없애
///     claimed = total - token.balanceOf(this) 로 잔액에서 유도했으나,
///     제3자가 토큰을 기부해 잔액이 total을 넘기는 순간 지급누적이
///     0으로 포화되어 total 초과 지급이 가능해진다 (PoC:
///     test_vesting_toleratesDonation). 정확성을 위해 1슬롯을 택했다.
///   - brake가 없다: 어차피 claim(탈출)만 있고 진입이 없어 brake가
///     막을 것이 없다. 배치 컨트랙트에만 brake가 의미 있다.
///   - revoke 없음 — 그랜트는 비가역이다. 되돌릴 주체도 없다.
///
///  F 매핑:
///   F-01: claim nonReentrant + CEI(claimed 갱신 후 push).
///   F-02/F-03: SafeToken 경로, 생성자 무코드 거부.
///   F-04: vested/claimable 상수 시간.
contract LinearVesting is ReentrancyGuard, PersonalTest {
    uint256 private constant _MAX_UINT128 = type(uint128).max;

    IERC20 public immutable token;
    address public immutable beneficiary;
    uint128 public immutable total;
    uint48 public immutable start;
    uint48 public immutable cliff;
    uint48 public immutable duration;

    /// @dev 지급누적 — claim에서만 증가, vested 이하로 단조 증가한다
    uint128 private claimed;

    error ZeroAmount();
    error ZeroDuration();
    error AmountTooLarge(uint256 amount);

    event Claimed(address indexed beneficiary, uint256 amount);

    constructor(IERC20 token_, address beneficiary_, uint256 amount, uint256 cliffSec, uint256 durationSec) {
        if (address(token_).code.length == 0) revert ZeroAmount(); // F-03
        if (beneficiary_ == address(0)) revert ZeroAmount();
        _requirePersonalTestAccount(beneficiary_);
        if (amount == 0) revert ZeroAmount();
        if (amount > _MAX_UINT128) revert AmountTooLarge(amount);
        if (durationSec == 0 || cliffSec > durationSec) revert ZeroDuration();

        token = token_;
        beneficiary = beneficiary_;
        total = uint128(amount);
        start = uint48(block.timestamp);
        cliff = uint48(cliffSec);
        duration = uint48(durationSec);

        _checkPersonalTestTokenDeposit(address(token_), amount);
        SafeToken.pullExact(token_, _exampleDeployer(), amount); // 그랜트 전액 예치
        _checkPersonalTestTokenCaps();
    }

    /// @notice 수혜자에게 해제분을 지급한다. 누구나 호출할 수 있다
    ///         (가스 대낭) — 수령인은 언제나 beneficiary다.
    function claim() external personalTestAccess nonReentrant returns (uint256 paid) {
        _requirePersonalTestAccount(beneficiary);
        uint256 v = _vested();
        paid = v > claimed ? v - claimed : 0;
        if (paid > 0) {
            claimed = uint128(claimed + paid); // CEI: 갱신 먼저
            SafeToken.push(token, beneficiary, paid);
        }
        emit Claimed(beneficiary, paid);
    }

    // ---------------------------------------------------------------- 뷰 (F-04)

    function vested() external view returns (uint256) {
        return _vested();
    }

    /// @notice 지금 claim하면 나오는 양 = vested - 지급누적.
    function claimable() external view returns (uint256) {
        uint256 v = _vested();
        return v > claimed ? v - claimed : 0;
    }

    function _vested() private view returns (uint256) {
        uint256 elapsed = block.timestamp - start;
        if (elapsed <= cliff) return 0;
        if (elapsed >= duration) return total;
        return (total * (elapsed - cliff)) / (duration - cliff);
    }
}

