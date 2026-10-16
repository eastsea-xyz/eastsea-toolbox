// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20 ^0.8.24;

// lib/openzeppelin-contracts/contracts/utils/Context.sol

// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

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

// lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol

// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/draft-IERC6093.sol)

/**
 * @dev Standard ERC-20 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-20 tokens.
 */
interface IERC20Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC20InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC20InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC20InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `spender` to be approved. Used in approvals.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC20InvalidSpender(address spender);
}

/**
 * @dev Standard ERC-721 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-721 tokens.
 */
interface IERC721Errors {
    /**
     * @dev Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in ERC-20.
     * Used in balance queries.
     * @param owner Address of the current owner of a token.
     */
    error ERC721InvalidOwner(address owner);

    /**
     * @dev Indicates a `tokenId` whose `owner` is the zero address.
     * @param tokenId Identifier number of a token.
     */
    error ERC721NonexistentToken(uint256 tokenId);

    /**
     * @dev Indicates an error related to the ownership over a particular token. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param tokenId Identifier number of a token.
     * @param owner Address of the current owner of a token.
     */
    error ERC721IncorrectOwner(address sender, uint256 tokenId, address owner);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC721InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC721InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param tokenId Identifier number of a token.
     */
    error ERC721InsufficientApproval(address operator, uint256 tokenId);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC721InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC721InvalidOperator(address operator);
}

/**
 * @dev Standard ERC-1155 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-1155 tokens.
 */
interface IERC1155Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     * @param tokenId Identifier number of a token.
     */
    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC1155InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC1155InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param owner Address of the current owner of a token.
     */
    error ERC1155MissingApprovalForAll(address operator, address owner);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC1155InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC1155InvalidOperator(address operator);

    /**
     * @dev Indicates an array length mismatch between ids and values in a safeBatchTransferFrom operation.
     * Used in batch transfers.
     * @param idsLength Length of the array of token identifiers
     * @param valuesLength Length of the array of token amounts
     */
    error ERC1155InvalidArrayLength(uint256 idsLength, uint256 valuesLength);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/extensions/IERC20Metadata.sol)

/**
 * @dev Interface for the optional metadata functions from the ERC-20 standard.
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
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

// lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/ERC20.sol)

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.openzeppelin.com/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * The default value of {decimals} is 18. To change this, you should override
 * this function so it returns a different value.
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC-20
 * applications.
 */
