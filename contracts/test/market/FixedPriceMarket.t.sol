// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {OnchainNFT} from "src/nft/OnchainNFT.sol";
import {FixedPriceMarket} from "src/market/FixedPriceMarket.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @notice 로열티(EIP-2981) 없는 최소 ERC-721 — 미지원 경로 테스트용.
contract PlainERC721 is ERC721 {
    uint256 private _next;

    constructor() ERC721("Plain", "PLN") {}

    function mint(address to) external returns (uint256 id) {
        id = ++_next;
        _mint(to, id);
    }
}

/// @notice F-01 PoC 1: 구매자 ERC-721 콜백에서 buy를 재시도한다.
contract ReentrantBuyer {
    FixedPriceMarket internal market;
    uint256 internal targetListing;
    bool public reentryBuyOk;

    constructor(FixedPriceMarket m) {
        market = m;
    }

    function attack(uint256 listingId) external payable {
        targetListing = listingId;
        market.buy{value: msg.value}(listingId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (bool ok,) = address(market).call{value: 0}(abi.encodeCall(market.buy, (targetListing)));
        reentryBuyOk = ok;
        return this.onERC721Received.selector;
    }
}

/// @notice F-01 PoC 2: withdraw의 native 수신 콜백에서 withdraw를 재시도한다.
contract ReentrantWithdrawer {
    FixedPriceMarket internal market;
    bool public reentryWithdrawOk;
    bool public drained;

    constructor(FixedPriceMarket m) {
        market = m;
    }

    function drain() external {
        market.withdraw();
        drained = true;
    }

    // OnchainNFT를 받기 위한 receiver (mint 시 콜백)
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (!drained) {
            (bool ok,) = address(market).call(abi.encodeCall(market.withdraw, ()));
            reentryWithdrawOk = ok;
        }
    }
}

