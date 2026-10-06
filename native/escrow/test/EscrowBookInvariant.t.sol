// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {EscrowBook} from "../src/EscrowBook.sol";
import {TestToken} from "../../common/test/Tokens.sol";

/// @notice Every action is attempted by a randomly chosen actor (buyer,
///         seller, stranger or arbiter) at random times. An independent model
///         predicts success or failure and the exact payout; any disagreement
///         is counted. This checks authorisation, deadlines, single
///         resolution, single payout and "exits always open" (a payout or
///         lapse the model allows never fails) together.
contract EscrowHandler is Test {
    EscrowBook public book;
    TestToken public token;
    address public judge;
    address[3] actors;

    uint8 constant OFFERED = 1;
    uint8 constant ACCEPTED = 2;
    uint8 constant DISPUTED = 3;
    uint8 constant RESOLVED = 4;
    uint8 constant GONE = 5;

    struct M {
        uint256 id;
        address buyer;
        address seller;
        uint128 amount;
        uint64 clock;
        uint64 deliverBy;
        uint8 policy;
        uint8 phase;
        uint128 award;
        uint8 paid;
        uint64 round;
        uint128 pAward;
        address proposer;
    }

    M[] internal ms;
    uint256 public funded;
    uint256 public paidOut;
    uint256 public mismatches;
    uint256 public resolutions;

    constructor(EscrowBook b, TestToken t, address j) {
        book = b;
        token = t;
        judge = j;
        for (uint256 i; i < 3; i++) {
            actors[i] = address(uint160(0xA000 + i));
            t.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            t.approve(address(b), type(uint256).max);
        }
    }

    function _who(uint256 s, M storage m) internal view returns (address) {
        uint256 k = s % 4;
        if (k == 0) return m.buyer;
        if (k == 1) return m.seller;
        if (k == 2) return judge;
        return address(0xBAD);
    }

    function liability() external view returns (uint256 s) {
        for (uint256 i; i < ms.length; i++) {
            M storage m = ms[i];
            if (m.phase == GONE) continue;
            if (m.phase != RESOLVED) {
                s += m.amount;
            } else {
                if (m.paid & 1 == 0) s += m.award;
                if (m.paid & 2 == 0) s += m.amount - m.award;
            }
        }
    }

    function create(uint256 seed, uint128 amount, uint32 aw, uint32 dw, bool pol) external {
        if (ms.length >= 40) return;
        M memory n;
        n.buyer = actors[seed % 3];
        n.seller = actors[(seed % 3 + 1 + (seed >> 8) % 2) % 3];
        n.amount = uint128(bound(amount, 1, 1e24));
        n.clock = uint64(block.timestamp) + uint64(bound(aw, 1, 3 days));
        n.deliverBy = n.clock + uint64(bound(dw, 1, 10 days));
        n.policy = pol ? 1 : 0;
        n.phase = OFFERED;
        vm.prank(n.buyer);
        n.id = book.create(n.seller, n.amount, n.clock, n.deliverBy, n.policy, keccak256(abi.encode(seed)));
        ms.push(n);
        funded += n.amount;
    }

    function _pick(uint256 i) internal view returns (bool, uint256) {
        if (ms.length == 0) return (false, 0);
        return (true, i % ms.length);
    }

    function _check(bool ok, bool expectOk) internal {
        if (ok != expectOk) mismatches++;
    }

    function _resolve(M storage m, uint128 award) internal {
        m.phase = RESOLVED;
        m.award = award;
        m.paid = (award == 0 ? 1 : 0) | (award == m.amount ? 2 : 0);
        m.round = 0;
        resolutions++;
    }

    function accept(uint256 i, uint256 w) external {
        (bool any, uint256 k) = _pick(i);
        if (!any) return;
        M storage m = ms[k];
        address who = _who(w, m);
        bool expectOk = m.phase == OFFERED && who == m.seller && block.timestamp < m.clock;
        vm.prank(who);
        try book.accept(m.id) {
            _check(true, expectOk);
            m.phase = ACCEPTED;
        } catch {
            _check(false, expectOk);
        }
    }

    function cancel(uint256 i, uint256 w) external {
        (bool any, uint256 k) = _pick(i);
        if (!any) return;
        M storage m = ms[k];
        address who = _who(w, m);
        bool expectOk = m.phase == OFFERED && (who == m.buyer || block.timestamp >= m.clock);
        vm.prank(who);
        try book.cancel(m.id) {
            _check(true, expectOk);
            _resolve(m, 0);
        } catch {
            _check(false, expectOk);
        }
    }

    function releaseOrRefund(uint256 i, uint256 w, bool rel) external {
        (bool any, uint256 k) = _pick(i);
        if (!any) return;
        M storage m = ms[k];
        address who = _who(w, m);
        bool open = m.phase == ACCEPTED || m.phase == DISPUTED;
        bool expectOk = open && who == (rel ? m.buyer : m.seller);
        vm.prank(who);
        (bool ok,) =
            address(book).call(abi.encodeWithSelector(rel ? book.release.selector : book.refund.selector, m.id));
        _check(ok, expectOk);
        if (ok) _resolve(m, rel ? m.amount : 0);
    }

    function propose(uint256 i, uint256 w, uint128 award) external {
        (bool any, uint256 k) = _pick(i);
        if (!any) return;
        M storage m = ms[k];
        address who = _who(w, m);
        award = uint128(bound(award, 0, uint256(m.amount) + 1));
        bool open = m.phase == ACCEPTED || m.phase == DISPUTED;
        bool expectOk = open && (who == m.buyer || who == m.seller) && award <= m.amount;
        vm.prank(who);
        try book.propose(m.id, award) {
            _check(true, expectOk);
            m.round++;
            m.pAward = award;
            m.proposer = who;
        } catch {
            _check(false, expectOk);
        }
    }

    function acceptProposal(uint256 i, uint256 w, bool stale) external {
        (bool any, uint256 k) = _pick(i);
        if (!any) return;
        M storage m = ms[k];
        address who = _who(w, m);
        uint64 round = stale ? m.round + 1 : m.round;
        bool open = m.phase == ACCEPTED || m.phase == DISPUTED;
        bool expectOk = open && m.round != 0 && !stale && (who == m.buyer || who == m.seller) && who != m.proposer;
        vm.prank(who);
        try book.acceptProposal(m.id, round, m.pAward) {
            _check(true, expectOk);
            _resolve(m, m.pAward);
        } catch {
            _check(false, expectOk);
        }
    }

    function dispute(uint256 i, uint256 w) external {
        (bool any, uint256 k) = _pick(i);
        if (!any) return;
        M storage m = ms[k];
        address who = _who(w, m);
        bool expectOk = m.phase == ACCEPTED && (who == m.buyer || who == m.seller) && block.timestamp < m.deliverBy;
        vm.prank(who);
        try book.dispute(m.id) {
            _check(true, expectOk);
            m.phase = DISPUTED;
            m.clock = uint64(block.timestamp) + book.rulingDuration();
        } catch {
            _check(false, expectOk);
        }
    }

    function rule(uint256 i, uint256 w, uint128 award) external {
        (bool any, uint256 k) = _pick(i);
        if (!any) return;
        M storage m = ms[k];
        address who = _who(w, m);
        award = uint128(bound(award, 0, m.amount));
        bool expectOk = m.phase == DISPUTED && who == judge && block.timestamp < m.clock;
        vm.prank(who);
        try book.rule(m.id, award) {
            _check(true, expectOk);
            _resolve(m, award);
        } catch {
            _check(false, expectOk);
        }
    }

    function timeout(uint256 i) external {
        (bool any, uint256 k) = _pick(i);
        if (!any) return;
        M storage m = ms[k];
        bool expectOk = (m.phase == ACCEPTED && block.timestamp >= m.deliverBy)
            || (m.phase == DISPUTED && block.timestamp >= m.clock);
        try book.resolveTimeout(m.id) {
            _check(true, expectOk);
            _resolve(m, m.policy == 1 ? m.amount : 0);
        } catch {
            _check(false, expectOk);
        }
    }

    function pay(uint256 i, bool toSeller) external {
        (bool any, uint256 k) = _pick(i);
        if (!any) return;
        M storage m = ms[k];
        uint8 flag = toSeller ? 1 : 2;
        bool expectOk = m.phase == RESOLVED && m.paid & flag == 0;
        address to = toSeller ? m.seller : m.buyer;
        uint256 due = toSeller ? m.award : m.amount - m.award;
        uint256 before = token.balanceOf(to);
        try book.pay(m.id, toSeller) {
            _check(true, expectOk);
            if (token.balanceOf(to) - before != due) mismatches++;
            paidOut += due;
            m.paid |= flag;
            if (m.paid == 3) m.phase = GONE;
        } catch {
            _check(false, expectOk);
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 2 days));
    }
}

