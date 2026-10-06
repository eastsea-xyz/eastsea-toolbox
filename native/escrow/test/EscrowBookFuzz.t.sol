// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {EscrowBook} from "../src/EscrowBook.sol";
import {TestToken} from "../../common/test/Tokens.sol";

contract EscrowBookFuzzTest is Test {
    TestToken token;
    EscrowBook book;
    EscrowBook nativeBook;
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address judge = makeAddr("judge");

    function setUp() public {
        vm.warp(1_000_000);
        token = new TestToken();
        book = new EscrowBook(address(token), judge, 3 days, 0, 0);
        nativeBook = new EscrowBook(address(0), address(0), 0, 0, 0);
        token.mint(buyer, type(uint128).max);
        vm.prank(buyer);
        token.approve(address(book), type(uint256).max);
    }

    /// Any split, reached by any of the three routes, pays exactly `amount`
    /// in total, never more, and retires the record.
    function testFuzz_anySplitConserves(uint128 amount, uint128 award, uint8 route) public {
        amount = uint128(bound(amount, 1, type(uint128).max));
        award = uint128(bound(award, 0, amount));
        uint64 now_ = uint64(block.timestamp);
        vm.prank(buyer);
        uint256 id = book.create(seller, amount, now_ + 1, now_ + 100, 0, keccak256("t"));
        vm.prank(seller);
        book.accept(id);
        route = route % 3;
        if (route == 0) {
            vm.prank(seller);
            book.propose(id, award);
            vm.prank(buyer);
            book.acceptProposal(id, 1, award);
        } else if (route == 1) {
            vm.prank(buyer);
            book.propose(id, award);
            vm.prank(seller);
            book.acceptProposal(id, 1, award);
        } else {
            vm.prank(buyer);
            book.dispute(id);
            vm.prank(judge);
            book.rule(id, award);
        }
        uint256 b0 = token.balanceOf(buyer);
        EscrowBook.Deal memory d = book.deal(id);
        if (d.paid & 1 == 0) book.pay(id, true);
        if (d.paid & 2 == 0) book.pay(id, false);
        assertEq(token.balanceOf(seller), award);
        assertEq(token.balanceOf(buyer) - b0, amount - award);
        assertEq(book.totalLiability(), 0);
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(book.deal(id).phase, 0);
    }

    /// Silence outcome depends only on the agreed policy and deadline.
    function testFuzz_silenceFollowsPolicy(uint128 amount, uint8 policy, uint32 accWin, uint32 delWin, uint32 late)
        public
    {
        amount = uint128(bound(amount, 1, 1e30));
        policy = policy % 2;
        uint64 now_ = uint64(block.timestamp);
        uint64 acceptBy = now_ + uint64(bound(accWin, 1, 30 days));
        uint64 deliverBy = acceptBy + uint64(bound(delWin, 1, 365 days));
        vm.deal(buyer, amount);
        vm.prank(buyer);
        uint256 id = nativeBook.create{value: amount}(seller, amount, acceptBy, deliverBy, policy, keccak256("t"));
        vm.prank(seller);
        nativeBook.accept(id);
        vm.warp(uint256(deliverBy) + bound(late, 0, 365 days));
        nativeBook.resolveTimeout(id);
        if (policy == 1) {
            nativeBook.pay(id, true);
            assertEq(seller.balance, amount);
        } else {
            nativeBook.pay(id, false);
            assertEq(buyer.balance, amount);
        }
        assertEq(address(nativeBook).balance, 0);
    }

    /// Strangers can never move money or change terms on someone else's deal.
    function testFuzz_strangerHasNoPower(address who, uint128 award) public {
        vm.assume(who != buyer && who != seller && who != judge);
        uint64 now_ = uint64(block.timestamp);
        vm.prank(buyer);
        uint256 id = book.create(seller, 100, now_ + 1, now_ + 100, 1, keccak256("t"));
        vm.prank(seller);
        book.accept(id);
        vm.startPrank(who);
        vm.expectRevert();
        book.release(id);
        vm.expectRevert();
        book.refund(id);
        vm.expectRevert();
        book.propose(id, award);
        vm.expectRevert();
        book.dispute(id);
        vm.expectRevert();
        book.rule(id, award);
        vm.expectRevert();
        book.resolveTimeout(id);
        vm.expectRevert();
        book.pay(id, true);
        vm.stopPrank();
        assertEq(book.deal(id).phase, 2);
    }
}