contract FixedPriceMarketTest is Test {
    FixedPriceMarket internal market;
    OnchainNFT internal royaltyNft; // 5% 로열티
    PlainERC721 internal plainNft; // 로열티 없음

    address internal creator = makeAddr("creator");
    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal guardian = makeAddr("guardian");

    uint256 internal constant PRICE = 0.1 ether;

    function setUp() public {
        market = new FixedPriceMarket(guardian);
        vm.prank(creator);
        royaltyNft = new OnchainNFT("Island Folk", "IFLK", 100, 500, guardian);
        plainNft = new PlainERC721();

        // seller에게 NFT 지급
        vm.prank(creator);
        royaltyNft.mint(seller, 1, 1, 1, 1); // tokenId 1
        plainNft.mint(seller); // tokenId 1
        vm.deal(buyer, 100 ether);
    }

    /// 로열티 NFT를 에스크로한 리스팅을 만든다.
    function _listRoyalty(uint256 price) internal returns (uint256) {
        vm.startPrank(seller);
        royaltyNft.approve(address(market), 1);
        uint256 id = market.list(royaltyNft, 1, price);
        vm.stopPrank();
        return id;
    }

    function _listPlain(uint256 price) internal returns (uint256) {
        vm.startPrank(seller);
        plainNft.setApprovalForAll(address(market), true);
        uint256 id = market.list(plainNft, 1, price);
        vm.stopPrank();
        return id;
    }

    // ---- 판매 등록 ----

    function test_list_escrowsNft() public {
        uint256 id = _listRoyalty(PRICE);
        assertEq(royaltyNft.ownerOf(1), address(market));
        (address s, address t, uint256 tid, uint256 p, bool active) = market.listingOf(id);
        assertEq(s, seller);
        assertEq(t, address(royaltyNft));
        assertEq(tid, 1);
        assertEq(p, PRICE);
        assertTrue(active);
    }

    function test_list_revertNotOwner() public {
        vm.prank(creator);
        royaltyNft.mint(buyer, 0, 0, 0, 0); // tokenId 2 — buyer 소유
        vm.prank(seller); // 소유 아님 (approve 여부와 무관하게 소유 검사가 먼저)
        vm.expectRevert(FixedPriceMarket.NotOwner.selector);
        market.list(royaltyNft, 2, PRICE);
    }

    function test_list_revertNotApproved() public {
        vm.prank(seller);
        vm.expectRevert(FixedPriceMarket.NotApproved.selector);
        market.list(royaltyNft, 1, PRICE);
    }

    function test_list_revertZeroPrice() public {
        vm.startPrank(seller);
        royaltyNft.approve(address(market), 1);
        vm.expectRevert(FixedPriceMarket.ZeroPrice.selector);
        market.list(royaltyNft, 1, 0);
        vm.stopPrank();
    }

    // ---- 구매 ----

    function test_buy_royaltySplit() public {
        uint256 id = _listRoyalty(PRICE);
        vm.prank(buyer);
        market.buy{value: PRICE}(id);

        assertEq(royaltyNft.ownerOf(1), buyer);
        assertEq(market.credits(seller), PRICE * 95 / 100);
        assertEq(market.credits(creator), PRICE * 5 / 100); // 로열티 수신자 = creator
        (,,,, bool active) = market.listingOf(id);
        assertFalse(active); // 리스팅 소진
    }

    function test_buy_noRoyaltyTokenAllToSeller() public {
        uint256 id = _listPlain(PRICE);
        vm.prank(buyer);
        market.buy{value: PRICE}(id);
        assertEq(plainNft.ownerOf(1), buyer);
        assertEq(market.credits(seller), PRICE);
        assertEq(market.credits(creator), 0);
    }

    function test_buy_revertWrongPrice(uint128 delta) public {
        vm.assume(delta > 0 && delta < PRICE);
        uint256 id = _listRoyalty(PRICE);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(FixedPriceMarket.WrongPrice.selector, id, PRICE, PRICE - delta));
        market.buy{value: PRICE - delta}(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(FixedPriceMarket.WrongPrice.selector, id, PRICE, PRICE + delta));
        market.buy{value: PRICE + delta}(id);
    }

    function test_buy_revertUnknownThenDoubleBuy() public {
        uint256 id = _listRoyalty(PRICE);
        vm.prank(buyer);
        market.buy{value: PRICE}(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(FixedPriceMarket.UnknownListing.selector, id));
        market.buy{value: PRICE}(id); // 이미 팔림 — 리스팅 삭제됨
    }

    // ---- 취소 ----

    function test_cancel_returnsNft() public {
        uint256 id = _listRoyalty(PRICE);
        vm.prank(seller);
        market.cancel(id);
        assertEq(royaltyNft.ownerOf(1), seller);
        (,,,, bool active) = market.listingOf(id);
        assertFalse(active);
    }

    function test_cancel_revertNotSeller() public {
        uint256 id = _listRoyalty(PRICE);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(FixedPriceMarket.NotSeller.selector, id, buyer));
        market.cancel(id);
    }

    // ---- 인출 ----

    function test_withdraw_paysCredits() public {
        uint256 id = _listRoyalty(PRICE);
        vm.prank(buyer);
        market.buy{value: PRICE}(id);

        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        market.withdraw();
        assertEq(seller.balance - sellerBefore, PRICE * 95 / 100);

        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        market.withdraw();
        assertEq(creator.balance - creatorBefore, PRICE * 5 / 100);

        assertEq(address(market).balance, 0);
    }

    function test_withdraw_revertZeroCredit() public {
        vm.prank(seller);
        vm.expectRevert(FixedPriceMarket.ZeroCredit.selector);
        market.withdraw();
    }

    // ---- F-01 PoC: 재진입 ----

    function test_reentrancy_buyBlocked() public {
        uint256 id = _listRoyalty(PRICE);
        ReentrantBuyer attacker = new ReentrantBuyer(market);
        attacker.attack{value: PRICE}(id);

        assertFalse(attacker.reentryBuyOk(), "reentrant buy must fail");
        assertEq(royaltyNft.ownerOf(1), address(attacker)); // 1차 구매는 정상 성립
    }

    function test_reentrancy_withdrawBlocked() public {
        uint256 id = _listRoyalty(PRICE);
        vm.prank(buyer);
        market.buy{value: PRICE}(id);

        // 공격자가 판매자인 척할 수는 없지만, 콜백 표면 검증을 위해
        // 판매자 크레딧을 갖는 악성 수신자를 시뮬레이션한다.
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(market);
        // seller의 크레딧을 attacker에게 이전할 방법은 없다 — 정상 경로로
        // attacker 자신이 크레딧을 얻게 한다: attacker가 직접 판매.
        vm.prank(creator);
        royaltyNft.mint(address(attacker), 2, 2, 2, 2);
        vm.startPrank(address(attacker));
        royaltyNft.approve(address(market), 2);
        uint256 id2 = market.list(royaltyNft, 2, PRICE);
        vm.stopPrank();

        vm.prank(buyer);
        market.buy{value: PRICE}(id2);
        assertEq(market.credits(address(attacker)), PRICE * 95 / 100);

        attacker.drain();
        assertTrue(attacker.drained(), "first withdraw must succeed");
        assertFalse(attacker.reentryWithdrawOk(), "reentrant withdraw must fail");
    }

    // ---- 솔번시 불변식 (fuzz) ----

    /// 무작위 구매/취소/인출 시퀀스 후 sum(credits) == address(market).balance.
    function test_fuzz_solvency(uint8 seed) public {
        // 리스팅 6개: 로열티 NFT 3 (id 1,2,3) + plain 3 (id 4,5,6)
        vm.startPrank(creator);
        royaltyNft.mint(seller, 2, 2, 2, 2);
        royaltyNft.mint(seller, 3, 3, 3, 3);
        royaltyNft.mint(seller, 4, 4, 4, 4);
        vm.stopPrank();
        plainNft.mint(seller); // tokenId 2
        plainNft.mint(seller); // tokenId 3
        vm.startPrank(seller);
        royaltyNft.setApprovalForAll(address(market), true);
        market.list(royaltyNft, 2, PRICE);
        market.list(royaltyNft, 3, 2 * PRICE);
        market.list(royaltyNft, 4, PRICE);
        plainNft.setApprovalForAll(address(market), true);
        market.list(plainNft, 1, PRICE);
        market.list(plainNft, 2, PRICE);
        market.list(plainNft, 3, PRICE);
        vm.stopPrank();

        address[2] memory buyers = [buyer, makeAddr("buyer2")];
        for (uint256 i = 0; i < buyers.length; i++) {
            vm.deal(buyers[i], 1000 ether);
        }

        for (uint256 s = 0; s < 30; s++) {
            uint256 pick = (uint256(seed) * 13 + s * 7) % 11;
            uint256 listingId = 1 + (pick % 6);
            (,,, uint256 price, bool active) = market.listingOf(listingId);
            if (!active) continue;

            if (pick % 3 == 0) {
                vm.prank(seller);
                (bool cok,) = address(market).call(abi.encodeCall(market.cancel, (listingId)));
                if (!cok) {} // 이미 팔린 리스팅 — 무시
            } else {
                address b = buyers[pick % 2];
                vm.prank(b);
                (bool bok,) = address(market).call{value: price}(abi.encodeCall(market.buy, (listingId)));
                if (!bok) {} // 경쟁 구매 실패 — 무시
            }
            // 가끔 인출
            if (pick % 4 == 1) {
                vm.prank(seller);
                (bool wok,) = address(market).call(abi.encodeCall(market.withdraw, ()));
                if (!wok) {} // 크레딧 0 — 무시
                vm.prank(creator);
                (bool wok2,) = address(market).call(abi.encodeCall(market.withdraw, ()));
                if (!wok2) {}
            }

            // 매 스텝 불변식
            uint256 sum = market.credits(seller) + market.credits(creator);
            assertEq(sum, address(market).balance, "sum(credits) == balance");
        }
    }

    // ---- brake ----

    function test_brake_blocksEntryNotExit() public {
        uint256 id = _listRoyalty(PRICE);
        vm.prank(buyer);
        market.buy{value: PRICE}(id);

        vm.prank(guardian);
        market.engageBrake(1);

        // 신규 진입(list/buy)은 차단된다
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        market.list(plainNft, 1, PRICE);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        market.buy{value: PRICE}(999); // 존재 검사보다 brake가 먼저

        // 탈출(취소·인출)은 열려 있다
        uint256 before = seller.balance;
        vm.prank(seller);
        market.withdraw();
        assertEq(seller.balance - before, PRICE * 95 / 100);
    }

    // ---- 상태 계량 (examples/market/GAS.md 원본 데이터) ----

    function test_meter_deploy() public {
        StateMeter.Result memory r;
        (, r) = StateMeter.measureDeploy(abi.encodePacked(type(FixedPriceMarket).creationCode, abi.encode(guardian)));
        emit log_named_uint("deploy gasUsed", r.gasUsed);
        emit log_named_uint("deploy codeBytes", r.codeBytes);
        emit log_named_uint("deploy stateUnits", r.stateUnits);
    }

    function test_meter_listBuyWithdraw() public {
        address[] memory tracked = new address[](1);
        tracked[0] = address(market);

        vm.startPrank(seller);
        royaltyNft.approve(address(market), 1);
        vm.stopPrank();
        StateMeter.Result memory r = StateMeter.measureCall(
            seller, tracked, address(market), abi.encodeCall(market.list, (royaltyNft, 1, PRICE))
        );
        emit log_named_uint("list gasUsed", r.gasUsed);
        emit log_named_uint("list newSlots", r.newSlots);
        emit log_named_uint("list stateUnits", r.stateUnits);

        StateMeter.Result memory r2 = StateMeter.measureCallValue(
            buyer, tracked, address(market), abi.encodeCall(market.buy, (uint256(1))), PRICE
        );
        emit log_named_uint("buy gasUsed", r2.gasUsed);
        emit log_named_uint("buy newSlots", r2.newSlots);
        emit log_named_uint("buy logBytes", r2.logBytes);
        emit log_named_uint("buy stateUnits", r2.stateUnits);

        StateMeter.Result memory r3 =
            StateMeter.measureCall(seller, tracked, address(market), abi.encodeCall(market.withdraw, ()));
        emit log_named_uint("withdraw gasUsed", r3.gasUsed);
        emit log_named_uint("withdraw newSlots", r3.newSlots);
        emit log_named_uint("withdraw stateUnits", r3.stateUnits);
    }
}