contract EscrowBookInvariantTest is Test {
    EscrowHandler h;
    EscrowBook book;
    TestToken token;

    function setUp() public {
        vm.warp(1_000_000);
        token = new TestToken();
        address judge = address(0x7D6E);
        book = new EscrowBook(address(token), judge, 2 days, 0, 0);
        h = new EscrowHandler(book, token, judge);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](11);
        sel[0] = EscrowHandler.create.selector;
        sel[1] = EscrowHandler.accept.selector;
        sel[2] = EscrowHandler.cancel.selector;
        sel[3] = EscrowHandler.releaseOrRefund.selector;
        sel[4] = EscrowHandler.propose.selector;
        sel[5] = EscrowHandler.acceptProposal.selector;
        sel[6] = EscrowHandler.dispute.selector;
        sel[7] = EscrowHandler.rule.selector;
        sel[8] = EscrowHandler.timeout.selector;
        sel[9] = EscrowHandler.pay.selector;
        sel[10] = EscrowHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    function invariant_everyCallMatchesModel() public view {
        assertEq(h.mismatches(), 0);
    }

    function invariant_liabilityEqualsUnpaidAwards() public view {
        assertEq(book.totalLiability(), h.liability());
    }

    function invariant_conservation() public view {
        assertEq(h.funded(), h.paidOut() + book.totalLiability());
        assertEq(token.balanceOf(address(book)), book.totalLiability());
    }

    function invariant_brakeOpenWithoutExternalLoss() public view {
        (uint8 s, address g,) = book.brakeState();
        assertEq(s, 0);
        assertEq(g, address(0));
    }
}
