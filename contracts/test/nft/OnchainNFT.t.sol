// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Base64} from "openzeppelin/utils/Base64.sol";
import {OnchainNFT} from "src/nft/OnchainNFT.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {StateMeter} from "test/utils/StateMeter.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

contract OnchainNFTTest is Test {
    OnchainNFT internal nft;
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal guardian = makeAddr("guardian");

    uint256 internal constant MAX_SUPPLY = 100;

    function setUp() public {
        vm.prank(creator);
        nft = new OnchainNFT("Island Folk", "IFLK", MAX_SUPPLY, 500, guardian); // 5% 로열티
    }

    function _mintFirst() internal returns (uint256) {
        vm.prank(creator);
        return nft.mint(alice, 0, 0, 0, 0); // teal orb veil none
    }

    // ---- 배치 ----

    function test_deploy_setup() public view {
        assertEq(nft.name(), "Island Folk");
        assertEq(nft.symbol(), "IFLK");
        assertEq(nft.maxSupply(), MAX_SUPPLY);
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, creator);
        assertEq(amount, 0.05 ether); // 500bps = 5%
    }

    // ---- 발행 ----

    function test_mint_packsTraits() public {
        uint256 id = _mintFirst();
        assertEq(nft.ownerOf(id), alice);
        OnchainNFT.Traits memory t = nft.traitsOf(id);
        assertEq(uint256(t.color), 0);
        assertEq(uint256(t.shape), 0);
        assertEq(uint256(t.pattern), 0);
        assertEq(uint256(t.halo), 0);
        assertEq(t.mintedAt, block.timestamp);
    }

    function test_mint_maxValues() public {
        vm.prank(creator);
        uint256 id = nft.mint(bob, 7, 7, 7, 7);
        OnchainNFT.Traits memory t = nft.traitsOf(id);
        assertEq(uint256(t.color), 7);
        assertEq(uint256(t.halo), 7);
    }

    function test_mint_revertNotCreator() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OnchainNFT.NotCreator.selector, alice));
        nft.mint(alice, 0, 0, 0, 0);
    }

    function test_mint_revertBadTrait(uint8 v) public {
        vm.assume(v > 7);
        vm.prank(creator);
        vm.expectRevert(OnchainNFT.BadTrait.selector);
        nft.mint(alice, v, 0, 0, 0);
    }

    function test_mint_revertSoldOut() public {
        for (uint256 i = 0; i < MAX_SUPPLY; i++) {
            vm.prank(creator);
            nft.mint(bob, uint8(i % 8), 0, 0, 0);
        }
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(OnchainNFT.MintedOut.selector, MAX_SUPPLY + 1, MAX_SUPPLY));
        nft.mint(bob, 0, 0, 0, 0);
    }

    // ---- 온체인 메타데이터 ----

    function test_tokenURI_isSelfConsistentBase64() public {
        uint256 id = _mintFirst();
        string memory uri = nft.tokenURI(id);
        // 접두 검증 (data:application/json;base64, = 29B)
        bytes memory prefix = "data:application/json;base64,";
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uint8(bytes(uri)[i]), uint8(prefix[i]));
        }
        // 전문이 jsonOf의 base64와 일치
        assertEq(uri, string.concat("data:application/json;base64,", Base64.encode(bytes(nft.jsonOf(id)))));
    }

    function test_jsonContainsTraitsAndImage() public {
        uint256 id = _mintFirst();
        string memory json = nft.jsonOf(id);
        // trait 이름이 문자열에 박혀 있는지 (파싱 대신 contains 검증)
        assertTrue(_contains(bytes(json), '"trait_type":"color"'));
        assertTrue(_contains(bytes(json), '"value":"teal"'));
        assertTrue(_contains(bytes(json), '"value":"orb"'));
        assertTrue(_contains(bytes(json), '"value":"none"'));
        assertTrue(_contains(bytes(json), "Island Folk #"));
        assertTrue(_contains(bytes(json), '"image":"data:image/svg+xml;base64,'));
    }

    function test_svgIsWellFormed() public {
        uint256 id = _mintFirst();
        string memory svg = nft.svgOf(id);
        assertTrue(_contains(bytes(svg), "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200'>"));
        assertTrue(_contains(bytes(svg), "#2dd4bf")); // teal 배경
        assertTrue(_contains(bytes(svg), "</svg>"));
    }

    function test_tokenURI_revertUnknown(uint256 id) public {
        vm.assume(id == 0 || id > 1);
        vm.expectRevert();
        nft.tokenURI(id);
    }

    // ---- 이전/승인 (표준 스모크) ----

    function test_transferApprovalFlow() public {
        uint256 id = _mintFirst();
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.balanceOf(alice), 0);

        vm.prank(bob);
        nft.approve(alice, id);
        vm.prank(alice);
        nft.transferFrom(bob, alice, id);
        assertEq(nft.ownerOf(id), alice);
    }

    // ---- 소각 ----

    function test_burn_refundsTraitSlot() public {
        uint256 id = _mintFirst();
        vm.prank(alice);
        nft.burn(id);
        vm.expectRevert(); // ownerOf: 미발행
        nft.ownerOf(id);
        vm.expectRevert(); // traitsOf: _requireOwned
        nft.traitsOf(id);
    }

    function test_burn_revertNotOwner() public {
        uint256 id = _mintFirst();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OnchainNFT.NotOwnerOf.selector, id, bob));
        nft.burn(id);
    }

    // ---- brake ----

    function test_brake_blocksMintNotTransferOrBurn() public {
        uint256 id = _mintFirst();
        vm.prank(guardian);
        nft.engageBrake(1); // 신규 진입 정지

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        nft.mint(bob, 0, 0, 0, 0);

        vm.prank(alice); // 이전은 열려 있다
        nft.transferFrom(alice, bob, id);

        vm.prank(bob); // 소각(자구)도 열려 있다
        nft.burn(id);
    }

    function test_brake_onlyGuardianAndMonotonic() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.NotBrakeGuardian.selector, alice));
        nft.engageBrake(1);

        vm.prank(guardian);
        nft.engageBrake(1);
        vm.prank(guardian);
        vm.expectRevert(); // 1 -> 1 불가 (단조)
        nft.engageBrake(1);
        vm.prank(guardian);
        nft.engageBrake(2); // 1 -> 2 가능
        (uint8 state, address g,) = nft.brakeState();
        assertEq(state, 2);
        assertEq(g, guardian);
    }

    // ---- 인터페이스 ----

    function test_supportsInterfaces() public view {
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(nft.supportsInterface(0x2a55205a)); // ERC-2981
        assertTrue(nft.supportsInterface(0x01ffc9a7)); // ERC-165
    }

    // ---- 상태 계량 (examples/nft/GAS.md 원본 데이터) ----

    function test_meter_deploy() public {
        StateMeter.Result memory r;
        (, r) = StateMeter.measureDeploy(
            abi.encodePacked(
                type(OnchainNFT).creationCode, abi.encode("Island Folk", "IFLK", MAX_SUPPLY, uint96(500), guardian)
            )
        );
        emit log_named_uint("deploy gasUsed", r.gasUsed);
        emit log_named_uint("deploy codeBytes", r.codeBytes);
        emit log_named_uint("deploy newSlots", r.newSlots);
        emit log_named_uint("deploy stateUnits", r.stateUnits);
    }

    function test_meter_mintAndTransfer() public {
        address[] memory tracked = new address[](1);
        tracked[0] = address(nft);

        bytes memory data = abi.encodeCall(OnchainNFT.mint, (bob, 1, 1, 1, 1));
        StateMeter.Result memory r = StateMeter.measureCall(creator, tracked, address(nft), data);
        emit log_named_uint("mint-new-holder gasUsed", r.gasUsed);
        emit log_named_uint("mint-new-holder newSlots", r.newSlots);
        emit log_named_uint("mint-new-holder logBytes", r.logBytes);
        emit log_named_uint("mint-new-holder stateUnits", r.stateUnits);

        // 2차 이전: 수신자 소유권 슬롯만 새로 생김
        StateMeter.Result memory r2 =
            StateMeter.measureCall(bob, tracked, address(nft), abi.encodeCall(nft.transferFrom, (bob, alice, 1)));
        emit log_named_uint("transfer-existing-token gasUsed", r2.gasUsed);
        emit log_named_uint("transfer-existing-token newSlots", r2.newSlots);
        emit log_named_uint("transfer-existing-token stateUnits", r2.stateUnits);
    }

    // ---- helpers ----

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0) return true;
        for (uint256 i = 0; i + needle.length <= hay.length; i++) {
            uint256 j = 0;
            while (j < needle.length && hay[i + j] == needle[j]) {
                j++;
            }
            if (j == needle.length) return true;
        }
        return false;
    }
}
