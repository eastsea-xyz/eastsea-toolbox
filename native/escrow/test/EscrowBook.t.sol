// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {EscrowBook} from "../src/EscrowBook.sol";
import {INativeBrake} from "../../common/src/INativeBrake.sol";
import {ExactToken} from "../../common/src/ExactToken.sol";
import {TransientLock} from "../../common/src/TransientLock.sol";
import {TestToken, FeeOnTransferToken, BlockingToken, CallbackToken} from "../../common/test/Tokens.sol";
import {SlotDiff} from "../../common/test/SlotDiff.sol";

abstract contract EscrowBase is Test {
    TestToken token;
    EscrowBook book;
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address stranger = makeAddr("stranger");
    address judge = makeAddr("judge");
    bytes32 constant TERMS = keccak256("deliver 1 logo by 12 Oct");

    uint64 constant T0 = 1_000_000;
    uint64 constant ACCEPT_BY = T0 + 1 days;
    uint64 constant DELIVER_BY = T0 + 7 days;
    uint64 constant RULING = 3 days;

    function _deploy(TestToken t, address arb) internal {
        vm.warp(T0);
        token = t;
        book = new EscrowBook(address(t), arb, arb == address(0) ? 0 : RULING, keccak256("spec"), keccak256("doc"));
        t.mint(buyer, type(uint128).max);
        vm.prank(buyer);
        t.approve(address(book), type(uint256).max);
    }

    function _create(uint128 amount, uint8 policy) internal returns (uint256 id) {
        vm.prank(buyer);
        id = book.create(seller, amount, ACCEPT_BY, DELIVER_BY, policy, TERMS);
    }

    function _accepted(uint128 amount, uint8 policy) internal returns (uint256 id) {
        id = _create(amount, policy);
        vm.prank(seller);
        book.accept(id);
    }

    function _payBoth(uint256 id) internal {
        EscrowBook.Deal memory d = book.deal(id);
        if (d.paid & 1 == 0) book.pay(id, true);
        if (d.paid & 2 == 0) book.pay(id, false);
    }
}