abstract contract ERC20 is Context, IERC20, IERC20Metadata, IERC20Errors {
    mapping(address account => uint256) private _balances;

    mapping(address account => mapping(address spender => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the default value returned by this function, unless
     * it's overridden.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `value`.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `value` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Skips emitting an {Approval} event indicating an allowance update. This is not
     * required by the ERC. See {xref-ERC20-_approve-address-address-uint256-bool-}[_approve].
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `value`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `value`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                _balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                _totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                _balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates a `value` amount of tokens and assigns them to `account`, by transferring it from address(0).
     * Relies on the `_update` mechanism
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Relies on the `_update` mechanism.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead
     */
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /**
     * @dev Sets `value` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Variant of {_approve} with an optional flag to enable or disable the {Approval} event.
     *
     * By default (when calling {_approve}) the flag is set to true. On the other hand, approval changes made by
     * `_spendAllowance` during the `transferFrom` operation set the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the`transferFrom` operation can force the flag to
     * true using the following override:
     *
     * ```solidity
     * function _approve(address owner, address spender, uint256 value, bool) internal virtual override {
     *     super._approve(owner, spender, value, true);
     * }
     * ```
     *
     * Requirements are the same as {_approve}.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}

// src/amm/AmmFactory.sol

/// @notice 예제 4 — 상수곱(constant-product) AMM 팩토리.
/// @dev
///  페어 생성은 신규 진입이므로 brake(>= 1)에서 차단된다. 이미 만들어진
///  페어의 탈출(burn)은 팩토리 brake와 무관하게 항상 열려 있다 — 페어
///  컨트랙트가 이 규칙을 적용한다.
///  F-03: 무코드 주소로 페어를 만들 수 없다. 배포된 코드가 없는 토큰은
///  이체 자체가 불가능하고, 페어만 남아 상태 비용을 태운다.
contract AmmFactory is SimpleBrake {
    /// @dev tokenA/tokenB (정렬된) -> pair. 없으면 address(0).
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    error IdenticalTokens(address token);
    error ZeroTokenAddress();
    error TokenHasNoCode(address token);
    error PairExists(address pair);

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairCount);

    constructor(address guardian) SimpleBrake(guardian) {}

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /// @notice 새 페어를 만든다. tokenA/tokenB 순서는 임의로 넣어도 된다.
    function createPair(address tokenA, address tokenB)
        external
        personalTestAccess
        whenEntryOpen
        returns (address pair)
    {
        if (tokenA == tokenB) revert IdenticalTokens(tokenA);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroTokenAddress();
        // F-03: 코드 없는 토큰은 거부 — 페어 생성 후 첫 예치에서야 죽는
        // 좀비 페어를 만들지 않는다.
        if (token0.code.length == 0) revert TokenHasNoCode(token0);
        if (token1.code.length == 0) revert TokenHasNoCode(token1);
        if (getPair[token0][token1] != address(0)) revert PairExists(getPair[token0][token1]);

        pair = address(new AmmPair(IERC20(token0), IERC20(token1), this));
        _registerPersonalTestChild(pair);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }
}

// src/amm/AmmPair.sol

/// @notice 예제 4 — 상수곱 페어. LP 토큰은 일반 ERC-20이다.
/// @dev
///  유입량은 전부 잔액 차이(balance - reserve)로 측정한다 — F-02:
///  수수료 과징(fee-on-transfer) 토큰이 약속 금액보다 적게 도착해도
///  실제 도착량만큼만 LP/스왑이 정산되므로 좌초하지 않는다.
///  팩토리 brake: state 1 이상이면 mint(예치)과 swap(진입)이 차단되고
///  burn(회수)·skim(잔여 회수)은 항상 열려 있다. 탈출은 막지 않는다.
///  TWAP: price{0,1}CumulativeLast는 reserve 기반 순간가격의 시간 적산.
///  소비자는 두 시점의 차이를 경과 시간으로 나눠 평균가를 얻는다.
contract AmmPair is ERC20, ReentrancyGuard, PersonalTest {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    /// @dev 스왑 수수료 0.30% — getAmountOut의 997/1000와 짝을 이룬다.
    uint256 public immutable FEE_NUMERATOR;
    uint256 public constant FEE_DENOMINATOR = 1000;
    /// @dev 최소 유동성 잠금처 — 프라이빗 키가 없는 관례 주소.
    address private constant _DEAD = 0x000000000000000000000000000000000000dEaD;

    AmmFactory public immutable factory;
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    /// @dev slot 1: reserve 2개 + 타임스탬프 (Uniswap V2 레이아웃)
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    /// @dev slot 2-3: TWAP 적산치
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    error NotBraked(uint8 state);
    error InsufficientOutput();
    error ExcessiveOutput();
    error InsufficientLiquidity();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InvalidSwapAmounts();
    error TransferFailed();
    error ReserveOverflow();
    error FactoryBrakedNewEntry(uint8 state);
    error FactoryBrakedFull(uint8 state);

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, address indexed to, uint256 amount0, uint256 amount1);
    event Swap(
        address indexed sender,
        address indexed to,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    modifier factoryEntryOpen() {
        (uint8 state,,) = factory.brakeState();
        if (state >= 1) revert FactoryBrakedNewEntry(state);
        _;
    }

    constructor(IERC20 _token0, IERC20 _token1, AmmFactory _factory) ERC20("EastSea AMM LP", "EALP") {
        factory = _factory;
        FEE_NUMERATOR = personalTestEnabled ? FEE_DENOMINATOR : 997;
        token0 = _token0;
        token1 = _token1;
        _requirePersonalTestAccount(address(_factory));
        _registerPersonalTestToken(address(_token0));
        _registerPersonalTestToken(address(_token1));
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        (_reserve0, _reserve1) = (reserve0, reserve1);
        _blockTimestampLast = blockTimestampLast;
    }

    /// @notice 예치(라우터가 토큰을 미리 보낸 뒤 호출). LP는 to에게.
    function mint(address to) external personalTestAccess nonReentrant factoryEntryOpen returns (uint256 liquidity) {
        _requirePersonalTestAccount(to);
        _checkPersonalTestTokenCaps();
        // F-02: 유입량 = 잔액 - 리저브 (약속이 아니라 도착량 기준)
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1);
            // 최소 유동성보다 작으면 첫 예치를 거절 (0 유입 underflow 방지)
            if (liquidity <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
            liquidity -= MINIMUM_LIQUIDITY;
            // 최소 유동성은 영구 잠김 — 키 없는 dead 주소로 발행한다.
            // (OZ v5는 address(0) 수신을 금지한다)
            _mint(_DEAD, MINIMUM_LIQUIDITY);
        } else {
            liquidity = _min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);

        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice 회수(라우터가 LP를 미리 보낸 뒤 호출). 토큰은 to에게 직접.
    function burn(address to) external personalTestAccess nonReentrant returns (uint256 amount0, uint256 amount1) {
        _requirePersonalTestAccount(to);
        // 탈출 경로 — 팩토리 brake와 무관하게 항상 열려 있다
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        amount0 = (liquidity * balance0) / totalSupply();
        amount1 = (liquidity * balance1) / totalSupply();
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        _burn(address(this), liquidity);

        // F-03: 이체 대상 토큰은 페어 생성 시 코드가 확인됐다. 그래도
        // 반환값 strict 확인 — ERC-20 위반 토큰은 여기서 죽는다.
        (bool ok0, bytes memory ret0) = address(token0).call(abi.encodeCall(IERC20.transfer, (to, amount0)));
        if (!ok0 || (ret0.length != 0 && !abi.decode(ret0, (bool)))) revert TransferFailed();
        (bool ok1, bytes memory ret1) = address(token1).call(abi.encodeCall(IERC20.transfer, (to, amount1)));
        if (!ok1 || (ret1.length != 0 && !abi.decode(ret1, (bool)))) revert TransferFailed();

        balance0 = token0.balanceOf(address(this));
        balance1 = token1.balanceOf(address(this));
        _update(balance0, balance1);
        emit Burn(msg.sender, to, amount0, amount1);
    }

    /// @notice 스왑. 정확히 한쪽 out만 0이 아니어야 하고, 수령인은 to.
    /// @dev 라우터가 out 계산을 책임진다. 페어는 k 보존만 강제한다.
    function swap(uint256 amount0Out, uint256 amount1Out, address to)
        external
        personalTestAccess
        nonReentrant
        factoryEntryOpen
    {
        _requirePersonalTestAccount(to);
        _checkPersonalTestTokenCaps();
        if (amount0Out == 0 && amount1Out == 0) revert InvalidSwapAmounts();
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();

        // out 먼저 전달 (이후 k 검증이 남아 있다 — 재진입 이득 없음)
        if (amount0Out > 0) _safeTransfer(token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);

        // F-02: 유입량은 잔액 차이. k 보존 검증까지 _settleSwap에 위임.
        (uint256 amount0In, uint256 amount1In) = _settleSwap(_reserve0, _reserve1, amount0Out, amount1Out);

        _update(token0.balanceOf(address(this)), token1.balanceOf(address(this)));
        emit Swap(msg.sender, to, amount0In, amount1In, amount0Out, amount1Out);
    }

    /// @dev 스왑 후 잔액을 읽어 유입량을 계산하고, 수수료 보정 k 비감소를
    ///      강제한다. 유입량을 돌려준다 (이벤트용).
    function _settleSwap(uint112 reserve0_, uint112 reserve1_, uint256 amount0Out, uint256 amount1Out)
        private
        view
        returns (uint256 amount0In, uint256 amount1In)
    {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        amount0In = balance0 > reserve0_ - amount0Out ? balance0 - (reserve0_ - amount0Out) : 0;
        amount1In = balance1 > reserve1_ - amount1Out ? balance1 - (reserve1_ - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientOutput();

        // k 비감소 검증 — Uniswap V2 정식: 양쪽 밸런스에 1000 스케일,
        // 유입쪽에서 수수료(3/1000) 차감. 기준은 스왑 전 리저브의 곱.
        uint256 balance0Adjusted = balance0 * FEE_DENOMINATOR - (amount0In * (FEE_DENOMINATOR - FEE_NUMERATOR));
        uint256 balance1Adjusted = balance1 * FEE_DENOMINATOR - (amount1In * (FEE_DENOMINATOR - FEE_NUMERATOR));
        if (
            balance0Adjusted * balance1Adjusted
                < uint256(reserve0_) * uint256(reserve1_) * FEE_DENOMINATOR * FEE_DENOMINATOR
        ) {
            revert ExcessiveOutput();
        }
    }

    /// @notice 잔액-리저브 초과분(우연 입금 등)을 to로 꺼낸다. sync의 안전한 짝.
    function skim(address to) external personalTestAccess nonReentrant {
        _requirePersonalTestAccount(to);
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        _safeTransfer(token0, to, token0.balanceOf(address(this)) - _reserve0);
        _safeTransfer(token1, to, token1.balanceOf(address(this)) - _reserve1);
    }

    /// @notice 리저브를 현재 잔액으로 강제 재동기화. 토큰이 잔액을 스스로
    ///         늘린 뒤 복구하는 비상구. k는 줄어들 수 있다 — 문서 참조.
    function sync() external personalTestAccess nonReentrant {
        _checkPersonalTestTokenCaps();
        _update(token0.balanceOf(address(this)), token1.balanceOf(address(this)));
    }

    function _update(address from, address to, uint256 value) internal override {
        _requirePersonalTestAccount(msg.sender);
        if (from != address(0)) _requirePersonalTestAccount(from);
        // The original AMM minimum-liquidity burn remains an internal mint only.
        if (to != address(0) && !(from == address(0) && to == _DEAD)) _requirePersonalTestAccount(to);
        super._update(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal override {
        _requirePersonalTestAccount(msg.sender);
        _requirePersonalTestAccount(owner);
        if (value != 0) _requirePersonalTestAccount(spender);
        super._approve(owner, spender, value, emitEvent);
    }

    // ---- 내부 ----

    function _safeTransfer(IERC20 token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _update(uint256 balance0, uint256 balance1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert ReserveOverflow();
        (uint112 _reserve0, uint112 _reserve1, uint32 blockTimestampLast_) = getReserves();

        // TWAP: 직전 갱신 이후 경과 시간만큼 순간가격을 적산한다.
        uint32 timeElapsed = uint32(block.timestamp) - blockTimestampLast_;
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            price0CumulativeLast += (uint256(_reserve1) * 1e18 / _reserve0) * timeElapsed;
            price1CumulativeLast += (uint256(_reserve0) * 1e18 / _reserve1) * timeElapsed;
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp);
        emit Sync(reserve0, reserve1);
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

// src/amm/AmmRouter.sol

/// @notice 예제 4 — AMM 라우터. 유동성 공급·회수·경로 스왑의 진입점.
/// @dev
///  토큰 이동은 SafeToken(F-02/F-03 대응)으로만 한다. 페어가 없으면
///  addLiquidity 안에서 만든다. native(AETH) 스왑은 다루지 않는다 —
///  필요하면 래핑 토큰을 경로에 넣어라 (래핑 자체가 별도 예제 주제).
///  F-04: 경로 길이는 호출자가 준 path[] 배열에 한정된다 — 순회 뷰가
///  아니다. getAmountsOut은 path.length만큼만 계산한다.
contract AmmRouter is ReentrancyGuard, PersonalTest {
    using SafeToken for IERC20;

    AmmFactory public immutable factory;

    /// @dev AmmPair.FEE_NUMERATOR와 짝 — 상수는 타입 멤버로 접근할 수 없어 복제한다.
    uint256 private constant FEE_NUMERATOR = 997;
    uint256 private constant FEE_DENOMINATOR = 1000;

    error Expired();
    error InsufficientAmount();
    error InsufficientAmountA();
    error InsufficientAmountB();
    error ExcessiveAmountA();
    error ExcessiveAmountB();
    error InsufficientOutput(uint256 expected, uint256 actual);
    error InvalidPath();

    event LiquidityAdded(address indexed sender, address indexed pair, uint256 amountA, uint256 amountB);
    event LiquidityRemoved(address indexed sender, address indexed pair, uint256 amountA, uint256 amountB);

    constructor(AmmFactory _factory) {
        factory = _factory;
        _requirePersonalTestAccount(address(_factory));
    }

    // ---- 유동성 ----

    /// @notice 페어가 없으면 만들고, 원하는 비율로 유동성을 공급한다.
    /// @dev 비율 계산은 Uniswap V2와 동일한 quote 기준. 실제 예치는
    ///      SafeToken.pull의 도착량(delta) 기준 — F-02 안전.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external personalTestAccess nonReentrant returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        _requirePersonalTestAccount(to);
        if (block.timestamp > deadline) revert Expired();
        (AmmPair pair, uint256 reserveA, uint256 reserveB) = _pairForOrCreate(tokenA, tokenB);
        (amountA, amountB) = _optimalAmounts(amountADesired, amountBDesired, amountAMin, amountBMin, reserveA, reserveB);

        _fundPair(tokenA, tokenB, address(pair), amountA, amountB);
        liquidity = pair.mint(to);
        emit LiquidityAdded(msg.sender, address(pair), amountA, amountB);
    }

    /// @dev 사용자로부터 두 토큰을 끌어와 페어로 전달한다 (잔여분 포함).
    function _fundPair(address tokenA, address tokenB, address pair, uint256 amountA, uint256 amountB) private {
        _registerPersonalTestToken(tokenA);
        _registerPersonalTestToken(tokenB);
        _checkPersonalTestTokenDeposit(tokenA, amountA);
        IERC20(tokenA).pull(msg.sender, amountA);
        _checkPersonalTestTokenCaps();
        _checkPersonalTestTokenDeposit(tokenB, amountB);
        IERC20(tokenB).pull(msg.sender, amountB);
        _checkPersonalTestTokenCaps();
        IERC20(tokenA).push(pair, IERC20(tokenA).balanceOf(address(this)));
        IERC20(tokenB).push(pair, IERC20(tokenB).balanceOf(address(this)));
    }

    /// @dev 현재 리저브 비율에 맞춰 실제 예치액을 결정한다 (Uniswap V2 방식).
    function _optimalAmounts(
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 reserveA,
        uint256 reserveB
    ) private pure returns (uint256 amountA, uint256 amountB) {
        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }
        uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
        if (amountBOptimal <= amountBDesired) {
            if (amountBOptimal < amountBMin) revert ExcessiveAmountA();
            return (amountADesired, amountBOptimal);
        }
        uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
        if (amountAOptimal < amountAMin) revert ExcessiveAmountB();
        return (amountAOptimal, amountBDesired);
    }

    /// @notice LP를 반납하고 토큰을 회수한다. 탈출 — brake와 무관.
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external personalTestAccess nonReentrant returns (uint256 amountA, uint256 amountB) {
        _requirePersonalTestAccount(to);
        if (block.timestamp > deadline) revert Expired();
        AmmPair pair = _mustPair(tokenA, tokenB);

        IERC20(address(pair)).pull(msg.sender, liquidity);
        IERC20(address(pair)).push(address(pair), liquidity);
        (amountA, amountB) = pair.burn(to);

        if (amountA < amountAMin) revert InsufficientOutput(amountAMin, amountA);
        if (amountB < amountBMin) revert InsufficientOutput(amountBMin, amountB);
        emit LiquidityRemoved(msg.sender, address(pair), amountA, amountB);
    }

    // ---- 스왑 ----

    /// @notice path[0]을 정확히 amountIn 지불해 path[last]를 최소 amountOutMin 수령.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external personalTestAccess nonReentrant returns (uint256[] memory amounts) {
        _requirePersonalTestAccount(to);
        if (block.timestamp > deadline) revert Expired();
        amounts = getAmountsOut(amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) {
            revert InsufficientOutput(amountOutMin, amounts[amounts.length - 1]);
        }

        _checkPersonalTestTokenDeposit(path[0], amounts[0]);
        IERC20(path[0]).pull(msg.sender, amounts[0]);
        _checkPersonalTestTokenCaps();
        IERC20(path[0]).push(address(_mustPair(path[0], path[1])), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @notice FoT 토큰용 스왑 — 홉별 출력량을 견적 대신 페어의 실제 도착
    ///         잔액에서 관찰해 계산한다 (Uniswap V2의 supporting-fee 변형).
    /// @dev 마지막 홉에서도 최종 수령량을 다시 관찰할 수 없다(수신자 주소의
    ///      사전 잔액을 모른다). amountOutMin은 페어가 준 양 기준으로 검증된다 —
    ///      수신자에게 가는 마지막 이체에서 또 과징하는 토큰은 이 라우터의
    ///      관심 밖이다(문서 참조).
    function swapSupportingFeeOnTransfer(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external personalTestAccess nonReentrant {
        _requirePersonalTestAccount(to);
        if (block.timestamp > deadline) revert Expired();
        if (path.length < 2 || path.length > 4) revert InvalidPath();

        _checkPersonalTestTokenDeposit(path[0], amountIn);
        IERC20(path[0]).pull(msg.sender, amountIn);
        _checkPersonalTestTokenCaps();
        IERC20(path[0]).push(address(_mustPair(path[0], path[1])), IERC20(path[0]).balanceOf(address(this)));

        uint256 amountOut;
        for (uint256 i; i < path.length - 1; ++i) {
            bool lastHop = i == path.length - 2;
            address recipient = lastHop ? to : address(_mustPair(path[i + 1], path[i + 2]));
            amountOut = _observedHop(path[i], path[i + 1], recipient);
        }
        if (amountOut < amountOutMin) revert InsufficientOutput(amountOutMin, amountOut);
    }

    /// @dev 페어의 실제 도착량(reserve 대비 잔액 증가)으로 홉을 실행한다.
    function _observedHop(address input, address output, address recipient) private returns (uint256 amountOut) {
        AmmPair pair = _mustPair(input, output);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool inputIsToken0 = input < output;
        (uint256 reserveIn, uint256 reserveOut) =
            inputIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 amountInput = IERC20(input).balanceOf(address(pair)) - reserveIn;
        amountOut = getAmountOut(amountInput, reserveIn, reserveOut);
        (uint256 amount0Out, uint256 amount1Out) = inputIsToken0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        pair.swap(amount0Out, amount1Out, recipient);
    }

    /// @dev amounts는 이미 계산된 홉별 출력량. 중간 홉의 수령인은 다음
    ///      페어 주소다 (라우터를 거치지 않는다 — 가스·재진입 표면 최소화).
    ///      마지막 홉만 to에게 간다.
    function _swap(uint256[] memory amounts, address[] calldata path, address to) private {
        for (uint256 i; i < path.length - 1; ++i) {
            (address input, address output) = (path[i], path[i + 1]);
            AmmPair pair = _mustPair(input, output);
            (uint256 amount0Out, uint256 amount1Out) =
                input < output ? (uint256(0), amounts[i + 1]) : (amounts[i + 1], uint256(0));
            address recipient = i < path.length - 2 ? address(_mustPair(output, path[i + 2])) : to;
            pair.swap(amount0Out, amount1Out, recipient);
        }
    }

    // ---- 조회 ----

    /// @notice 견적. path는 [tokenIn, ..., tokenOut]. F-04: 배열 길이 한정.
    function getAmountsOut(uint256 amountIn, address[] calldata path) public view returns (uint256[] memory amounts) {
        if (path.length < 2 || path.length > 4) revert InvalidPath();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; ++i) {
            (, uint256 reserveIn, uint256 reserveOut) = _reservesOf(path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    /// @notice 상수곱 출력량 (수수료 0.30% 반영).
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        view
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidityPair();
        uint256 amountInWithFee = amountIn * (personalTestEnabled ? FEE_DENOMINATOR : FEE_NUMERATOR);
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    // ---- 내부 ----

    error InsufficientLiquidityPair();
    error PairNotFound(address tokenA, address tokenB);

    function _pairForOrCreate(address tokenA, address tokenB)
        private
        returns (AmmPair pair, uint256 reserveA, uint256 reserveB)
    {
        address existing = factory.getPair(tokenA, tokenB);
        if (existing == address(0)) {
            pair = AmmPair(factory.createPair(tokenA, tokenB));
        } else {
            pair = AmmPair(existing);
        }
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (reserveA, reserveB) = tokenA < tokenB ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _mustPair(address tokenA, address tokenB) private view returns (AmmPair) {
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound(tokenA, tokenB);
        return AmmPair(pair);
    }

    function _reservesOf(address tokenA, address tokenB)
        private
        view
        returns (AmmPair pair, uint256 reserveA, uint256 reserveB)
    {
        pair = _mustPair(tokenA, tokenB);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (reserveA, reserveB) = tokenA < tokenB ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }
}

