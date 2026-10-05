// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {InvoiceBook} from "src/invoice/InvoiceBook.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 예제 16 — 인보이스 장부 테스트.
/// @dev fixture: 청구 금액 0.5 ether, 결제 기한 14일.
contract InvoiceBookTest is Test {
    InvoiceBook internal book;

    address internal guardian = makeAddr("guardian");
    address internal payee = makeAddr("payee");
    address internal alice = makeAddr("alice"); // 고객

    uint128 internal constant AMOUNT = 0.5 ether;
    uint48 internal constant PAY_BY = 14 days;

    function setUp() public {
        book = new InvoiceBook(guardian, payee);
    }

    function _issue() internal returns (uint256 id) {
        vm.prank(payee);
        id = book.issue(AMOUNT, PAY_BY, "logo design v2");
    }

    // ---------------------------------------------------------------- 발행

    function test_issue_recordsInvoice() public {
        vm.expectEmit(true, false, false, true);
        emit InvoiceBook.Issued(1, AMOUNT, uint48(block.timestamp) + PAY_BY, "logo design v2");
        uint256 id = _issue();

        (uint128 amount, uint48 due) = book.invoices(id);
        assertEq(amount, AMOUNT);
        assertEq(due, uint48(block.timestamp) + PAY_BY);
        assertEq(book.invoiceCount(), 1);
    }

    function test_issue_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvoiceBook.NotPayee.selector, alice));
        book.issue(AMOUNT, PAY_BY, "");

        vm.startPrank(payee);
        vm.expectRevert(InvoiceBook.ZeroAmount.selector);
        book.issue(0, PAY_BY, "");
        vm.expectRevert(InvoiceBook.ZeroPeriod.selector);
        book.issue(AMOUNT, 0, "");
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(InvoiceBook.NotPayee.selector, address(0)));
        new InvoiceBook(guardian, address(0));
    }

    // ---------------------------------------------------------------- 결제

    function test_settle_paysExactlyAndReleasesSlot() public {
        uint256 id = _issue();
        vm.deal(alice, 1 ether);
        uint256 before = payee.balance;

        vm.expectEmit(true, true, true, true);
        emit InvoiceBook.Settled(id, alice, AMOUNT);
        vm.prank(alice);
        book.settle{value: AMOUNT}(id);

        assertEq(payee.balance, before + AMOUNT);
        assertEq(book.totalSettled(), AMOUNT);
        (uint128 amount,) = book.invoices(id);
        assertEq(amount, 0); // 결제된 청구서는 존재하지 않는다

        // 이중결제 — 슬롯 부재가 답이다
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvoiceBook.UnknownInvoice.selector, id));
        book.settle{value: AMOUNT}(id);
    }

    function test_settle_reverts() public {
        uint256 id = _issue();
        vm.deal(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvoiceBook.WrongAmount.selector, AMOUNT + 1, AMOUNT));
        book.settle{value: AMOUNT + 1}(id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvoiceBook.WrongAmount.selector, 0, AMOUNT));
        book.settle{value: 0}(id);

        // 밖 송금 거부
        (bool ok,) = address(book).call{value: AMOUNT}("");
        assertFalse(ok);

        // 만료 — 기대 데이터는 warp 전 사전 계산 (prank 소비 함정)
        bytes memory expired =
            abi.encodeWithSelector(InvoiceBook.InvoiceExpired.selector, invoiceDueOf(id) + 1, invoiceDueOf(id));
        vm.warp(invoiceDueOf(id) + 1);
        vm.prank(alice);
        vm.expectRevert(expired);
        book.settle{value: AMOUNT}(id);
    }

    // ---------------------------------------------------------------- 폐기·반납

    function test_void_payeeOnly() public {
        uint256 id = _issue();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvoiceBook.NotPayee.selector, alice));
        book.void(id);

        vm.expectEmit(true, true, true, true);
        emit InvoiceBook.Voided(id);
        vm.prank(payee);
        book.void(id); // 만료 전이라도 폐기 가능

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvoiceBook.UnknownInvoice.selector, id));
        book.settle{value: AMOUNT}(id);
        assertEq(book.totalSettled(), 0); // 폐기는 정산 아님
    }

    function test_purge_afterDue() public {
        uint256 id = _issue();

        // 만료 전 반납 거부 — 경계 포함 (<=)
        vm.expectRevert(abi.encodeWithSelector(InvoiceBook.NotPastDue.selector, block.timestamp, invoiceDueOf(id)));
        book.purge(id);

        vm.warp(invoiceDueOf(id) + 1);
        vm.expectEmit(true, true, true, true);
        emit InvoiceBook.Purged(id, alice);
        vm.prank(alice); // 누구나
        book.purge(id);

        (uint128 amount,) = book.invoices(id);
        assertEq(amount, 0);
        assertEq(book.totalSettled(), 0); // 반납 ≠ 정산
    }

    // ---------------------------------------------------------------- 불변식

    /// @dev 발행 n건 × 경로(결제/폐기/방치) — payee 잔액은 정확히
    ///      결제합과 같고 totalSettled 와 일치하며 방치분만 남는다.
    function test_fuzz_lifecycle(uint8 seed) public {
        uint256 n = bound(seed, 1, 8);
        uint256 settled;
        uint256 left; // 방치(미결제·미폐기) 건수

        for (uint256 i; i < n; ++i) {
            vm.prank(payee);
            uint256 id = book.issue(AMOUNT, 30 days, "");

            uint8 route = uint8(uint256(keccak256(abi.encode(seed, i))) % 3);
            if (route == 0) {
                address payer = address(uint160(0x3000 + i));
                vm.deal(payer, AMOUNT);
                vm.prank(payer);
                book.settle{value: AMOUNT}(id);
                settled += AMOUNT;
            } else if (route == 1) {
                vm.prank(payee);
                book.void(id);
            } else {
                ++left;
            }
        }

        // I1: 정산 누계 == 결제합, payee 가 정확히 그만큼 받았다
        assertEq(book.totalSettled(), settled);
        assertEq(payee.balance, settled);

        // I2: 살아남은 청구서는 방치분뿐 — 전부 조회 가능
        uint256 alive;
        for (uint256 i = 1; i <= n; ++i) {
            (uint128 amount,) = book.invoices(i);
            if (amount != 0) ++alive;
        }
        assertEq(alive, left);
    }

    // ---------------------------------------------------------------- brake

    function test_brake_blocksIssueNotSettle() public {
        uint256 id = _issue();
        vm.prank(guardian);
        book.engageBrake(1);

        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        book.issue(AMOUNT, PAY_BY, "");

        // 이미 발행된 청구서의 결제·폐기·반납은 열려 있다
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        book.settle{value: AMOUNT}(id);
        assertEq(payee.balance, AMOUNT);
    }

    // ---------------------------------------------------------------- 상태 계량 (examples/invoice/GAS.md 원본)

    function test_meter_deploy() public {
        (, StateMeter.Result memory r) =
            StateMeter.measureDeploy(abi.encodePacked(type(InvoiceBook).creationCode, abi.encode(guardian, payee)));
        emit log_named_uint("bookDeploy gasUsed", r.gasUsed);
        emit log_named_uint("bookDeploy codeBytes", r.codeBytes);
        emit log_named_uint("bookDeploy stateUnits", r.stateUnits);
    }

    function test_meter_lifecycle() public {
        address[] memory tracked = new address[](1);
        tracked[0] = address(book);

        StateMeter.Result memory r1 =
            StateMeter.measureCall(payee, tracked, address(book), abi.encodeCall(book.issue, (AMOUNT, PAY_BY, "logo")));
        emit log_named_uint("issue gasUsed", r1.gasUsed);
        emit log_named_uint("issue newSlots", r1.newSlots);
        emit log_named_uint("issue logBytes", r1.logBytes);
        emit log_named_uint("issue stateUnits", r1.stateUnits);

        vm.deal(alice, 1 ether);
        StateMeter.Result memory r2 =
            StateMeter.measureCallValue(alice, tracked, address(book), abi.encodeCall(book.settle, (1)), AMOUNT);
        emit log_named_uint("settle gasUsed", r2.gasUsed);
        emit log_named_uint("settle newSlots", r2.newSlots);
        emit log_named_uint("settle logBytes", r2.logBytes);
        emit log_named_uint("settle stateUnits", r2.stateUnits);

        // 둘째 발행 — invoiceCount 슬롯은 이미 살아 있어 청구서 슬롯만
        StateMeter.Result memory r3 =
            StateMeter.measureCall(payee, tracked, address(book), abi.encodeCall(book.issue, (AMOUNT, PAY_BY, "")));
        emit log_named_uint("issue2 gasUsed", r3.gasUsed);
        emit log_named_uint("issue2 newSlots", r3.newSlots);
        emit log_named_uint("issue2 stateUnits", r3.stateUnits);

        // 폐기 — 슬롯 반납: void 는 영구 상태를 늘리지 않는다
        uint256 id3 = book.invoiceCount();
        StateMeter.Result memory r4 =
            StateMeter.measureCall(payee, tracked, address(book), abi.encodeCall(book.void, (id3)));
        emit log_named_uint("void gasUsed", r4.gasUsed);
        emit log_named_uint("void newSlots", r4.newSlots);
        emit log_named_uint("void stateUnits", r4.stateUnits);
    }

    // ---------------------------------------------------------------- 헬퍼

    /// @dev due 는 invoices(id) 튜플 접근이 불편하므로 — 슬롯 직접
    function invoiceDueOf(uint256 id) internal view returns (uint48) {
        (, uint48 due) = book.invoices(id);
        return due;
    }
}