contract EscrowCreateTest is EscrowBase {
    function setUp() public {
        _deploy(new TestToken(), address(0));
    }

    function test_runtimeWithinEip170() public view {
        assertLe(address(book).code.length, 24576);
    }

    function test_constructor_checks() public {
        vm.expectRevert(EscrowBook.AssetHasNoCode.selector);
        new EscrowBook(address(0xdead), address(0), 0, 0, 0);
        vm.expectRevert(EscrowBook.BadArbiterConfig.selector);
        new EscrowBook(address(0), judge, 0, 0, 0);
        vm.expectRevert(EscrowBook.BadArbiterConfig.selector);
        new EscrowBook(address(0), address(0), 1, 0, 0);
    }

    function test_create_fourWordsExactPull() public {
        SlotDiff.start();
        uint256 id = _create(100e18, 0);
        assertEq(SlotDiff.stop(address(book)).occupied, 4, "S0-S3; G already occupied");
        assertEq(book.totalLiability(), 100e18);
        assertEq(token.balanceOf(address(book)), 100e18);
        EscrowBook.Deal memory d = book.deal(id);
        assertEq(d.buyer, buyer);
        assertEq(d.seller, seller);
        assertEq(d.clock, ACCEPT_BY);
        assertEq(d.deliverBy, DELIVER_BY);
        assertEq(d.phase, 1);
        assertEq(d.termsHash, TERMS);
    }

    function test_create_validation() public {
        vm.startPrank(buyer);
        vm.expectRevert(EscrowBook.BadParty.selector);
        book.create(address(0), 1, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        vm.expectRevert(EscrowBook.BadParty.selector);
        book.create(buyer, 1, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        vm.expectRevert(EscrowBook.BadParty.selector);
        book.create(address(book), 1, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        vm.expectRevert(EscrowBook.ZeroAmount.selector);
        book.create(seller, 0, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        vm.expectRevert(EscrowBook.BadDeadlines.selector);
        book.create(seller, 1, T0, DELIVER_BY, 0, TERMS);
        vm.expectRevert(EscrowBook.BadDeadlines.selector);
        book.create(seller, 1, DELIVER_BY, DELIVER_BY, 0, TERMS);
        vm.expectRevert(EscrowBook.BadPolicy.selector);
        book.create(seller, 1, ACCEPT_BY, DELIVER_BY, 2, TERMS);
        vm.expectRevert(EscrowBook.ZeroTerms.selector);
        book.create(seller, 1, ACCEPT_BY, DELIVER_BY, 0, 0);
        vm.deal(buyer, 1);
        vm.expectRevert(EscrowBook.BadFunding.selector);
        book.create{value: 1}(seller, 1, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        book.create(seller, type(uint128).max - 1, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        vm.expectRevert(EscrowBook.LiabilityOverflow.selector);
        book.create(seller, 2, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        vm.stopPrank();
    }

    function test_create_rejectsFeeOnTransferAsset() public {
        _deploy(new FeeOnTransferToken(), address(0));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(ExactToken.NotExactTransfer.selector, 1000, 990));
        book.create(seller, 1000, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        assertEq(book.totalLiability(), 0);
    }

    function test_arbiterCannotBeAParty() public {
        _deploy(new TestToken(), judge);
        vm.prank(buyer);
        vm.expectRevert(EscrowBook.BadParty.selector);
        book.create(judge, 1, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        token.mint(judge, 10);
        vm.prank(judge);
        token.approve(address(book), 10);
        vm.prank(judge);
        vm.expectRevert(EscrowBook.BadParty.selector);
        book.create(seller, 1, ACCEPT_BY, DELIVER_BY, 0, TERMS);
    }
}

contract EscrowFlowTest is EscrowBase {
    function setUp() public {
        _deploy(new TestToken(), address(0));
    }

    function test_accept_onlySellerBeforeDeadline() public {
        uint256 id = _create(100, 0);
        vm.prank(stranger);
        vm.expectRevert(EscrowBook.NotAuthorized.selector);
        book.accept(id);
        vm.warp(ACCEPT_BY);
        vm.prank(seller);
        vm.expectRevert(EscrowBook.TooLate.selector);
        book.accept(id);
    }

    function test_sellerNeverAccepts_anyoneLapsesAndBuyerIsRefunded() public {
        uint256 id = _create(100, 1);
        vm.prank(stranger);
        vm.expectRevert(EscrowBook.NotAuthorized.selector);
        book.cancel(id);
        vm.warp(ACCEPT_BY);
        vm.prank(stranger);
        book.cancel(id);
        uint256 before = token.balanceOf(buyer);
        SlotDiff.start();
        vm.prank(stranger);
        book.pay(id, false);
        assertEq(SlotDiff.stop(address(book)).cleared, 4, "record deleted after the only payout");
        assertEq(token.balanceOf(buyer) - before, 100);
        assertEq(book.totalLiability(), 0);
        vm.expectRevert(abi.encodeWithSelector(EscrowBook.UnknownDeal.selector, id));
        book.pay(id, false);
    }

    function test_buyerCancelsBeforeAcceptance() public {
        uint256 id = _create(100, 0);
        vm.prank(buyer);
        book.cancel(id);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(EscrowBook.WrongPhase.selector, id, 4));
        book.accept(id);
        book.pay(id, false);
    }

    function test_release_paysSeller_once() public {
        uint256 id = _accepted(100, 0);
        vm.prank(seller);
        vm.expectRevert(EscrowBook.NotAuthorized.selector);
        book.release(id);
        vm.prank(buyer);
        book.release(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowBook.WrongPhase.selector, id, 4));
        book.refund(id);
        vm.expectRevert(EscrowBook.AlreadyPaid.selector);
        book.pay(id, false); // buyer award was zero: consumed at resolution
        book.pay(id, true);
        assertEq(token.balanceOf(seller), 100);
        assertEq(book.deal(id).phase, 0);
    }

    function test_refund_paysBuyer() public {
        uint256 id = _accepted(100, 1);
        vm.prank(buyer);
        vm.expectRevert(EscrowBook.NotAuthorized.selector);
        book.refund(id);
        uint256 before = token.balanceOf(buyer);
        vm.prank(seller);
        book.refund(id);
        book.pay(id, false);
        assertEq(token.balanceOf(buyer) - before, 100);
    }

    function test_split_proposalRules() public {
        uint256 id = _accepted(100, 0);
        vm.prank(stranger);
        vm.expectRevert(EscrowBook.NotAuthorized.selector);
        book.propose(id, 10);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(EscrowBook.AwardTooLarge.selector, 101, 100));
        book.propose(id, 101);

        SlotDiff.start();
        vm.prank(seller);
        book.propose(id, 0); // zero award still occupies S4 (round, role)
        assertEq(SlotDiff.stop(address(book)).occupied, 1);
        vm.prank(seller);
        book.propose(id, 70); // replaces round 1
        vm.prank(seller);
        vm.expectRevert(EscrowBook.NotAuthorized.selector);
        book.acceptProposal(id, 2, 70); // proposer cannot accept own
        vm.prank(buyer);
        vm.expectRevert(EscrowBook.StaleProposal.selector);
        book.acceptProposal(id, 1, 0);
        vm.prank(buyer);
        vm.expectRevert(EscrowBook.StaleProposal.selector);
        book.acceptProposal(id, 2, 69);
        uint256 before = token.balanceOf(buyer);
        vm.prank(buyer);
        book.acceptProposal(id, 2, 70);
        assertEq(book.proposal(id).round, 0, "S4 cleared at resolution");
        book.pay(id, true);
        book.pay(id, false);
        assertEq(token.balanceOf(seller), 70);
        assertEq(token.balanceOf(buyer) - before, 30);
        assertEq(book.totalLiability(), 0);
    }

    function test_timeout_noArbiter_bothPolicies() public {
        uint256 r = _accepted(100, 0); // BUYER_REFUND on silence
        uint256 p = _accepted(100, 1); // SELLER_PAYMENT on silence
        vm.warp(DELIVER_BY - 1);
        vm.expectRevert(EscrowBook.TooEarly.selector);
        book.resolveTimeout(r);
        vm.expectRevert(EscrowBook.NoArbiter.selector);
        book.dispute(r);
        vm.warp(DELIVER_BY);
        uint256 before = token.balanceOf(buyer);
        vm.startPrank(stranger);
        book.resolveTimeout(r);
        book.resolveTimeout(p);
        book.pay(r, false);
        book.pay(p, true);
        vm.stopPrank();
        assertEq(token.balanceOf(buyer) - before, 100, "seller vanished: buyer refunded");
        assertEq(token.balanceOf(seller), 100, "buyer vanished: seller paid");
    }

    function test_unacceptedOfferCannotTimeOutToSeller() public {
        uint256 id = _create(100, 1);
        vm.warp(DELIVER_BY);
        vm.expectRevert(abi.encodeWithSelector(EscrowBook.WrongPhase.selector, id, 1));
        book.resolveTimeout(id);
        book.cancel(id);
        book.pay(id, false);
    }

    function test_blockedRecipient_onlyBlocksOwnPayout() public {
        BlockingToken bt = new BlockingToken();
        _deploy(bt, address(0));
        uint256 id = _accepted(100, 0);
        vm.prank(buyer);
        book.propose(id, 60);
        vm.prank(seller);
        book.acceptProposal(id, 1, 60);
        bt.setBlocked(seller, true);
        vm.expectRevert();
        book.pay(id, true);
        uint256 before = bt.balanceOf(buyer);
        book.pay(id, false); // independent
        assertEq(bt.balanceOf(buyer) - before, 40);
        assertEq(book.totalLiability(), 60);
        bt.setBlocked(seller, false);
        book.pay(id, true);
        assertEq(bt.balanceOf(seller), 60);
        assertEq(book.deal(id).phase, 0);
    }
}

contract EscrowArbiterTest is EscrowBase {
    function setUp() public {
        _deploy(new TestToken(), judge);
    }

    function test_dispute_rules() public {
        uint256 id = _create(100, 0);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(EscrowBook.WrongPhase.selector, id, 1));
        book.dispute(id); // not accepted yet
        vm.prank(seller);
        book.accept(id);
        vm.prank(stranger);
        vm.expectRevert(EscrowBook.NotAuthorized.selector);
        book.dispute(id);
        vm.warp(DELIVER_BY);
        vm.prank(buyer);
        vm.expectRevert(EscrowBook.TooLate.selector);
        book.dispute(id);
    }

    function test_arbiterSplits_withinWindow_onlyToParties() public {
        uint256 id = _accepted(100, 1);
        vm.warp(T0 + 2 days);
        vm.prank(buyer);
        book.dispute(id);
        assertEq(book.deal(id).clock, T0 + 2 days + RULING);
        vm.prank(stranger);
        vm.expectRevert(EscrowBook.NotAuthorized.selector);
        book.rule(id, 50);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(EscrowBook.AwardTooLarge.selector, 101, 100));
        book.rule(id, 101);
        vm.prank(judge);
        book.rule(id, 25);
        uint256 before = token.balanceOf(buyer);
        _payBoth(id);
        assertEq(token.balanceOf(seller), 25);
        assertEq(token.balanceOf(buyer) - before, 75);
        assertEq(token.balanceOf(judge), 0);
    }

    function test_absentArbiter_defaultAppliesAfterWindow() public {
        uint256 id = _accepted(100, 1);
        vm.prank(seller);
        book.dispute(id);
        uint64 rulingBy = book.deal(id).clock;
        vm.warp(rulingBy - 1);
        vm.expectRevert(EscrowBook.TooEarly.selector);
        book.resolveTimeout(id);
        vm.warp(rulingBy);
        vm.prank(judge);
        vm.expectRevert(EscrowBook.TooLate.selector);
        book.rule(id, 0);
        vm.prank(stranger);
        book.resolveTimeout(id);
        book.pay(id, true);
        assertEq(token.balanceOf(seller), 100);
    }

    function test_voluntarySettlementEndsDispute() public {
        uint256 id = _accepted(100, 0);
        vm.prank(buyer);
        book.dispute(id);
        vm.prank(buyer);
        book.propose(id, 80);
        vm.prank(seller);
        book.acceptProposal(id, 1, 80);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(EscrowBook.WrongPhase.selector, id, 4));
        book.rule(id, 0);
        _payBoth(id);
        assertEq(token.balanceOf(seller), 80);
    }

    function test_disputeCannotExtendSilence() public {
        uint256 id = _accepted(100, 0);
        vm.prank(buyer);
        book.dispute(id);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(EscrowBook.WrongPhase.selector, id, 3));
        book.dispute(id); // no second dispute, no new window
    }
}

contract EscrowNativeTest is EscrowBase {
    function setUp() public {
        vm.warp(T0);
        book = new EscrowBook(address(0), address(0), 0, keccak256("spec"), 0);
        vm.deal(buyer, 100 ether);
    }

    function test_native_fullFlow() public {
        vm.prank(buyer);
        vm.expectRevert(EscrowBook.BadFunding.selector);
        book.create{value: 1 ether - 1}(seller, 1 ether, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        vm.prank(buyer);
        uint256 id = book.create{value: 1 ether}(seller, 1 ether, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        vm.prank(seller);
        book.accept(id);
        vm.prank(buyer);
        book.release(id);
        book.pay(id, true);
        assertEq(seller.balance, 1 ether);
        assertEq(address(book).balance, 0);
    }

    function test_native_rejectingRecipientKeepsRight_andReentryBlocked() public {
        NativeGrief g = new NativeGrief();
        vm.deal(address(g), 10 ether);
        uint256 id = g.open(book, seller, 1 ether, ACCEPT_BY, DELIVER_BY, TERMS);
        uint256 other = g.open(book, seller, 1 ether, ACCEPT_BY, DELIVER_BY, TERMS);
        vm.warp(ACCEPT_BY);
        book.cancel(id);
        book.cancel(other);
        g.setMode(1); // revert on receive
        vm.expectRevert(abi.encodeWithSelector(ExactToken.NativeTransferFailed.selector, address(g), 1 ether));
        book.pay(id, false);
        assertEq(book.totalLiability(), 2 ether);
        g.setMode(2); // try to re-enter pay(other) while receiving
        g.arm(other);
        book.pay(id, false);
        assertEq(g.err(), TransientLock.Reentrancy.selector);
        assertEq(book.totalLiability(), 1 ether);
        g.setMode(0);
        book.pay(other, false);
        assertEq(address(book).balance, 0);
    }
}

contract EscrowBrakeTest is EscrowBase {
    function setUp() public {
        _deploy(new TestToken(), address(0));
    }

    function test_brake_deficit_entryClosed_exitsWaitForBacking() public {
        uint256 id = _create(100, 0);
        vm.expectRevert(INativeBrake.BrakePredicateFalse.selector);
        book.tripBrake();
        token.burnFrom(address(book), 1);
        assertEq(book.brakePredicate(), 2);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.EntryBraked.selector, 2, 0));
        book.create(seller, 1, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        vm.roll(9);
        book.tripBrake();
        // Agreement paths still work under the brake.
        vm.prank(seller);
        book.accept(id);
        vm.prank(buyer);
        book.release(id);
        vm.expectRevert();
        book.pay(id, true); // would leave liability unbacked
        token.mint(address(book), 1); // donation cures, grants no claim
        book.pay(id, true);
        assertEq(token.balanceOf(seller), 100);
        (uint8 s, address g, uint64 since) = book.brakeState();
        assertEq(s, 1);
        assertEq(g, address(0));
        assertEq(since, 9);
    }

    function test_brake_codeChangeAndIdExhaustion() public {
        vm.etch(address(token), address(new FeeOnTransferToken()).code);
        assertEq(book.brakePredicate() & 1, 1);
        vm.etch(address(token), address(new TestToken()).code);
        // G = slot 0: totalLiability (low 128) | nextId (64) | brakeSince (64)
        vm.store(address(book), bytes32(0), bytes32(uint256(type(uint64).max) << 128));
        assertEq(book.brakePredicate(), 4);
    }

    function test_reentrancy_fromTokenCallback() public {
        CallbackToken ct = new CallbackToken();
        _deploy(ct, address(0));
        EscrowReenterer r = new EscrowReenterer();
        vm.prank(buyer);
        uint256 a = book.create(address(r), 100, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        vm.prank(buyer);
        uint256 b = book.create(address(r), 100, ACCEPT_BY, DELIVER_BY, 0, TERMS);
        r.go(book, a);
        r.go(book, b);
        vm.prank(buyer);
        book.release(a);
        vm.prank(buyer);
        book.release(b);
        r.arm(b);
        book.pay(a, true);
        assertEq(r.err(), TransientLock.Reentrancy.selector);
        assertEq(ct.balanceOf(address(r)), 100);
        book.pay(b, true);
        assertEq(ct.balanceOf(address(r)), 200);
    }
}

contract NativeGrief {
    uint8 mode;
    EscrowBook book;
    uint256 target;
    bytes4 public err;

    function open(EscrowBook b, address s, uint128 amt, uint64 a, uint64 d, bytes32 t) external returns (uint256) {
        book = b;
        return b.create{value: amt}(s, amt, a, d, 0, t);
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function arm(uint256 id) external {
        target = id;
    }

    receive() external payable {
        if (mode == 1) revert("no");
        if (mode == 2) {
            mode = 0;
            try book.pay(target, false) {}
            catch (bytes memory e) {
                err = bytes4(e);
            }
        }
    }
}

contract EscrowReenterer {
    EscrowBook book;
    uint256 target;
    bytes4 public err;

    function go(EscrowBook b, uint256 id) external {
        book = b;
        b.accept(id);
    }

    function arm(uint256 id) external {
        target = id;
    }

    function onTokenTransfer(address, uint256) external {
        if (target == 0) return;
        uint256 t = target;
        target = 0;
        try book.pay(t, true) {}
        catch (bytes memory e) {
            err = bytes4(e);
        }
    }
}
