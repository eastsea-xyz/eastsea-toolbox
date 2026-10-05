// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base64} from "openzeppelin/utils/Base64.sol";
import {Editions1155} from "src/nft/Editions1155.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice mint 중 onERC1155Received에서 재진입을 시도하는 악성 수신자.
contract ReentrantBuyer {
    Editions1155 public target;
    bool public reentrySucceeded;

    constructor(Editions1155 t) {
        target = t;
    }

    function buy(uint256 editionId) external payable {
        target.mint{value: msg.value}(editionId);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        // price 0 에디션에 value 0으로 재진입 — nonReentrant가 막아야 한다.
        (bool ok,) = address(target).call{value: 0}(abi.encodeCall(target.mint, (uint256(1))));
        reentrySucceeded = ok;
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract Editions1155Test is Test {
    Editions1155 internal ed;
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal guardian = makeAddr("guardian");

    uint256 internal constant PRICE = 0.01 ether;
    uint256 internal constant CAP = 5;
    uint256 internal constant PER_WALLET = 2;

    function setUp() public {
        ed = new Editions1155(guardian);
        vm.prank(creator);
        ed.createEdition("Harbor Print", CAP, PER_WALLET, PRICE, 250); // 2.5%
    }

    function _buy(address buyer) internal {
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        ed.mint{value: PRICE}(1);
    }

    // ---- 에디션 생성 ----

    function test_createEdition_storesParams() public view {
        (address c, string memory name_, uint256 cap, uint256 minted, uint256 perWallet, uint256 price, uint16 feeBps) =
            ed.editionOf(1);
        assertEq(c, creator);
        assertEq(name_, "Harbor Print");
        assertEq(cap, CAP);
        assertEq(minted, 0);
        assertEq(perWallet, PER_WALLET);
        assertEq(price, PRICE);
        assertEq(uint256(feeBps), 250);
    }

    function test_createEdition_revertBadParams() public {
        vm.startPrank(creator);
        vm.expectRevert(Editions1155.NameTooLong.selector);
        ed.createEdition("", CAP, PER_WALLET, PRICE, 250);

        vm.expectRevert(Editions1155.NameTooLong.selector);
        ed.createEdition(string(new bytes(65)), CAP, PER_WALLET, PRICE, 250); // 65B 이름

        vm.expectRevert(Editions1155.BadEditionParams.selector);
        ed.createEdition("X", 0, PER_WALLET, PRICE, 250); // cap 0

        vm.expectRevert(Editions1155.BadEditionParams.selector);
        ed.createEdition("X", CAP, 0, PRICE, 250); // perWallet 0

        vm.expectRevert(Editions1155.BadEditionParams.selector);
        ed.createEdition("X", 3, 4, PRICE, 250); // perWallet > cap

        vm.expectRevert(Editions1155.BadEditionParams.selector);
        ed.createEdition("X", CAP, PER_WALLET, PRICE, 1001); // fee 상한 초과
        vm.stopPrank();
    }

    // ---- 구매 ----

    function test_mint_chargesExactPriceAndIncrements() public {
        _buy(alice);
        assertEq(ed.balanceOf(alice, 1), 1);
        (,,, uint256 minted,,,) = ed.editionOf(1);
        assertEq(minted, 1);
        assertEq(ed.withdrawable(1), PRICE);
    }

    function test_mint_revertWrongPrice() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Editions1155.WrongPrice.selector, 1, PRICE, PRICE - 1));
        ed.mint{value: PRICE - 1}(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Editions1155.WrongPrice.selector, 1, PRICE, PRICE + 1));
        ed.mint{value: PRICE + 1}(1);
    }

    function test_mint_revertWalletCap() public {
        _buy(alice);
        _buy(alice); // 2/2
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Editions1155.WalletCapReached.selector, 1, PER_WALLET));
        ed.mint{value: PRICE}(1);
    }

    function test_mint_revertSoldOut() public {
        address carol = makeAddr("carol");
        address dave = makeAddr("dave");
        _buy(alice); // 1
        _buy(alice); // 2 (지갑 상한 2/2)
        _buy(bob); // 3
        _buy(bob); // 4 (2/2)
        _buy(carol); // 5 = cap
        vm.deal(dave, 10 ether);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(Editions1155.EditionSoldOut.selector, 1, CAP));
        ed.mint{value: PRICE}(1);
    }

    function test_mint_revertUnknownEdition(uint256 id) public {
        vm.assume(id != 1);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Editions1155.UnknownEdition.selector, id));
        ed.mint{value: 0}(id);
    }

    // ---- 정산 ----

    function test_withdraw_paysAccruedThenZero() public {
        _buy(alice);
        _buy(bob);
        uint256 before = creator.balance;
        vm.prank(creator);
        ed.withdraw(1);
        assertEq(creator.balance - before, 2 * PRICE);
        assertEq(ed.withdrawable(1), 0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Editions1155.NothingToWithdraw.selector, 1));
        ed.withdraw(1);
    }

    function test_withdraw_revertNotCreator() public {
        _buy(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Editions1155.NotEditionCreator.selector, 1, alice));
        ed.withdraw(1);
    }

    // ---- 솔번시 불변식 (fuzz) ----

    /// 무작위 구매·인출 시퀀스 후 sum(withdrawable) == address(this).balance.
    function test_fuzz_solvency(uint8 seed) public {
        // 에디션 3개: 유료 2개 + 무료 1개 (재진입 PoC용)
        vm.startPrank(creator);
        ed.createEdition("Alpha", 50, 3, 0.02 ether, 100);
        ed.createEdition("Beta", 50, 3, 0.005 ether, 0);
        ed.createEdition("Free", 50, 3, 0, 100);
        vm.stopPrank();

        address[4] memory buyers = [alice, bob, makeAddr("carol"), makeAddr("dave")];
        for (uint256 i = 0; i < buyers.length; i++) {
            vm.deal(buyers[i], 100 ether);
        }

        uint256[4] memory prices = [PRICE, 0.02 ether, 0.005 ether, 0];

        for (uint256 s = 0; s < 40; s++) {
            uint256 pick = (uint256(seed) + s * 7) % 12;
            uint256 editionId = (pick % 3) + 1;
            address buyer = buyers[pick % buyers.length];
            if (pick % 4 == 3) {
                // 인출 시도 — 정상 경로이므로 성공해야 하고, 실패(=0원)해도 상태는 정합
                vm.prank(creator);
                (bool wok,) = address(ed).call(abi.encodeCall(ed.withdraw, (editionId)));
                if (!wok) {} // 인출액 0 revert 등 — 무시
            } else {
                vm.prank(buyer);
                (bool mok,) = address(ed).call{value: prices[editionId]}(abi.encodeCall(ed.mint, (editionId)));
                if (!mok) {} // cap/지갑 상한 초과 revert — 무시
            }
        }

        // 최종: credited(=sum price*minted) - withdrawn == balance
        // withdrawn 합계는 공개 뷰가 없으므로 balance == sum(withdrawable)로 갈음:
        uint256 sumWithdrawable;
        for (uint256 e = 1; e <= 4; e++) {
            sumWithdrawable += ed.withdrawable(e);
        }
        assertEq(sumWithdrawable, address(ed).balance, "sum(withdrawable) must equal contract balance");
    }

    // ---- 재진입 (F-01 PoC) ----

    function test_reentrancy_mintBlocked() public {
        // 무료 에디션 생성 (재진입 테스트용: value 0)
        vm.prank(creator);
        ed.createEdition("Free", 10, 10, 0, 0);

        ReentrantBuyer attacker = new ReentrantBuyer(ed);
        vm.deal(address(attacker), 1 ether);
        attacker.buy(2); // 무료 에디션 mint — 콜백에서 재진입 시도

        assertFalse(attacker.reentrySucceeded(), "reentrant mint must fail");
        assertEq(ed.balanceOf(address(attacker), 2), 1); // 1차 mint은 성공
    }

    // ---- brake ----

    function test_brake_blocksEntryNotWithdraw() public {
        _buy(alice);
        vm.prank(guardian);
        ed.engageBrake(1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        ed.mint{value: PRICE}(1);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        ed.createEdition("Late", 5, 1, PRICE, 0);

        // 출금은 열려 있다
        uint256 before = creator.balance;
        vm.prank(creator);
        ed.withdraw(1);
        assertEq(creator.balance - before, PRICE);
    }

    // ---- 로열티/URI ----

    function test_royaltyInfo_perEdition() public view {
        (address receiver, uint256 amount) = ed.royaltyInfo(1, 1 ether);
        assertEq(receiver, creator);
        assertEq(amount, 0.025 ether); // 250bps
    }

    function test_uri_isOnchainDataUri() public {
        _buy(alice);
        string memory u = ed.uri(1);
        bytes memory prefix = "data:application/json;base64,";
        assertTrue(bytes(u).length > prefix.length);
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uint8(bytes(u)[i]), uint8(prefix[i]));
        }
    }

    // ---- 상태 계량 (examples/nft/GAS.md 원본 데이터) ----

    function test_meter_deploy() public {
        StateMeter.Result memory r;
        (, r) = StateMeter.measureDeploy(abi.encodePacked(type(Editions1155).creationCode, abi.encode(guardian)));
        emit log_named_uint("deploy gasUsed", r.gasUsed);
        emit log_named_uint("deploy codeBytes", r.codeBytes);
        emit log_named_uint("deploy stateUnits", r.stateUnits);
    }

    function test_meter_createAndMintAndWithdraw() public {
        address[] memory tracked = new address[](1);
        tracked[0] = address(ed);

        StateMeter.Result memory r = StateMeter.measureCall(
            creator, tracked, address(ed), abi.encodeCall(ed.createEdition, ("Meter Edition", 100, 5, PRICE, 250))
        );
        emit log_named_uint("createEdition gasUsed", r.gasUsed);
        emit log_named_uint("createEdition newSlots", r.newSlots);
        emit log_named_uint("createEdition stateUnits", r.stateUnits);

        vm.deal(bob, 1 ether);
        StateMeter.Result memory r2 =
            StateMeter.measureCallValue(bob, tracked, address(ed), abi.encodeCall(ed.mint, (uint256(1))), PRICE);
        emit log_named_uint("mint-first gasUsed", r2.gasUsed);
        emit log_named_uint("mint-first newSlots", r2.newSlots);
        emit log_named_uint("mint-first logBytes", r2.logBytes);
        emit log_named_uint("mint-first stateUnits", r2.stateUnits);

        StateMeter.Result memory r3 =
            StateMeter.measureCall(creator, tracked, address(ed), abi.encodeCall(ed.withdraw, (uint256(1))));
        emit log_named_uint("withdraw gasUsed", r3.gasUsed);
        emit log_named_uint("withdraw newSlots", r3.newSlots);
        emit log_named_uint("withdraw stateUnits", r3.stateUnits);
    }
}
