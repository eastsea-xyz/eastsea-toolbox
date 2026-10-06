// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {ClaimCampaigns} from "../src/ClaimCampaigns.sol";
import {TestToken} from "../../common/test/Tokens.sol";
import {MerkleBuilder} from "./MerkleBuilder.sol";

contract ClaimCampaignsFuzzTest is Test {
    TestToken token;
    ClaimCampaigns claims;
    address issuer = makeAddr("issuer");
    address refundTo = makeAddr("refundTo");

    function setUp() public {
        token = new TestToken();
        claims = new ClaimCampaigns(address(token), 0);
        token.mint(issuer, type(uint128).max);
        vm.prank(issuer);
        token.approve(address(claims), type(uint256).max);
    }

    function _build(uint256 n, uint256 seed, uint256 maxAmt)
        internal
        view
        returns (address[] memory a, uint128[] memory m, bytes32[] memory l, uint128 sum)
    {
        a = new address[](n);
        m = new uint128[](n);
        l = new bytes32[](n);
        uint256 id = claims.nextCampaign();
        for (uint256 i; i < n; i++) {
            a[i] = address(uint160(uint256(keccak256(abi.encode(seed, i, "acct")))));
            m[i] = uint128(1 + uint256(keccak256(abi.encode(seed, i))) % maxAmt);
            sum += m[i];
            l[i] = claims.leafHash(id, i, a[i], m[i]);
        }
    }

    /// Every leaf of a fully funded campaign pays exactly once, in any order,
    /// and nothing is left over or created.
    function testFuzz_fullCampaignConserves(uint256 n, uint256 seed, uint256 order) public {
        n = bound(n, 1, 48);
        (address[] memory a, uint128[] memory m, bytes32[] memory l, uint128 sum) = _build(n, seed, 1e30);
        vm.prank(issuer);
        uint256 id = claims.create(1, MerkleBuilder.root(l), uint32(n), refundTo, 10, sum, 0);
        uint256[] memory perm = new uint256[](n);
        for (uint256 i; i < n; i++) {
            perm[i] = i;
        }
        for (uint256 i = n; i > 1; i--) {
            uint256 j = uint256(keccak256(abi.encode(order, i))) % i;
            (perm[i - 1], perm[j]) = (perm[j], perm[i - 1]);
        }
        for (uint256 k; k < n; k++) {
            uint256 i = perm[k];
            claims.claim(id, i, a[i], m[i], MerkleBuilder.proof(l, i));
            assertEq(token.balanceOf(a[i]), m[i]);
        }
        assertEq(claims.outstanding(), 0);
        assertEq(token.balanceOf(address(claims)), 0);
        claims.close(id);
        assertEq(token.balanceOf(refundTo), 0);
    }

    /// Any single-bit change to any proof element, the index, the account or
    /// the amount is rejected.
    function testFuzz_tamperedClaimRejected(uint256 n, uint256 seed, uint256 idx, uint256 which, uint8 bitPos) public {
        n = bound(n, 2, 40);
        idx = bound(idx, 0, n - 1);
        (address[] memory a, uint128[] memory m, bytes32[] memory l, uint128 sum) = _build(n, seed, 1e24);
        vm.prank(issuer);
        uint256 id = claims.create(1, MerkleBuilder.root(l), uint32(n), refundTo, 10, sum, 0);
        bytes32[] memory p = MerkleBuilder.proof(l, idx);
        address acct = a[idx];
        uint128 amt = m[idx];
        uint256 index = idx;
        which = bound(which, 0, p.length + 2);
        if (which < p.length) {
            p[which] = p[which] ^ bytes32(uint256(1) << bitPos);
        } else if (which == p.length) {
            acct = address(uint160(acct) ^ uint160(1 << (bitPos % 160)));
        } else if (which == p.length + 1) {
            amt = amt ^ uint128(1 << (bitPos % 128));
            vm.assume(amt != 0);
        } else {
            index = idx ^ 1;
            vm.assume(index < n);
        }
        assertFalse(claims.verify(id, index, acct, amt, p));
        vm.expectRevert();
        claims.claim(id, index, acct, amt, p);
        assertEq(claims.outstanding(), sum);
    }

    /// The largest possible single entitlement pays without overflow.
    function testFuzz_maxAmountSingleLeaf(address acct, uint128 amt) public {
        vm.assume(acct != address(0) && acct != address(claims) && acct != issuer);
        amt = uint128(bound(amt, type(uint128).max - 1e6, type(uint128).max));
        bytes32[] memory l = new bytes32[](1);
        l[0] = claims.leafHash(1, 0, acct, amt);
        vm.prank(issuer);
        uint256 id = claims.create(1, l[0], 1, refundTo, 10, amt, 0);
        claims.claim(id, 0, acct, amt, new bytes32[](0));
        assertEq(token.balanceOf(acct), amt);
        assertEq(claims.outstanding(), 0);
    }

    /// Leaf commitments are unique per (campaign, index, account, amount).
    function testFuzz_leafDomainBinding(uint64 id, uint256 index, address acct, uint128 amt, uint8 f) public view {
        bytes32 base = claims.leafHash(id, index, acct, amt);
        f = f % 4;
        bytes32 other;
        if (f == 0) other = claims.leafHash(uint256(id) + 1, index, acct, amt);
        else if (f == 1) other = claims.leafHash(id, index ^ 1, acct, amt);
        else if (f == 2) other = claims.leafHash(id, index, address(uint160(acct) ^ 1), amt);
        else other = claims.leafHash(id, index, acct, uint256(amt) ^ 1);
        assertTrue(base != other);
    }
}
