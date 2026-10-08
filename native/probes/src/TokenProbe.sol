// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {PersonalTest, IPersonalTestPolicy} from "toolbox-personal/PersonalTest.sol";
import {TransientLock} from "../../common/src/TransientLock.sol";

/// @notice Minimal ERC-20 read surface the probe uses.
interface IBalance {
    function balanceOf(address account) external view returns (uint256);
}

/// @title Holder the probe moves tokens to and back from
/// @dev Separate address so the probe can observe a real third-party transfer
///      and so `park` can leave a balance sitting still across heights.
contract ProbeSink is PersonalTest {
    address private immutable _probe;
    bytes32 private constant _SINK_STORAGE = keccak256("eastsea.toolbox.personal-probe.sink/1");

    struct SinkState {
        mapping(address => bool) registered;
    }

    error PersonalProbeUnlistedToken(address token);

    constructor() {
        _probe = msg.sender;
    }

    function probe() public view virtual returns (address) {
        return _probe;
    }

    function admitPersonalTestToken(address token) external personalTestAccess {
        require(msg.sender == probe(), "probe only");
        if (!_isPersonalTest()) revert PersonalTestInvalidPolicy();
        _registerPersonalTestToken(token);
        _sinkState().registered[token] = true;
    }

    function send(address token, address to, uint256 amount)
        external
        personalTestAccess
        returns (bool ok, bytes memory ret)
    {
        require(msg.sender == probe(), "probe only");
        _requirePersonalTestAccount(to);
        if (_isPersonalTest() && !_sinkState().registered[token]) revert PersonalProbeUnlistedToken(token);
        (ok, ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
    }

    function _sinkState() private pure returns (SinkState storage state) {
        bytes32 slot = _SINK_STORAGE;
        assembly { state.slot := slot }
    }
}

/// @dev The factory supplies the policy while the parent still has no runtime
///      code. The ordinary ProbeSink() constructor and getter ABI remain valid.
contract PersonalProbeSink is ProbeSink {
    address private immutable _parent;

    constructor(address parent) {
        if (!_isPersonalTest()) revert PersonalTestInvalidPolicy();
        _requirePersonalTestAccount(parent);
        _parent = parent;
    }

    function probe() public view override returns (address) {
        return _parent;
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
///      Ordinary probes store nothing: the owner and sink are immutables.
///      Personal probes cap both addresses together and record only their
///      owner's admitted inventory; recovery cannot sweep unsolicited gifts.
contract TokenProbe is PersonalTest, TransientLock {
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
    bytes32 private constant _PROBE_STORAGE = keccak256("eastsea.toolbox.personal-probe.inventory/1");

    struct ProbeState {
        mapping(address => bool) registered;
        address[] tokens;
        mapping(address => uint256) probeInventory;
        mapping(address => uint256) sinkInventory;
    }

    event Probed(address indexed token, uint256 amount, bool exact, uint8 pullShape, uint8 pushShape, uint8 backShape);
    event Parked(address indexed token, uint256 sinkBalance);

    error OnlyOwner();
    error PersonalProbeUnlistedToken(address token);
    error PersonalProbeZeroAmount();

    constructor(address owner_) {
        owner = _isPersonalTest() ? _exampleDeployer() : owner_;
        if (_isPersonalTest()) {
            sink = ProbeSink(
                IPersonalTestPolicy(personalTestAuthority)
                    .deployChild(
                        abi.encodePacked(type(PersonalProbeSink).creationCode, abi.encode(address(this))), bytes32(0)
                    )
            );
        } else {
            sink = new ProbeSink();
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @notice Owner must approve this probe for `amount` first.
    function probe(address token, uint256 amount) external personalTestAccess onlyOwner lock returns (Report memory r) {
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
        _preparePersonalToken(token, amount);
        address s = address(sink);

        // owner -> probe
        r.pull = _runLeg(token, owner, address(this), amount, true);
        _checkPersonalProbeCap(0);

        // probe -> sink: send whatever actually arrived (at most `amount`)
        uint256 held = _recoverable(token, address(this));
        if (r.pull.shape <= SHAPE_EMPTY && held != 0) {
            r.push = _runLeg(token, address(this), s, held < amount ? held : amount, false);
            _checkPersonalProbeCap(0);
            // sink -> probe: everything the sink holds
            uint256 sinkHeld = _recoverable(token, s);
            if (sinkHeld != 0) r.back = _runLeg(token, s, address(this), sinkHeld, false);
            _checkPersonalProbeCap(0);
        }

        r.exact = _clean(r.pull, amount) && _clean(r.push, amount) && _clean(r.back, amount);
        r.refunded = _returnAll(token);
        _checkPersonalProbeCap(0);
        emit Probed(token, amount, r.exact, r.pull.shape, r.push.shape, r.back.shape);
    }

    /// @notice Leave `amount` sitting in the sink so a later `parked` read can
    ///         reveal rebasing, demurrage or issuer seizure across heights.
    function park(address token, uint256 amount)
        external
        personalTestAccess
        onlyOwner
        lock
        returns (uint256 sinkBalance)
    {
        _preparePersonalToken(token, amount);
        uint256 ownerBefore = _isPersonalTest() ? _bal(token, owner) : 0;
        uint256 sinkBefore = _isPersonalTest() ? _bal(token, address(sink)) : 0;
        (bool ok,) = token.call(abi.encodeWithSelector(0x23b872dd, owner, address(sink), amount));
        sinkBalance = ok ? _bal(token, address(sink)) : 0;
        if (_isPersonalTest()) {
            uint256 ownerAfter = _bal(token, owner);
            uint256 sinkAfter = _bal(token, address(sink));
            _recordPersonalMovement(
                token,
                owner,
                address(sink),
                amount,
                ownerBefore > ownerAfter ? ownerBefore - ownerAfter : 0,
                sinkAfter > sinkBefore ? sinkAfter - sinkBefore : 0
            );
            _checkPersonalProbeCap(0);
        }
        emit Parked(token, sinkBalance);
    }

    function parked(address token) external view returns (uint256) {
        return _bal(token, address(sink));
    }

    /// @notice Ordinary probes return every balance. Personal probes recover
    ///         only inventory admitted from their owner, even after excess gifts.
    function sweep(address token) external personalTestAccess onlyOwner lock returns (uint256 returned) {
        if (_isPersonalTest() && !_probeState().registered[token]) revert PersonalProbeUnlistedToken(token);
        uint256 s = _recoverable(token, address(sink));
        if (s != 0) _runLeg(token, address(sink), owner, s, false);
        returned = _returnAll(token);
    }

    function _returnAll(address token) internal returns (uint256 sent) {
        uint256 h = _recoverable(token, address(this));
        if (h == 0) return 0;
        uint256 before = _bal(token, address(this));
        (bool ok,) = token.call(abi.encodeWithSelector(0xa9059cbb, owner, h));
        if (!ok) return 0;
        uint256 afterBal = _bal(token, address(this));
        sent = before > afterBal ? before - afterBal : 0;
        if (_isPersonalTest()) {
            uint256 available = _probeState().probeInventory[token];
            _probeState().probeInventory[token] = available - (sent < available ? sent : available);
        }
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
        _recordPersonalMovement(token, from, to, amount, l.fromDebit, l.toCredit);
    }

    function _preparePersonalToken(address token, uint256 amount) private {
        if (!_isPersonalTest()) return;
        if (amount == 0) revert PersonalProbeZeroAmount();
        _registerPersonalTestToken(token);
        ProbeState storage state = _probeState();
        if (!state.registered[token]) {
            state.registered[token] = true;
            state.tokens.push(token);
            sink.admitPersonalTestToken(token);
        }
        _checkPersonalProbeCap(amount);
    }

    /// @dev Both addresses and every admitted asset share the one configured
    ///      cap. Balance reads fail closed in personal mode for unmeasurable assets.
    function _checkPersonalProbeCap(uint256 incoming) private view {
        if (!_isPersonalTest()) return;
        uint256 nativeHeld = address(this).balance + address(sink).balance;
        if (nativeHeld > personalTestNativeCap) revert PersonalTestValueCap(nativeHeld, personalTestNativeCap);
        ProbeState storage state = _probeState();
        uint256 remaining = personalTestTokenCap;
        for (uint256 i; i < state.tokens.length; ++i) {
            uint256 held =
                IBalance(state.tokens[i]).balanceOf(address(this)) + IBalance(state.tokens[i]).balanceOf(address(sink));
            if (held > remaining) {
                revert PersonalTestValueCap(personalTestTokenCap - remaining + held, personalTestTokenCap);
            }
            remaining -= held;
        }
        if (incoming > remaining) {
            revert PersonalTestValueCap(personalTestTokenCap - remaining + incoming, personalTestTokenCap);
        }
    }

    function _recoverable(address token, address account) private view returns (uint256 held) {
        held = _bal(token, account);
        if (!_isPersonalTest()) return held;
        uint256 inventory =
            account == address(this) ? _probeState().probeInventory[token] : _probeState().sinkInventory[token];
        return held < inventory ? held : inventory;
    }

    function _recordPersonalMovement(
        address token,
        address from,
        address to,
        uint256 requested,
        uint256 debit,
        uint256 credit
    ) private {
        if (!_isPersonalTest()) return;
        ProbeState storage state = _probeState();
        uint256 available = from == owner
            ? requested
            : from == address(this) ? state.probeInventory[token] : state.sinkInventory[token];
        uint256 consumed = debit < available ? debit : available;
        if (from == address(this)) state.probeInventory[token] = available - consumed;
        else if (from == address(sink)) state.sinkInventory[token] = available - consumed;
        uint256 received = credit < consumed ? credit : consumed;
        if (to == address(this)) state.probeInventory[token] += received;
        else if (to == address(sink)) state.sinkInventory[token] += received;
    }

    function _probeState() private pure returns (ProbeState storage state) {
        bytes32 slot = _PROBE_STORAGE;
        assembly { state.slot := slot }
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
