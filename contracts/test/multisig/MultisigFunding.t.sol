// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleMultisig} from "src/multisig/SimpleMultisig.sol";

/// @notice 회귀 — 멀티시그는 서명된 native 지급을 실행할 수 있지만 입금 경로가
///         없었다. receive() 추가로 일반 native 송금을 받고 서명된 지급을
///         실행한다. 알 수 없는 셀렉터는 여전히 거부된다. (aether-node c6a04ad에서 포팅)
contract MultisigFundingTest is Test {
    /// @dev 입금 후 서명된 지급이 정상 실행된다.
    function test_execute_nativeFundingAndSignedPayout() public {
        uint256 ownerKey = 7;
        address[] memory owners = new address[](1);
        owners[0] = vm.addr(ownerKey);
        SimpleMultisig wallet = new SimpleMultisig(owners, 1);

        vm.deal(address(this), 10);
        (bool funded,) = address(wallet).call{value: 10}("");
        assertTrue(funded && address(wallet).balance == 10, "native funding refused");

        address payable recipient = payable(address(0xbeef));
        uint256 beforeBalance = recipient.balance;
        bytes32 digest = wallet.getTransactionHash(recipient, 6, "", 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);
        wallet.execute(recipient, 6, "", 1, signatures);

        assertEq(address(wallet).balance, 4);
        assertEq(recipient.balance, beforeBalance + 6);
        assertTrue(wallet.executed(digest), "execution missing");
    }

    /// @dev receive() 추가에도 알 수 없는 셀렉터는 거부된다 (fallback 부재 유지).
    function test_receive_unknownSelectorStillRefused() public {
        address[] memory owners = new address[](1);
        owners[0] = address(this);
        SimpleMultisig wallet = new SimpleMultisig(owners, 1);
        (bool accepted,) = address(wallet).call(hex"ffffffff");
        assertFalse(accepted, "unknown selector accepted");
    }
}
