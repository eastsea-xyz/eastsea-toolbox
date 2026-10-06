// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {GrantLedger} from "../src/GrantLedger.sol";
import {TestToken} from "../../common/test/Tokens.sol";

contract GrantLedgerFuzzTest is Test {
    TestToken token;
    GrantLedger ledger;
    address employer = makeAddr("employer");
    address alice = makeAddr("alice");

    function setUp() public {
        token = new TestToken();
        ledger = new GrantLedger(address(token), 0);
        token.mint(employer, type(uint128).max);
        vm.prank(employer);
        token.approve(address(ledger), type(uint256).max);
    }

    function _mk(uint128 total, uint32 cliff, uint32 end) internal returns (uint256 id) {
        vm.prank(employer);
        id = ledger.create(
            GrantLedger.GrantParams({beneficiary: alice, total: total, start: cliff, cliff: cliff, end: end})
        );
    }

    /// Earned is monotone in time, never above total, exactly floor of the
    /// linear share, and reaches total exactly at end. Full uint128/uint32 range.
    function testFuzz_earnedMonotoneBoundedFloor(uint128 total, uint32 cliff, uint32 dur, uint256 t1, uint256 t2)
        public
    {
        total = uint128(bound(total, 1, type(uint128).max));
        cliff = uint32(bound(cliff, 0, type(uint32).max - 1));
        dur = uint32(bound(dur, 1, type(uint32).max - cliff));
        uint32 end = cliff + dur;
        uint256 id = _mk(total, cliff, end);
        t1 = bound(t1, 0, uint256(type(uint32).max) + 365 days);
        t2 = bound(t2, t1, uint256(type(uint32).max) + 365 days);
        uint256 e1 = ledger.earnedAt(id, t1);
        uint256 e2 = ledger.earnedAt(id, t2);
        assertLe(e1, e2);
        assertLe(e2, total);
        if (t1 > cliff && t1 < end) {
            // floor: e1 * dur <= total * elapsed < (e1 + 1) * dur
            uint256 elapsed = t1 - cliff;
            assertLe(e1 * dur, uint256(total) * elapsed);
            assertGt((e1 + 1) * dur, uint256(total) * elapsed);
        }
        assertEq(ledger.earnedAt(id, end), total);
        assertEq(ledger.earnedAt(id, cliff), 0);
    }

    /// However many claims happen at whatever times, the beneficiary receives
    /// exactly total, never more, and the grant retires.
    function testFuzz_anyClaimScheduleSumsToTotal(uint128 total, uint32 dur, uint256 seed, uint8 k) public {
        total = uint128(bound(total, 1, type(uint128).max));
        dur = uint32(bound(dur, 1, 4 * 365 days));
        uint32 cliff = uint32(block.timestamp + 10);
        uint256 id = _mk(total, cliff, cliff + dur);
        uint256 n = bound(k, 1, 12);
        uint256 t = block.timestamp;
        uint256 paid;
        for (uint256 i; i < n; i++) {
            t += uint256(keccak256(abi.encode(seed, i))) % (uint256(dur) / n + 2);
            vm.warp(t);
            uint256 c = ledger.claimable(id);
            if (c == 0) continue;
            assertEq(ledger.claim(id), c);
            paid += c;
            assertLe(paid, total);
            assertEq(token.balanceOf(alice), paid);
        }
        vm.warp(uint256(cliff) + dur);
        if (paid < total) paid += ledger.claim(id);
        assertEq(paid, total);
        assertEq(ledger.outstanding(), 0);
        assertEq(ledger.grant(id).beneficiary, address(0));
    }

    /// Several grants never share backing: paying one leaves the others' sum
    /// intact.
    function testFuzz_grantsIsolated(uint128 a, uint128 b, uint32 when) public {
        a = uint128(bound(a, 1, type(uint128).max / 2));
        b = uint128(bound(b, 1, type(uint128).max / 2));
        uint32 c = uint32(block.timestamp);
        uint256 ia = _mk(a, c, c + 1000);
        uint256 ib = _mk(b, c, c + 2000);
        vm.warp(bound(when, uint256(c) + 1, uint256(c) + 3000));
        if (ledger.claimable(ia) != 0) ledger.claim(ia); // tiny grants may round to 0
        assertEq(token.balanceOf(address(ledger)), ledger.outstanding());
        assertEq(ledger.outstanding(), uint256(a) + b - token.balanceOf(alice));
        assertEq(ledger.grant(ib).released, 0);
    }
}
