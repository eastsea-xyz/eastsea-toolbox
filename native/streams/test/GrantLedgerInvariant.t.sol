// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {GrantLedger} from "../src/GrantLedger.sol";
import {TestToken} from "../../common/test/Tokens.sol";

/// @notice Random creates (single and batch), claims, time jumps and
///         donations against an independent model of each grant. Every claim
///         outcome is predicted; mismatches are counted.
contract GrantsHandler is Test {
    GrantLedger public ledger;
    TestToken public token;
    address employer = makeAddr("employer");

    struct Model {
        uint256 id;
        address who;
        uint128 total;
        uint32 cliff;
        uint32 end;
        uint256 released;
    }

    Model[] internal models;
    uint256 public funded;
    uint256 public paid;
    uint256 public donated;
    uint256 public mismatches;

    constructor(GrantLedger l, TestToken t) {
        ledger = l;
        token = t;
        t.mint(employer, type(uint128).max);
        vm.prank(employer);
        t.approve(address(l), type(uint256).max);
    }

    function liveOwed() external view returns (uint256 s) {
        for (uint256 i; i < models.length; i++) {
            s += models[i].total - models[i].released;
        }
    }

    function receivedMatches() external view returns (bool) {
        for (uint256 i; i < models.length; i++) {
            // each model has a unique beneficiary
            if (token.balanceOf(models[i].who) != models[i].released) return false;
        }
        return true;
    }

    function _params(uint256 seed) internal view returns (GrantLedger.GrantParams memory p) {
        uint256 r = uint256(keccak256(abi.encode(seed, models.length)));
        p.beneficiary = address(uint160(uint256(keccak256(abi.encode("b", models.length, seed))) | 1));
        p.total = uint128(1 + r % 1e30);
        p.cliff = uint32(block.timestamp + (r >> 128) % 1000);
        p.start = p.cliff;
        p.end = p.cliff + uint32(1 + (r >> 64) % 100_000);
    }

    function _record(uint256 id, GrantLedger.GrantParams memory p) internal {
        models.push(Model({id: id, who: p.beneficiary, total: p.total, cliff: p.cliff, end: p.end, released: 0}));
        funded += p.total;
    }

    function create(uint256 seed) external {
        if (models.length >= 64) return;
        GrantLedger.GrantParams memory p = _params(seed);
        vm.prank(employer);
        uint256 id = ledger.create(p);
        _record(id, p);
    }

    function createBatch(uint256 seed, uint256 n) external {
        if (models.length >= 64) return;
        n = bound(n, 1, 8);
        GrantLedger.GrantParams[] memory ps = new GrantLedger.GrantParams[](n);
        for (uint256 i; i < n; i++) {
            ps[i] = _params(uint256(keccak256(abi.encode(seed, i))));
            // make beneficiaries unique within the batch
            ps[i].beneficiary = address(uint160(ps[i].beneficiary) ^ uint160(i << 8));
        }
        vm.prank(employer);
        uint256 first = ledger.createBatch(ps);
        for (uint256 i; i < n; i++) {
            _record(first + i, ps[i]);
        }
    }

    function _earned(Model storage m) internal view returns (uint256) {
        if (block.timestamp >= m.end) return m.total;
        if (block.timestamp <= m.cliff) return 0;
        return uint256(m.total) * (block.timestamp - m.cliff) / (m.end - m.cliff);
    }

    function claim(uint256 seed) external {
        if (models.length == 0) return;
        Model storage m = models[seed % models.length];
        uint256 due = _earned(m) - m.released;
        uint256 before = token.balanceOf(m.who);
        try ledger.claim(m.id) returns (uint256 got) {
            if (due == 0 || got != due) mismatches++;
            if (token.balanceOf(m.who) - before != due) mismatches++;
            m.released += due;
            paid += due;
        } catch {
            if (due != 0) mismatches++;
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 20_000));
    }

    function donate(uint256 amt) external {
        amt = bound(amt, 1, 1e24);
        token.mint(address(ledger), amt);
        donated += amt;
    }
}

contract GrantLedgerInvariantTest is Test {
    GrantsHandler h;
    GrantLedger ledger;
    TestToken token;

    function setUp() public {
        token = new TestToken();
        ledger = new GrantLedger(address(token), 0);
        h = new GrantsHandler(ledger, token);
        targetContract(address(h));
    }

    function invariant_everyClaimMatchesModel() public view {
        assertEq(h.mismatches(), 0);
        assertTrue(h.receivedMatches());
    }

    function invariant_outstandingEqualsUnpaidEntitlements() public view {
        assertEq(ledger.outstanding(), h.liveOwed());
    }

    function invariant_conservation() public view {
        assertEq(h.funded(), h.paid() + ledger.outstanding());
        assertEq(token.balanceOf(address(ledger)), ledger.outstanding() + h.donated());
    }

    function invariant_brakeOpenWithoutExternalLoss() public view {
        (uint8 s, address g,) = ledger.brakeState();
        assertEq(s, 0);
        assertEq(g, address(0));
    }
}
