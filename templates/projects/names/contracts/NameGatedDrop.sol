// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19 ^0.8.20 ^0.8.24;

// src/system/EastSeaNames.sol

// Vendored from eastsea-xyz/aether-node contracts/src/EastSeaNames.sol (2026-10-05).
// Only this provenance header was added; the contract body is unchanged.
// Upstream is dual-licensed MIT OR Apache-2.0 and stays so here.

/// The `.aeth` name service (docs/design/26-name-service.md, launch item E18):
/// fixed burn fees, no auction. Immutable, no owner, no admin, no upgrade, no
/// pause — the same rules for everyone, forever.
///
/// Registration is commit-reveal: `commit(keccak256(name, owner, salt,
/// relayer))` with the burned COMMIT_BOND, wait MIN_COMMIT_AGE, then
/// `register(name, owner, salt, relayer)` with the fee. The commitment binds
/// the name AND the owner AND the relayer, and its slot is bound to the
/// committer who posted the bond: an unexpired commitment is frozen — not
/// even its own committer can rewrite its timestamp — so a front-runner
/// cannot reset a victim's window by re-committing the same hash (A5-3), and
/// only the committer or the relayer they designated may reveal.
///
/// The fee is fixed by name length, paid in native AETH, and BURNED (sent to
/// BURN_ADDRESS). Nobody receives anything: no fee recipient, no treasury, no
/// premium or reserved names (12-launch-plan.md 원칙: 비수탁, 수수료 0). The burn
/// address is 0x…dEaD — the ecosystem's keyless convention; address(0) is
/// deliberately NOT used because it is the "unset" sentinel all over this
/// contract. Over-payment is refunded in the same call; state is settled
/// before either transfer (checks-effects-interactions), so re-entrancy from
/// the refund finds the commitment already spent.
///
/// COMMIT_BOND is burned when the commitment is posted, never refunded, and
/// credited toward the registration fee when the same committer reveals
/// within the window — an honest self-reveal pays exactly the fee overall.
/// It exists so this contract is never a free path for permanent state
/// writes (A5-1); the chain-level state fee is the real defence against
/// arbitrary storage-writing contracts. An expired, unrevealed commitment
/// can be reclaimed by anyone via `clear`.
///
/// Registration lasts REGISTRATION_PERIOD; anyone may renew (a gift to the
/// owner, priced at the same fee) up to GRACE_PERIOD past expiry, after which
/// the name is released and free to register again — with no stale resolver
/// data (the release is lazy: views go quiet immediately, and the next
/// registration sweeps the old record).
///
/// Owners are addresses, and EastSea accounts are smart accounts, so an owner
/// may well be a contract. This contract never calls its owners; ownership
/// grants no callback surface.
contract EastSeaNames {
    struct Record {
        address owner;
        uint64 expires;
        /// Kept so reverseOf can return the name without another lookup.
        string name;
        address pendingOwner;
        address addr;
        bytes32[] textKeys;
        mapping(bytes32 => string) texts;
    }

    error InvalidName();
    error InvalidOwner();
    error UnknownCommitment();
    error CommitTooNew(uint256 age);
    error CommitTooOld();
    error CommitmentActive();
    error CommitmentNotExpired();
    error NotCommitter();
    error WrongBondValue();
    error NameTaken();
    error Unregistered();
    error Released();
    error InsufficientFee(uint256 fee);
    error BurnFailed();
    error RefundFailed();
    error NotOwner();
    error NotPendingOwner();
    error BadTextKey();
    error TextValueTooLong();
    error TooManyTextRecords();
    error ReverseMismatch();

    event CommitmentMade(bytes32 indexed commitment, address indexed committer);
    event CommitmentCleared(bytes32 indexed commitment, address indexed by);
    event Registered(string name, bytes32 indexed node, address indexed owner, uint64 expires, uint256 fee);
    event Renewed(bytes32 indexed node, uint64 newExpires, uint256 fee);
    event Burned(uint256 amount);
    event TransferProposed(bytes32 indexed node, address indexed from, address indexed to);
    event TransferAccepted(bytes32 indexed node, address indexed from, address indexed to);
    event AddrSet(bytes32 indexed node, address indexed addr);
    event TextSet(bytes32 indexed node, string key, string value);
    event ReverseSet(address indexed account, bytes32 indexed node, string name);

    /// Keyless, codeless, nobody's. address(0) is reserved for "unset".
    address payable public constant BURN_ADDRESS = payable(0x000000000000000000000000000000000000dEaD);
    /// Short names are scarce, so they cost more to squat. 3 chars: 2, 4: 0.5, 5+: 0.1 AETH.
    uint256 public constant FEE_3 = 2 ether;
    uint256 public constant FEE_4 = 0.5 ether;
    uint256 public constant FEE_5_PLUS = 0.1 ether;
    uint256 public constant MIN_NAME_LENGTH = 3;
    uint256 public constant MAX_NAME_LENGTH = 32;
    uint256 public constant REGISTRATION_PERIOD = 365 days;
    /// After this the name is free again. Views go quiet at expiry+grace.
    uint64 public constant GRACE_PERIOD = 30 days;
    /// Commit must age this long (and no longer than MAX_COMMIT_AGE).
    uint64 public constant MIN_COMMIT_AGE = 60 seconds;
    uint64 public constant MAX_COMMIT_AGE = 24 hours;
    uint256 public constant MAX_TEXT_KEYS = 4;
    uint256 public constant TEXT_KEY_MAX_LENGTH = 32;
    uint256 public constant TEXT_VALUE_MAX_LENGTH = 128;
    /// Burned when a commitment is posted: never refunded, credited toward
    /// the fee on the committer's own reveal. One tenth of the lowest
    /// registration fee (FEE_5_PLUS), so an honest self-reveal pays exactly
    /// the fee overall — see docs/design/26-name-service.md (A5-1).
    uint256 public constant COMMIT_BOND = 0.01 ether;

    uint256 public totalBurned;
    /// commitment hash => (committer, timestamp). The slot is bound to the
    /// committer who paid its bond; frozen while unexpired (A5-3).
    mapping(bytes32 => Commitment) private _commitments;
    /// account => node claimed as its primary name.
    mapping(address => bytes32) private _reverse;
    mapping(bytes32 => Record) private _records;

    struct Commitment {
        /// Bond payer; only they (or the relayer in the hash) may reveal.
        address committer;
        uint64 committedAt;
    }

    // ---- commit-reveal ----

    /// Post a commitment hash and burn the bond. The hash must be
    /// `keccak256(name, owner, salt, relayer)`: the relayer is the one other
    /// account allowed to reveal (address(0) = nobody but the committer);
    /// `owner` stays inside the hash, so registering FOR someone else works.
    ///
    /// An existing unexpired commitment is frozen: re-committing the same
    /// hash reverts (CommitmentActive) no matter who asks — not even the
    /// original committer can move its timestamp (A5-3). Only a slot past
    /// MAX_COMMIT_AGE — dead for revealing anyway — may be replaced, and the
    /// replacement becomes a fresh commitment of its poster.
    function commit(bytes32 commitment) external payable {
        Commitment storage c = _commitments[commitment];
        if (c.committer != address(0) && block.timestamp - c.committedAt < MAX_COMMIT_AGE) {
            revert CommitmentActive();
        }
        if (msg.value != COMMIT_BOND) revert WrongBondValue();
        c.committer = msg.sender;
        c.committedAt = uint64(block.timestamp);
        totalBurned += COMMIT_BOND;
        emit CommitmentMade(commitment, msg.sender);
        emit Burned(COMMIT_BOND);
        (bool burned,) = BURN_ADDRESS.call{value: COMMIT_BOND}("");
        if (!burned) revert BurnFailed();
    }

    /// Reveal: register `name` for `owner` using the salt and relayer from
    /// the commitment. Only the committer or the designated relayer may
    /// reveal (the owner can still be anyone — it is inside the hash). The
    /// committer's burned bond is credited toward the fee, so a self-reveal
    /// pays fee - COMMIT_BOND here and exactly the fee overall; a relayer
    /// reveal pays the full fee. Any excess is refunded in the same call.
    function register(string calldata name, address owner, bytes32 salt, address relayer) external payable {
        if (!isValidName(name)) revert InvalidName();
        if (owner == address(0)) revert InvalidOwner();
        bytes32 commitment = keccak256(abi.encodePacked(name, owner, salt, relayer));
        Commitment storage c = _commitments[commitment];
        if (c.committer == address(0)) revert UnknownCommitment();
        if (msg.sender != c.committer && msg.sender != relayer) revert NotCommitter();
        uint256 age = block.timestamp - c.committedAt;
        if (age < MIN_COMMIT_AGE) revert CommitTooNew(age);
        if (age >= MAX_COMMIT_AGE) revert CommitTooOld();
        bytes32 node = nodeFor(name);
        Record storage r = _records[node];
        if (_live(r)) revert NameTaken();
        uint256 fee = feeFor(name); // fee >= FEE_5_PLUS > COMMIT_BOND
        uint256 due = msg.sender == c.committer ? fee - COMMIT_BOND : fee;
        if (msg.value < due) revert InsufficientFee(due);

        // Effects: everything settles before the transfers, so a re-entrant
        // call from the refund finds its commitment already spent.
        delete _commitments[commitment];
        _sweep(node, r); // a dead record sits here: clear its stale data
        r.owner = owner;
        r.expires = uint64(block.timestamp + REGISTRATION_PERIOD);
        r.name = name;
        totalBurned += due;
        emit Registered(name, node, owner, r.expires, fee);
        emit Burned(due);

        // Interactions: burn, then refund.
        (bool burned,) = BURN_ADDRESS.call{value: due}("");
        if (!burned) revert BurnFailed();
        uint256 refund = msg.value - due;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// Free the storage of a commitment that expired unrevealed (A5-1).
    /// Anyone may call once the reveal window is over; the slot is deleted
    /// and nothing is paid out — the bond was already burned, and paying a
    /// clearer's bounty would need a held (refundable) bond, i.e. a drain
    /// surface. After a clear the hash is free for a fresh commitment.
    function clear(bytes32 commitment) external {
        Commitment storage c = _commitments[commitment];
        if (c.committer == address(0)) revert UnknownCommitment();
        if (block.timestamp - c.committedAt < MAX_COMMIT_AGE) revert CommitmentNotExpired();
        delete _commitments[commitment];
        emit CommitmentCleared(commitment, msg.sender);
    }

    /// Extend by one REGISTRATION_PERIOD from the CURRENT expiry (not from
    /// now), by anyone, at the same fixed fee. During grace this means the
    /// lapsed time is the owner's loss.
    function renew(string calldata name) external payable {
        bytes32 node = nodeFor(name);
        Record storage r = _records[node];
        if (r.owner == address(0)) revert Unregistered();
        if (!_live(r)) revert Released();
        uint256 fee = feeFor(name);
        if (msg.value < fee) revert InsufficientFee(fee);

        uint64 newExpires = uint64(uint256(r.expires) + REGISTRATION_PERIOD);
        r.expires = newExpires;
        totalBurned += fee;
        emit Renewed(node, newExpires, fee);
        emit Burned(fee);

        (bool burned,) = BURN_ADDRESS.call{value: fee}("");
        if (!burned) revert BurnFailed();
        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    // ---- ownership ----

    /// Two-step transfer: propose (address(0) cancels), then the new owner
    /// accepts. A mistyped destination can be dropped before it does harm.
    function transferPropose(string calldata name, address to) external {
        bytes32 node = nodeFor(name);
        Record storage r = _records[node];
        _requireLiveOwner(r);
        r.pendingOwner = to;
        emit TransferProposed(node, r.owner, to);
    }

    function transferAccept(string calldata name) external {
        bytes32 node = nodeFor(name);
        Record storage r = _records[node];
        address previous = r.owner;
        if (!_live(r) || r.pendingOwner == address(0) || msg.sender != r.pendingOwner) revert NotPendingOwner();
        delete r.pendingOwner;
        r.owner = msg.sender;
        emit TransferAccepted(node, previous, msg.sender);
    }

    // ---- resolver records ----

    /// The name's primary address. Moving it retires any reverse claim the
    /// previous address held on this name.
    function setAddr(string calldata name, address a) external {
        bytes32 node = nodeFor(name);
        Record storage r = _records[node];
        _requireLiveOwner(r);
        address previous = r.addr;
        r.addr = a;
        if (previous != address(0) && previous != a && _reverse[previous] == node) delete _reverse[previous];
        emit AddrSet(node, a);
    }

    /// One bounded set of text records per name: at most MAX_TEXT_KEYS
    /// distinct keys (lowercase [a-z0-9-], 1-32 bytes), values up to
    /// TEXT_VALUE_MAX_LENGTH bytes. An empty value deletes (and frees the slot).
    function setText(string calldata name, string calldata key, string calldata value) external {
        bytes32 node = nodeFor(name);
        Record storage r = _records[node];
        _requireLiveOwner(r);
        if (!_validTextKey(bytes(key))) revert BadTextKey();
        if (bytes(value).length > TEXT_VALUE_MAX_LENGTH) revert TextValueTooLong();
        bytes32 k = keccak256(bytes(key));
        bool known = _hasKey(r, k);
        if (bytes(value).length == 0) {
            delete r.texts[k];
            if (known) _removeKey(r, k);
        } else {
            if (!known) {
                if (r.textKeys.length >= MAX_TEXT_KEYS) revert TooManyTextRecords();
                r.textKeys.push(k);
            }
            r.texts[k] = value;
        }
        emit TextSet(node, key, value);
    }

    /// Claim `name` as msg.sender's primary name. Only the name's owner can
    /// do this, and only when the name's address record IS msg.sender — so
    /// nobody can pin a name on someone else's address.
    function setReverse(string calldata name) external {
        bytes32 node = nodeFor(name);
        Record storage r = _records[node];
        _requireLiveOwner(r);
        if (r.addr != msg.sender) revert ReverseMismatch();
        _reverse[msg.sender] = node;
        emit ReverseSet(msg.sender, node, name);
    }

    // ---- pure ----

    /// Lowercase ASCII [a-z0-9-], 3-32 bytes, no leading/trailing hyphen, no
    /// double hyphen at positions 3-4 (the punycode `xn--` shape — homograph
    /// hygiene).
    function isValidName(string calldata name) public pure returns (bool) {
        bytes memory b = bytes(name);
        if (b.length < MIN_NAME_LENGTH || b.length > MAX_NAME_LENGTH) return false;
        if (b[0] == 0x2d || b[b.length - 1] == 0x2d) return false;
        if (b.length >= 4 && b[2] == 0x2d && b[3] == 0x2d) return false;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2d;
            if (!ok) return false;
        }
        return true;
    }

    /// The fixed fee for a name, by length. Invalid names never reach payment
    /// (register reverts first), so this simply buckets by length.
    function feeFor(string calldata name) public pure returns (uint256) {
        bytes memory b = bytes(name);
        if (b.length == 3) return FEE_3;
        if (b.length == 4) return FEE_4;
        return FEE_5_PLUS;
    }

    function nodeFor(string calldata name) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(name));
    }

    // ---- views ----

    /// address(0) once the name is past its grace period (released).
    function ownerOf(bytes32 node) external view returns (address) {
        Record storage r = _records[node];
        return _live(r) ? r.owner : address(0);
    }

    function pendingOwnerOf(bytes32 node) external view returns (address) {
        Record storage r = _records[node];
        return _live(r) ? r.pendingOwner : address(0);
    }

    /// Raw expiry (also readable for released names); grace runs to
    /// expires + GRACE_PERIOD.
    function expiresOf(bytes32 node) external view returns (uint64) {
        return _records[node].expires;
    }

    function addrOf(bytes32 node) external view returns (address) {
        Record storage r = _records[node];
        return _live(r) ? r.addr : address(0);
    }

    function textOf(bytes32 node, string calldata key) external view returns (string memory) {
        Record storage r = _records[node];
        if (!_live(r)) return "";
        return r.texts[keccak256(bytes(key))];
    }

    /// The account's primary name, but only while it is honest: the forward
    /// record must still be live and point back at the account. Stale claims
    /// answer "" (setAddr and the sweep also remove them eagerly).
    function reverseOf(address account) external view returns (string memory) {
        bytes32 node = _reverse[account];
        Record storage r = _records[node];
        if (!_live(r) || r.addr != account) return "";
        return r.name;
    }

    // ---- internals ----

    /// A record counts while owner is set and now < expires + grace.
    function _live(Record storage r) private view returns (bool) {
        return r.owner != address(0) && block.timestamp < uint256(r.expires) + GRACE_PERIOD;
    }

    function _requireLiveOwner(Record storage r) private view {
        if (!_live(r) || r.owner != msg.sender) revert NotOwner();
    }

    /// Clear a dead record so the next registration starts fresh: texts,
    /// pending transfer, address record, and the reverse claim it anchored.
    function _sweep(bytes32 node, Record storage r) private {
        if (r.addr != address(0) && _reverse[r.addr] == node) delete _reverse[r.addr];
        for (uint256 i = 0; i < r.textKeys.length; i++) {
            delete r.texts[r.textKeys[i]];
        }
        delete r.textKeys;
        delete r.owner;
        delete r.expires;
        delete r.pendingOwner;
        delete r.addr;
        // r.name stays; it is overwritten on the next registration.
    }

    function _validTextKey(bytes memory b) private pure returns (bool) {
        if (b.length == 0 || b.length > TEXT_KEY_MAX_LENGTH) return false;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2d;
            if (!ok) return false;
        }
        return true;
    }

    function _hasKey(Record storage r, bytes32 k) private view returns (bool) {
        for (uint256 i = 0; i < r.textKeys.length; i++) {
            if (r.textKeys[i] == k) return true;
        }
        return false;
    }

    function _removeKey(Record storage r, bytes32 k) private {
        for (uint256 i = 0; i < r.textKeys.length; i++) {
            if (r.textKeys[i] == k) {
                r.textKeys[i] = r.textKeys[r.textKeys.length - 1];
                r.textKeys.pop();
                return;
            }
        }
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

// src/names/NameGatedDrop.sol

/// @title 예제 15 — 이름 자격 드롭 (이름 서비스 연동)
/// @notice primary name(.aeth)을 가진 계정만 받을 수 있는 고정액
///         드롭. 자격 검증을 시스템 이름 서비스에 통째로 위임한다.
/// @dev
///  설계 결정 — 신원은 빌려 쓰고 상태는 만들지 않는다:
///   - 자격 증명을 자체 매핑으로 만들면(화이트리스트) 배포자가
///     명단 상태를 선불한다 (예제 13이 머클로 피한 비용).
///   - 여기서는 `names.reverseOf(msg.sender) != ""`이 자격의 전부다.
///     시스템 이름 서비스의 reverseOf는 **정직성 조건**까지 검사해
///     준다 — forward 레코드가 살아 있고 그 주소를 되돌아가는
///     경우만 이름을 반환한다. 만료·스웜·위조는 모두 ""다.
///   - 앱은 이름 문자열을 상태에 저장하지 않는다. 자격 판정에
///     필요한 건 "있는가"뿐이고, 청구 기록은 주소 비트 1개다.
///     이름은 Claimed 이벤트의 페이로드로만 남는다 — 문자열은
///     영구 상태(1B=1u)가 아니라 로그(스캔 가능, 회수 불가능)에.
///
///  조회 시점 원칙:
///   - 자격은 claim 트랜잭션이 실행되는 순간의 이름 서비스 상태로
///     판정된다. 등록 시점에 해석해 두면(캐시) 이름이 만료·이전된
///     뒤에도 자격이 남는다 — 스푸핑 표면이다.
///   - 이름을 이전받은 새 소유자는 자기 primary name이 그 이름이라면
///     청구할 수 있다. 자격의 주체는 어디까지나 "지금 그 이름을
///     대표하는 계정"이다.
///
///  F 매핑:
///   F-01: claim/sweep CEI + nonReentrant — claimed 비트를 전송보다 먼저.
///   F-02/F-03: native만. receive() 허용 — 풀 충전.
///   F-04: 자격 판정은 시스템 뷰 호출 1회 (reverseOf) — 순회 없음.
///   F-05: 7702 위임 EOA도 동일 — primary name은 계정 주소 기준.
///   F-06: names·distributor·deadline·dropAmount 전부 immutable.
///         distributor는 마감 후 잔여 수령인일 뿐 키가 아니다.
///   F-07: Claimed 이벤트 ≠ 청구 — 진실은 claimed 매핑.
///   F-08: 무작위성 없음 — 자격 배정은 이름 서비스가 이미 결정.
///
///  brake가 없는 이유: 진입(자금·권리 유입)이 없다 — 자격은 외부
///  시스템의 상태이고 이 컨트랙트의 상수는 배포 시 고정됐다.
///  claim(탈출)과 sweep(탈출)만 남는다 (예제 13과 동일 논리).
contract NameGatedDrop is ReentrancyGuard, PersonalTest {
    /// @dev 시스템 이름 서비스 — 자격의 원천
    EastSeaNames public immutable names;

    /// @dev 마감 후 잔여 회수 수령인 (배포 시 고정)
    address public immutable distributor;

    /// @dev 청구 마감
    uint48 public immutable deadline;

    /// @dev 1인당 지급액 (고정)
    uint256 public immutable dropAmount;

    /// @dev 청구 완료 비트 — 청구자당 1슬롯, 청구가 만든다
    mapping(address => bool) public claimed;

    /// @dev 지급 인원 — 스칼라 (예산 소진 조회용, 상수 시간)
    uint256 public claimCount;

    error ZeroAmount();
    error ZeroDistributor();
    error ZeroPeriod();
    error NoPrimaryName(address account);
    error AlreadyClaimed();
    error ClaimClosed(uint256 at, uint256 until);
    error InsufficientPool(uint256 needed, uint256 have);
    error ClaimTransferFailed();
    error SweepTooEarly(uint256 at, uint256 until);
    error SweepTransferFailed();

    event Claimed(address indexed user, string name);
    event Swept(address indexed distributor, uint256 amount);

    /// @param names_       시스템 이름 서비스 주소
    /// @param distributor_ 마감 후 잔여 수령인
    /// @param dropAmount_  1인당 지급액
    /// @param claimPeriod  청구 기간 (배포 시각부터)
    constructor(address names_, address distributor_, uint256 dropAmount_, uint48 claimPeriod) {
        if (dropAmount_ == 0) revert ZeroAmount();
        if (distributor_ == address(0)) revert ZeroDistributor();
        _requirePersonalTestAccount(distributor_);
        if (claimPeriod == 0) revert ZeroPeriod();

        names = EastSeaNames(names_);
        distributor = distributor_;
        dropAmount = dropAmount_;
        deadline = uint48(block.timestamp) + claimPeriod;
    }

    /// @dev 풀 충전 — 누구나 후원 가능 (claimCount와 무관)
    receive() external payable personalTestAccess {
        _checkPersonalTestNativeCap();
    }

    // ---------------------------------------------------------------- 청구 (탈출)

    /// @notice primary name을 가진 계정에 dropAmount를 지급한다.
    ///         자격·정직성 검증은 names.reverseOf가 대신한다.
    function claim() external personalTestAccess nonReentrant {
        if (claimed[msg.sender]) revert AlreadyClaimed();
        if (block.timestamp > deadline) revert ClaimClosed(block.timestamp, deadline);

        string memory name = names.reverseOf(msg.sender); // 정직한 primary name만
        if (bytes(name).length == 0) revert NoPrimaryName(msg.sender);
        if (address(this).balance < dropAmount) revert InsufficientPool(dropAmount, address(this).balance);

        claimed[msg.sender] = true; // CEI: 비트 먼저
        ++claimCount;
        emit Claimed(msg.sender, name); // 문자열은 로그에만 — 상태 아님

        (bool ok,) = msg.sender.call{value: dropAmount}("");
        if (!ok) revert ClaimTransferFailed();
    }

    // ---------------------------------------------------------------- 회수 (탈출)

    /// @notice 마감 후 잔여 전액을 distributor에게 인도한다. 누구나 호출.
    function sweep() external personalTestAccess nonReentrant {
        _requirePersonalTestAccount(distributor);
        if (block.timestamp <= deadline) revert SweepTooEarly(block.timestamp, deadline);

        uint256 amount = address(this).balance;
        (bool ok,) = distributor.call{value: amount}("");
        if (!ok) revert SweepTransferFailed();
        emit Swept(distributor, amount);
    }
}

