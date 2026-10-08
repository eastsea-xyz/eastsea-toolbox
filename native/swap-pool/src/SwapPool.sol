// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {NativeBrake} from "../../common/src/NativeBrake.sol";
import {TransientLock} from "../../common/src/TransientLock.sol";
import {ExactToken, IERC20Min} from "../../common/src/ExactToken.sol";

/// @title SwapPool: minimal immutable constant-product pair
/// @notice Exchange one exact-transfer ERC-20 for another now, at a price
///         limit the person chose (`minOut` or `maxIn`) and before a
///         deadline. Anyone deploys a pair; anyone adds proportional
///         liquidity; only an LP's own account removes its shares, to any
///         receiver it names. The whole LP fee stays in reserves.
/// @dev Design: native/swap-pool/DESIGN.md. Immutable: the two tokens, the LP
///      fee (0-100 bps), the locked minimum, the brake document hash. No
///      owner, factory allowlist, protocol fee, proxy, hook, callback, flash
///      swap, price oracle, skim or rescue key.
///      Personal instances restrict actors and recipients to their wallet,
///      enforce aggregate custody caps, and always use a zero LP fee.
///
///      Storage (newly occupied slots):
///        slot 0 `_r`: reserve0 | reserve1 | lastHeightLow  (first liquidity)
///        slot 1 `_s`: totalShares | lockedShares           (first liquidity)
///        slot 2 `_m`: createdAt | latchedAt | reason       (deployment)
///        `shares[lp]`: one slot per newly nonzero LP, cleared on full exit
///      The locked minimum lives inside `totalShares`; it is never credited
///      to a sink mapping entry. The reentrancy lock is transient.
///
///      Brake predicate bits (INativeBrake): 1 a token's code hash changed,
///      2 a token balance is below its recorded reserve, 8 shares and
///      reserves disagree. While any bit holds, or once latched, `add` and
///      both swaps revert. `remove` never checks the brake; it pays pro rata
///      of actual balances and latches a live predicate itself, so the
///      evidence cannot be erased by syncing reserves.
contract SwapPool is NativeBrake, TransientLock {
    uint256 public constant FEE_DENOM = 10_000;
    uint256 public constant MAX_FEE_BPS = 100;
    uint128 public constant MIN_LOCKED_SHARES = 1_000;
    uint8 internal constant REASON_SUPPLY = 8;
    uint256 internal constant MAX112 = type(uint112).max;

    address public immutable token0;
    address public immutable token1;
    uint256 public immutable feeBps;
    bytes32 public immutable token0CodeHash;
    bytes32 public immutable token1CodeHash;

    struct Reserves {
        uint112 reserve0;
        uint112 reserve1;
        uint32 lastHeightLow;
    }

    struct Supply {
        uint128 totalShares;
        uint128 lockedShares;
    }

    struct BrakeMeta {
        uint64 createdAt;
        uint64 latchedAt;
        uint8 reason;
    }

    Reserves private _r;
    Supply private _s;
    BrakeMeta private _m;
    mapping(address => uint128) public shares;

    /// @notice Pool-side balance change of each token (+ in, - out).
    event Swap(address indexed sender, int256 delta0, int256 delta1);
    event Added(address indexed owner, uint256 amount0, uint256 amount1, uint256 shares);
    event Removed(address indexed owner, uint256 amount0, uint256 amount1, uint256 shares);

    error SameToken();
    error TokenHasNoCode(address token);
    error FeeTooHigh();
    error Expired();
    error BadToken();
    error BadRecipient();
    error ZeroAmount();
    error NotInitialized();
    error ReserveOverflow();
    error InsufficientLiquidity();
    error SlippageOut(uint256 amountOut, uint256 minOut);
    error SlippageIn(uint256 amountIn, uint256 maxIn);
    error SlippageShares(uint256 shares, uint256 minShares);
    error InitialSharesTooSmall();
    error NotEnoughShares(uint256 have, uint256 want);
    error TokenCallFailed(address token);
    error InvariantBroken();

    constructor(address tokenA, address tokenB, uint256 feeBps_, bytes32 brakeDocSha256) NativeBrake(brakeDocSha256) {
        if (tokenA == tokenB) revert SameToken();
        if (tokenA.code.length == 0) revert TokenHasNoCode(tokenA);
        if (tokenB.code.length == 0) revert TokenHasNoCode(tokenB);
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        token0 = tokenA;
        token1 = tokenB;
        feeBps = _isPersonalTest() ? 0 : feeBps_;
        token0CodeHash = tokenA.codehash;
        token1CodeHash = tokenB.codehash;
        _registerPersonalTestToken(tokenA);
        _registerPersonalTestToken(tokenB);
        _m.createdAt = _height();
    }

    // ------------------------------------------------------------------ views

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 lastHeightLow) {
        Reserves memory r = _r;
        return (r.reserve0, r.reserve1, r.lastHeightLow);
    }

    function totalShares() external view returns (uint128) {
        return _s.totalShares;
    }

    function lockedShares() external view returns (uint128) {
        return _s.lockedShares;
    }

    function brakeMeta() external view returns (uint64 createdAt, uint64 latchedAt, uint8 reason) {
        BrakeMeta memory m = _m;
        return (m.createdAt, m.latchedAt, m.reason);
    }

    /// @notice Output for an exact input at current reserves (no donation
    ///         absorption). Reverts where the swap would.
    function quoteExactInput(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        (uint256 rIn, uint256 rOut) = _ordered(tokenIn, _r.reserve0, _r.reserve1);
        return _outFor(amountIn, rIn, rOut);
    }

    /// @notice Input needed for an exact output at current reserves.
    function quoteExactOutput(address tokenIn, uint256 amountOut) external view returns (uint256 amountIn) {
        (uint256 rIn, uint256 rOut) = _ordered(tokenIn, _r.reserve0, _r.reserve1);
        return _inFor(amountOut, rIn, rOut);
    }

    // ------------------------------------------------------------------ swaps

    /// @notice Spend exactly `amountIn` of `tokenIn`; receive at least `minOut`.
    function swapExactInput(address tokenIn, uint256 amountIn, uint256 minOut, address recipient, uint64 deadline)
        external
        personalTestAccess
        lock
        returns (uint256 amountOut)
    {
        (uint256 rIn, uint256 rOut, bool zeroIn) = _enterSwap(tokenIn, recipient, deadline);
        amountOut = _outFor(amountIn, rIn, rOut);
        if (amountOut < minOut) revert SlippageOut(amountOut, minOut);
        _settleSwap(zeroIn, amountIn, amountOut, rIn, rOut, recipient);
    }

    /// @notice Receive exactly `amountOut`; spend at most `maxIn` of `tokenIn`.
    function swapExactOutput(address tokenIn, uint256 amountOut, uint256 maxIn, address recipient, uint64 deadline)
        external
        personalTestAccess
        lock
        returns (uint256 amountIn)
    {
        (uint256 rIn, uint256 rOut, bool zeroIn) = _enterSwap(tokenIn, recipient, deadline);
        amountIn = _inFor(amountOut, rIn, rOut);
        if (amountIn > maxIn) revert SlippageIn(amountIn, maxIn);
        _settleSwap(zeroIn, amountIn, amountOut, rIn, rOut, recipient);
    }

    function _enterSwap(address tokenIn, address recipient, uint64 deadline)
        internal
        returns (uint256 rIn, uint256 rOut, bool zeroIn)
    {
        if (block.timestamp > deadline) revert Expired();
        if (recipient == address(0) || recipient == address(this)) revert BadRecipient();
        _requirePersonalTestAccount(recipient);
        _requireEntryOpen();
        (uint256 r0, uint256 r1) = _absorb();
        if (r0 == 0) revert NotInitialized();
        zeroIn = tokenIn == token0;
        (rIn, rOut) = _ordered(tokenIn, r0, r1);
    }

    function _settleSwap(bool zeroIn, uint256 amountIn, uint256 amountOut, uint256 rIn, uint256 rOut, address to)
        internal
    {
        uint256 newIn = rIn + amountIn;
        uint256 newOut = rOut - amountOut;
        if (newIn > MAX112) revert ReserveOverflow();
        // Fee-adjusted constant product, checked independently of the quote.
        if ((rIn * FEE_DENOM + amountIn * (FEE_DENOM - feeBps)) * newOut < rIn * rOut * FEE_DENOM) {
            revert InvariantBroken();
        }
        (address tIn, address tOut) = zeroIn ? (token0, token1) : (token1, token0);
        _checkPersonalTestNativeCap();
        _checkPersonalTestTokenDeposit(tIn, amountIn);
        // Effects first: readers re-entering through a token see final reserves.
        if (zeroIn) _write(newIn, newOut);
        else _write(newOut, newIn);
        ExactToken.pullExact(tIn, msg.sender, amountIn);
        _checkPersonalTestTokenCaps();
        ExactToken.pushExact(tOut, to, amountOut);
        _checkPersonalTestTokenCaps();
        // Both amounts are below 2^112 (reserve bound), so the int casts are exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        (int256 i, int256 o) = (int256(amountIn), int256(amountOut));
        emit Swap(msg.sender, zeroIn ? i : -o, zeroIn ? -o : i);
    }

    /// @dev Floor division: the pool never pays more than the curve allows.
    function _outFor(uint256 amountIn, uint256 rIn, uint256 rOut) internal view returns (uint256 out) {
        if (amountIn == 0) revert ZeroAmount();
        if (rIn == 0 || rOut == 0) revert NotInitialized();
        if (amountIn > MAX112) revert ReserveOverflow();
        uint256 inWithFee = amountIn * (FEE_DENOM - feeBps);
        out = inWithFee * rOut / (rIn * FEE_DENOM + inWithFee);
        if (out == 0) revert ZeroAmount();
    }

    /// @dev Ceiling division: the trader always pays at least the curve price.
    function _inFor(uint256 amountOut, uint256 rIn, uint256 rOut) internal view returns (uint256) {
        if (amountOut == 0) revert ZeroAmount();
        if (rIn == 0 || rOut == 0) revert NotInitialized();
        if (amountOut >= rOut) revert InsufficientLiquidity();
        uint256 num = rIn * amountOut * FEE_DENOM;
        uint256 den = (rOut - amountOut) * (FEE_DENOM - feeBps);
        return (num + den - 1) / den;
    }

    // -------------------------------------------------------------- liquidity

    /// @notice Add liquidity, credited to the caller. First call fixes the
    ///         ratio (not a certified price) and locks MIN_LOCKED_SHARES.
    ///         Later calls take the proportional part of (max0, max1),
    ///         rounded up in the pool's favour, and leave the rest with you.
    function add(uint256 max0, uint256 max1, uint256 minShares, uint64 deadline)
        external
        personalTestAccess
        lock
        returns (uint256 used0, uint256 used1, uint256 minted)
    {
        if (block.timestamp > deadline) revert Expired();
        _requireEntryOpen();
        if (max0 == 0 || max1 == 0) revert ZeroAmount();
        if (max0 > MAX112 || max1 > MAX112) revert ReserveOverflow();
        (uint256 r0, uint256 r1) = _absorb();
        uint256 total = _s.totalShares;
        if (total == 0) {
            (used0, used1) = (max0, max1);
            uint256 root = _sqrt(max0 * max1);
            if (root <= MIN_LOCKED_SHARES) revert InitialSharesTooSmall();
            minted = root - MIN_LOCKED_SHARES;
            // root = sqrt(max0 * max1) < 2^112 because both maxima are < 2^112.
            // forge-lint: disable-next-line(unsafe-typecast)
            _s = Supply(uint128(root), MIN_LOCKED_SHARES);
        } else {
            uint256 a = max0 * total / r0;
            uint256 b = max1 * total / r1;
            minted = a < b ? a : b;
            if (minted == 0) revert ZeroAmount();
            used0 = _divUp(minted * r0, total);
            used1 = _divUp(minted * r1, total);
            if (total + minted > type(uint128).max) revert ReserveOverflow();
            // forge-lint: disable-next-line(unsafe-typecast)
            _s.totalShares = uint128(total + minted); // bounded on the line above
        }
        if (minted < minShares) revert SlippageShares(minted, minShares);
        if (r0 + used0 > MAX112 || r1 + used1 > MAX112) revert ReserveOverflow();
        // minted <= totalShares, which fits uint128 (checked above).
        // forge-lint: disable-next-line(unsafe-typecast)
        shares[msg.sender] += uint128(minted);
        _write(r0 + used0, r1 + used1);
        _checkPersonalTestNativeCap();
        _checkPersonalTestTokenDeposit(token0, used0);
        ExactToken.pullExact(token0, msg.sender, used0);
        _checkPersonalTestTokenDeposit(token1, used1);
        ExactToken.pullExact(token1, msg.sender, used1);
        _checkPersonalTestTokenCaps();
        emit Added(msg.sender, used0, used1, minted);
    }

    /// @notice Burn `amount` of your shares and receive your pro-rata part of
    ///         the pool's ACTUAL balances (donations included, deficits shared).
    ///         Open in every brake state; only token behaviour can block it.
    ///         `min0`/`min1` bound what actually leaves the pool for you.
    function remove(uint256 amount, uint256 min0, uint256 min1, address recipient, uint64 deadline)
        external
        personalTestAccess
        lock
        returns (uint256 out0, uint256 out1)
    {
        if (block.timestamp > deadline) revert Expired();
        if (recipient == address(0) || recipient == address(this)) revert BadRecipient();
        _requirePersonalTestAccount(recipient);
        if (amount == 0) revert ZeroAmount();
        uint256 have = shares[msg.sender];
        if (amount > have) revert NotEnoughShares(have, amount);
        // Record a live predicate before the books are synced to balances.
        _latchIfTripped();
        uint256 total = _s.totalShares;
        uint256 b0 = _cap(_balance(token0));
        uint256 b1 = _cap(_balance(token1));
        // Both differences are below their uint128 sources.
        // forge-lint: disable-next-line(unsafe-typecast)
        shares[msg.sender] = uint128(have - amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        _s.totalShares = uint128(total - amount);
        out0 = _pushOut(token0, recipient, amount * b0 / total);
        out1 = _pushOut(token1, recipient, amount * b1 / total);
        if (out0 < min0) revert SlippageOut(out0, min0);
        if (out1 < min1) revert SlippageOut(out1, min1);
        // Books follow what actually left: honest exact tokens leave exactly
        // b - share; a rounding or misbehaving token cannot strand the LP.
        _write(_cap(_balance(token0)), _cap(_balance(token1)));
        emit Removed(msg.sender, out0, out1, amount);
    }

    // ------------------------------------------------------------------ brake

    function _brakeReasons() internal view override returns (uint8 reasons) {
        if (token0.codehash != token0CodeHash || token1.codehash != token1CodeHash) reasons |= REASON_CODE_CHANGED;
        Reserves memory r = _r;
        if (_balance(token0) < r.reserve0 || _balance(token1) < r.reserve1) reasons |= REASON_DEFICIT;
        Supply memory s = _s;
        bool empty = r.reserve0 == 0 && r.reserve1 == 0;
        bool bad = s.totalShares == 0
            ? (!empty || s.lockedShares != 0)
            : (r.reserve0 == 0 || r.reserve1 == 0 || s.totalShares < s.lockedShares);
        if (bad) reasons |= REASON_SUPPLY;
    }

    function _brakeSince() internal view override returns (uint64) {
        return _m.latchedAt;
    }

    function _setBrakeSince(uint64 height) internal override {
        _m.latchedAt = height;
        _m.reason = _brakeReasons();
    }

    function _brakeUri() internal pure override returns (string memory) {
        return "native/swap-pool/SECURITY.md#brake";
    }

    function _latchIfTripped() internal {
        if (_m.latchedAt != 0) return;
        uint8 reasons = _brakeReasons();
        if (reasons == 0) return;
        uint64 h = _height();
        _m.latchedAt = h;
        _m.reason = reasons;
        emit BrakeLatched(h, reasons);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Entry paths run only with no deficit, so balances >= reserves.
    ///      Fold any surplus (donation, positive rebase) into reserves so it
    ///      belongs to the current LPs before price or shares are computed.
    function _absorb() internal returns (uint256 r0, uint256 r1) {
        r0 = _balance(token0);
        r1 = _balance(token1);
        if (r0 > MAX112 || r1 > MAX112) revert ReserveOverflow();
        Reserves memory r = _r;
        if (r0 != r.reserve0 || r1 != r.reserve1) _write(r0, r1);
    }

    function _write(uint256 r0, uint256 r1) internal {
        // Every caller bounds r0 and r1 by MAX112; the height keeps its low 32 bits on purpose.
        // forge-lint: disable-next-line(unsafe-typecast)
        _r = Reserves(uint112(r0), uint112(r1), uint32(block.number));
    }

    function _ordered(address tokenIn, uint256 r0, uint256 r1) internal view returns (uint256, uint256) {
        if (tokenIn == token0) return (r0, r1);
        if (tokenIn == token1) return (r1, r0);
        revert BadToken();
    }

    function _balance(address token) internal view returns (uint256) {
        return IERC20Min(token).balanceOf(address(this));
    }

    /// @dev Exit leg. Returns what actually left the pool (its own balance
    ///      debit), which `remove` checks against the LP's minimum. Neither
    ///      the receiver's credit nor exactness is required, so a token that
    ///      later starts charging a fee, or rounds like a rebasing token,
    ///      still lets LPs out. A reverting or false-returning token blocks it.
    function _pushOut(address token, address to, uint256 amount) internal returns (uint256 debit) {
        if (amount == 0) return 0;
        uint256 before = _balance(token);
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Min.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && (ret.length != 32 || abi.decode(ret, (uint256)) != 1))) {
            revert TokenCallFailed(token);
        }
        uint256 afterBal = _balance(token);
        debit = before > afterBal ? before - afterBal : 0;
    }

    function _cap(uint256 x) internal pure returns (uint256) {
        return x > MAX112 ? MAX112 : x;
    }

    function _height() internal view returns (uint64) {
        return block.number == 0 ? 1 : uint64(block.number);
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev Babylonian integer square root (floor).
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
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
}
