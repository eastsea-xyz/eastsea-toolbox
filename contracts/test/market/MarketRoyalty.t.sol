// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {FixedPriceMarket} from "src/market/FixedPriceMarket.sol";

/// @notice 수신자가 설정되지 않은(address(0)) 로열티를 광고하는 기형 컬렉션.
contract ZeroReceiverRoyaltyNFT is ERC721 {
    constructor() ERC721("Zero Receiver", "ZERO") {
        _mint(msg.sender, 1);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a || super.supportsInterface(interfaceId);
    }

    function royaltyInfo(uint256, uint256 price) external pure returns (address, uint256) {
        return (address(0), price / 2);
    }
}

/// @notice 회귀 — receiver=0 로열티는 인출 주체가 없어 판매대금 일부가 마켓에
///         좌초된다. 수신자 없는 로열티는 로열티 없음으로 취급한다.
///         (aether-node 3fe06b6에서 포팅)
contract MarketRoyaltyTest is Test {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @dev receiver=0 로열티는 무시되고 판매자가 전액 크레딧을 받는다.
    function test_buy_zeroReceiverRoyaltyCannotStrandSellerProceeds() public {
        FixedPriceMarket market = new FixedPriceMarket(address(this));
        ZeroReceiverRoyaltyNFT nft = new ZeroReceiverRoyaltyNFT();
        nft.approve(address(market), 1);
        market.list(nft, 1, 1 ether);
        vm.deal(address(this), 1 ether);
        market.buy{value: 1 ether}(1);
        assertEq(market.credits(address(this)), 1 ether); // 판매자 전액
        assertEq(market.credits(address(0)), 0); // 인출 불가 크레딧 없음
        market.withdraw();
        assertEq(address(market).balance, 0); // 좌초분 없음
    }

    receive() external payable {}
}
