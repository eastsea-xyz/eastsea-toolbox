// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice Minimal ERC-20 read surface the probe uses.
interface IBalance {
    function balanceOf(address account) external view returns (uint256);
}

/// @title Holder the probe moves tokens to and back from
/// @dev Separate address so the probe can observe a real third-party transfer
///      and so `park` can leave a balance sitting still across heights.
contract ProbeSink {
    address public immutable probe;

    constructor() {
        probe = msg.sender;
    }

    function send(address token, address to, uint256 amount) external returns (bool ok, bytes memory ret) {
        require(msg.sender == probe, "probe only");
        (ok, ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
    }
}

/// @title C0 token probe: what does this token actually do on a transfer?
/// @notice A personal measurement tool (Lane C0, gate G8). Its owner points it
///         at a token, it moves a small amount owner -> probe -> sink -> probe
///         -> owner, and it reports the return-data shape and both sides'
///         balance deltas of every leg. It never reverts because a token
///         misbehaves; it records what happened instead.
/// @dev What one transaction can and cannot show:
///      - Shows: missing code, reverting / false / empty ("no bool") returns,
///        fee-on-transfer on either leg, no-op "true" transfers, a frozen or
///        blocklisted probe or sink at this height, code hash.
///      - Cannot show: rebasing (balances change between transactions; use
///        `park` now and `parked` later), issuer upgrade or pause powers that
///        are not being used right now, or proxy admin keys (read EIP-1967
///        slots off-chain, e.g. `cast storage`). A clean report is evidence
///        about this height only, never an endorsement of the issuer.
///      The probe stores nothing: the owner and sink are immutables.
contract TokenProbe {
    uint8 public constant SHAPE_TRUE = 1;
    uint8 public constant SHAPE_EMPTY = 2;
    uint8 public constant SHAPE_FALSE_OR_OTHER = 3;
    uint8 public constant SHAPE_REVERTED = 4;

    struct Leg {
        uint8 shape;
        uint256 fromDebit; // how much the sender's balance fell
        uint256 toCredit; // how much the receiver's balance rose
    }

    struct Report {
        address token;
        uint256 amount;
        uint64 height;
        uint256 codeSize;
        bytes32 codeHash;
        Leg pull; // owner -> probe via transferFrom
        Leg push; // probe -> sink via transfer
        Leg back; // sink -> probe via transfer
        /// True only if every leg returned true/empty and moved exactly `amount`
        /// on both sides: what native/common ExactToken accepts.
        bool exact;
        uint256 refunded; // returned to the owner at the end
    }

    address public immutable owner;
    ProbeSink public immutable sink;

    event Probed(address indexed token, uint256 amount, bool exact, uint8 pullShape, uint8 pushShape, uint8 backShape);
    event Parked(address indexed token, uint256 sinkBalance);

    error OnlyOwner();

    constructor(address owner_) {
        owner = owner_;
        sink = new ProbeSink();
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @notice Owner must approve this probe for `amount` first.
    function probe(address token, uint256 amount) external onlyOwner returns (Report memory r) {
        r.token = token;
        r.amount = amount;
        r.height = uint64(block.number);
        r.codeSize = token.code.length;
        r.codeHash = token.codehash;
        if (r.codeSize == 0) {
            r.pull.shape = SHAPE_REVERTED;
            emit Probed(token, amount, false, r.pull.shape, 0, 0);
            return r;
        }
        address s = address(sink);

        // owner -> probe
        r.pull = _runLeg(token, owner, address(this), amount, true);

        // probe -> sink: send whatever actually arrived (at most `amount`)
        uint256 held = _bal(token, address(this));
        if (r.pull.shape <= SHAPE_EMPTY && held != 0) {
            r.push = _runLeg(token, address(this), s, held < amount ? held : amount, false);
            // sink -> probe: everything the sink holds
            uint256 sinkHeld = _bal(token, s);
            if (sinkHeld != 0) r.back = _runLeg(token, s, address(this), sinkHeld, false);
        }

        r.exact = _clean(r.pull, amount) && _clean(r.push, amount) && _clean(r.back, amount);
        r.refunded = _returnAll(token);
        emit Probed(token, amount, r.exact, r.pull.shape, r.push.shape, r.back.shape);
    }

    /// @notice Leave `amount` sitting in the sink so a later `parked` read can
    ///         reveal rebasing, demurrage or issuer seizure across heights.
    function park(address token, uint256 amount) external onlyOwner returns (uint256 sinkBalance) {
        (bool ok,) = token.call(abi.encodeWithSelector(0x23b872dd, owner, address(sink), amount));
        sinkBalance = ok ? _bal(token, address(sink)) : 0;
        emit Parked(token, sinkBalance);
    }

    function parked(address token) external view returns (uint256) {
        return _bal(token, address(sink));
    }

    /// @notice Return everything the probe and sink hold of `token` to the owner.
    function sweep(address token) external onlyOwner returns (uint256 returned) {
        uint256 s = _bal(token, address(sink));
        if (s != 0) sink.send(token, owner, s);
        returned = _returnAll(token);
    }

    function _returnAll(address token) internal returns (uint256 sent) {
        uint256 h = _bal(token, address(this));
        if (h == 0) return 0;
        uint256 before = h;
        (bool ok,) = token.call(abi.encodeWithSelector(0xa9059cbb, owner, h));
        if (!ok) return 0;
        uint256 afterBal = _bal(token, address(this));
        sent = before > afterBal ? before - afterBal : 0;
    }

    /// @dev One transfer leg. `pull` = transferFrom(from -> to) by the probe;
    ///      otherwise `from` (probe or sink) calls transfer(to).
    function _runLeg(address token, address from, address to, uint256 amount, bool pull)
        internal
        returns (Leg memory l)
    {
        uint256 fromBefore = _bal(token, from);
        uint256 toBefore = _bal(token, to);
        bool ok;
        bytes memory ret;
        if (pull) {
            (ok, ret) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        } else if (from == address(this)) {
            (ok, ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        } else {
            (ok, ret) = sink.send(token, to, amount);
        }
        l.shape = _shape(ok, ret);
        uint256 fromAfter = _bal(token, from);
        uint256 toAfter = _bal(token, to);
        l.fromDebit = fromBefore > fromAfter ? fromBefore - fromAfter : 0;
        l.toCredit = toAfter > toBefore ? toAfter - toBefore : 0;
    }

    function _shape(bool ok, bytes memory ret) internal pure returns (uint8) {
        if (!ok) return SHAPE_REVERTED;
        if (ret.length == 0) return SHAPE_EMPTY;
        if (ret.length == 32 && abi.decode(ret, (uint256)) == 1) return SHAPE_TRUE;
        return SHAPE_FALSE_OR_OTHER;
    }

    function _clean(Leg memory l, uint256 amount) internal pure returns (bool) {
        return (l.shape == SHAPE_TRUE || l.shape == SHAPE_EMPTY) && l.fromDebit == amount && l.toCredit == amount;
    }

    /// @dev balanceOf that cannot revert the probe.
    function _bal(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IBalance.balanceOf, (who)));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }
}
