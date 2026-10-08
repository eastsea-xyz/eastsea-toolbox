// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1271} from "openzeppelin/interfaces/IERC1271.sol";
import {P256} from "openzeppelin/utils/cryptography/P256.sol";

/// @dev Test-only mirror of EastSeaAccount v2's owner-signature interface.
/// Uses real P-256 verification in Solidity so the Paris test EVM needs no
/// P256VERIFY precompile. Recovery, guardians and sessions are outside scope.
contract EastSeaAccountMock is IERC1271 {
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    bytes32 private immutable ownerX;
    bytes32 private immutable ownerY;
    bool public enabled = true;

    error OnlySelf();
    error CallFailed(uint256 index, bytes reason);

    constructor(bytes32 x, bytes32 y) {
        ownerX = x;
        ownerY = y;
    }

    /// @dev Test control for ERC-1271's time-dependent signature validity.
    function setEnabled(bool value) external {
        enabled = value;
    }

    function signatureMessage(bytes32 hash) public view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("EastSeaAccount"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
        return
            abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(keccak256("Contents(bytes32 contents)"), hash)));
    }

    function signatureDigest(bytes32 hash) public view returns (bytes32) {
        return sha256(signatureMessage(hash));
    }

    /// @dev EastSea's signature bytes are r || s || x || y, exactly 128 bytes.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (!enabled || signature.length != 128) return 0xffffffff;
        bytes32 x = bytes32(signature[64:96]);
        bytes32 y = bytes32(signature[96:128]);
        if (x != ownerX || y != ownerY) return 0xffffffff;
        bool valid =
            P256.verifySolidity(signatureDigest(hash), bytes32(signature[0:32]), bytes32(signature[32:64]), x, y);
        return valid ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }

    /// @dev Matches the self-only account batch used by real P-256 transactions.
    function execute(Call[] calldata calls) external payable {
        if (msg.sender != address(this)) revert OnlySelf();
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            if (!ok) revert CallFailed(i, reason);
        }
    }

    receive() external payable {}
}
