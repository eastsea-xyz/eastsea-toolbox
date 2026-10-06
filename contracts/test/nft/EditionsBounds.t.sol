// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Editions1155} from "src/nft/Editions1155.sol";

/// @notice 회귀 — createEdition의 축소 캐스트는 광고된 판매 조건을 바꾸면 안
///         된다. uint128 가격·uint32 지갑 한도를 넘는 입력은 BadEditionParams로
///         거부된다. (aether-node c33c528에서 포팅)
contract EditionsBoundsTest is Test {
    /// @dev uint32를 넘는 지갑 한도는 작은 값으로 잘려 민팅이 얼어붙으면 안 된다.
    function test_createEdition_rejectsWalletCapAboveUint32() public {
        Editions1155 editions = new Editions1155(address(this));
        vm.expectRevert(Editions1155.BadEditionParams.selector);
        editions.createEdition("wrapped cap", uint256(1) << 32, uint256(1) << 32, 1, 0);
    }

    /// @dev uint128을 넘는 가격은 0에 가까운 값으로 잘려 사실상 무료 판매가
    ///      되어서는 안 된다.
    function test_createEdition_rejectsPriceAboveUint128() public {
        Editions1155 editions = new Editions1155(address(this));
        vm.expectRevert(Editions1155.BadEditionParams.selector);
        editions.createEdition("wrapped price", 1, 1, uint256(1) << 128, 0);
    }

    /// @dev 정확한 팩 필드 경계값은 잘림 없이 그대로 저장·조회된다.
    function test_createEdition_exactPackedFieldBoundsRoundTrip() public {
        Editions1155 editions = new Editions1155(address(this));
        uint256 id = editions.createEdition("bounds", type(uint48).max, type(uint32).max, type(uint128).max, 1000);
        (,, uint256 cap,, uint256 walletCap, uint256 price,) = editions.editionOf(id);
        assertEq(cap, type(uint48).max);
        assertEq(walletCap, type(uint32).max);
        assertEq(price, type(uint128).max);
    }
}
