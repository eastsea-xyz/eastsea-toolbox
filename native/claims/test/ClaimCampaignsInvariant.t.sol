// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {ClaimCampaigns} from "../src/ClaimCampaigns.sol";
import {TestToken} from "../../common/test/Tokens.sol";
import {MerkleBuilder} from "./MerkleBuilder.sol";

/// @notice Drives create / claim / close / prune / donate / time and keeps an
///         independent model. Every call's success or failure is predicted
///         from the model; a mismatch is recorded, so "exits always open"
///         (an entitled, backed, in-window claim or an eligible close never
///         fails) and "no unauthorised payout" are both checked.
contract ClaimsHandler is Test {
    ClaimCampaigns public claims;
    TestToken public token;
    address issuer = makeAddr("issuer");
    address refundTo = makeAddr("refundTo");

    struct Model {
        uint256 id;
        uint64 deadline;
        uint128 remaining;
        bool closed;
        address[] accts;
        uint128[] amts;
        bytes32[] leaves;
        bool[] paid;
    }

    Model[] internal models;
    uint256 public totalFunded;
    uint256 public totalClaimed;
    uint256 public totalRefunded;
    uint256 public mismatches;
    uint256 public donated;

    constructor(ClaimCampaigns c, TestToken t) {
        claims = c;
        token = t;
        t.mint(issuer, type(uint128).max);
        vm.prank(issuer);
        t.approve(address(c), type(uint256).max);
    }

    function liveRemainingSum() external view returns (uint256 s) {
        for (uint256 i; i < models.length; i++) {
            if (!models[i].closed) s += models[i].remaining;
        }
    }

    function count() external view returns (uint256) {
        return models.length;
    }

    function create(uint256 seed, uint256 n, uint256 pct, uint256 life) external {
        n = bound(n, 1, 16);
        pct = bound(pct, 30, 100);
        life = bound(life, 1, 40);
        uint256 id = claims.nextCampaign();
        models.push();
        Model storage m = models[models.length - 1];
        m.id = id;
        uint256 sum;
        for (uint256 i; i < n; i++) {
            m.accts.push(address(uint160(uint256(keccak256(abi.encode(seed, i, "a"))) | 1)));
            m.amts.push(uint128(1 + uint256(keccak256(abi.encode(seed, i))) % 1e24));
            m.leaves.push(claims.leafHash(id, i, m.accts[i], m.amts[i]));
            m.paid.push(false);
            sum += m.amts[i];
        }
        uint128 funding = uint128(sum * pct / 100);
        if (funding == 0) funding = 1;
        m.remaining = funding;
        m.deadline = uint64(block.number + life);
        bytes32 root = MerkleBuilder.root(m.leaves);
        vm.prank(issuer);
        claims.create(id, root, uint32(n), refundTo, m.deadline, funding, 0);
        totalFunded += funding;
    }

    function claim(uint256 cSeed, uint256 iSeed, bool tamper) external {
        if (models.length == 0) return;
        Model storage m = models[cSeed % models.length];
        uint256 i = iSeed % m.accts.length;
        uint128 amt = tamper ? m.amts[i] + 1 : m.amts[i];
        bool expectOk = !tamper && !m.closed && block.number <= m.deadline && !m.paid[i] && m.amts[i] <= m.remaining;
        bytes32[] memory p = MerkleBuilder.proof(m.leaves, i);
        uint256 before = token.balanceOf(m.accts[i]);
        try claims.claim(m.id, i, m.accts[i], amt, p) {
            if (!expectOk) mismatches++;
            if (token.balanceOf(m.accts[i]) - before != m.amts[i]) mismatches++;
            m.paid[i] = true;
            m.remaining -= m.amts[i];
            totalClaimed += m.amts[i];
        } catch {
            if (expectOk) mismatches++;
        }
    }

    function close(uint256 cSeed) external {
        if (models.length == 0) return;
        Model storage m = models[cSeed % models.length];
        bool expectOk = !m.closed && (block.number > m.deadline || m.remaining == 0);
        uint256 before = token.balanceOf(refundTo);
        try claims.close(m.id) {
            if (!expectOk) mismatches++;
            if (token.balanceOf(refundTo) - before != m.remaining) mismatches++;
            totalRefunded += m.remaining;
            m.remaining = 0;
            m.closed = true;
        } catch {
            if (expectOk) mismatches++;
        }
    }

    function prune(uint256 cSeed, uint256 count_) external {
        if (models.length == 0) return;
        Model storage m = models[cSeed % models.length];
        count_ = bound(count_, 1, 8);
        try claims.prune(m.id, 0, count_) {
            if (!m.closed) mismatches++;
        } catch {
            if (m.closed) mismatches++;
        }
    }

    function donate(uint256 amt) external {
        amt = bound(amt, 1, 1e24);
        token.mint(address(claims), amt);
        donated += amt;
    }

    function roll(uint256 k) external {
        vm.roll(block.number + bound(k, 1, 15));
    }
}

contract ClaimCampaignsInvariantTest is Test {
    ClaimsHandler h;
    ClaimCampaigns claims;
    TestToken token;

    function setUp() public {
        token = new TestToken();
        claims = new ClaimCampaigns(address(token), 0);
        h = new ClaimsHandler(claims, token);
        targetContract(address(h));
    }

    function invariant_modelAgreesWithEveryCall() public view {
        assertEq(h.mismatches(), 0);
    }

    function invariant_outstandingIsSumOfLiveRemaining() public view {
        assertEq(claims.outstanding(), h.liveRemainingSum());
    }

    function invariant_conservation() public view {
        assertEq(h.totalFunded(), h.totalClaimed() + h.totalRefunded() + claims.outstanding());
        assertEq(token.balanceOf(address(claims)), claims.outstanding() + h.donated());
    }

    function invariant_brakeOpenWithoutExternalLoss() public view {
        (uint8 s, address g,) = claims.brakeState();
        assertEq(s, 0);
        assertEq(g, address(0));
    }
}
