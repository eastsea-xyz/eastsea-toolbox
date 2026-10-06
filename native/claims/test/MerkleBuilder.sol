// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice Test-side positional Merkle tree matching ClaimCampaigns and
///         tools/claims_tree.py (empty positions = 0, node = keccak(l || r)).
library MerkleBuilder {
    function depthFor(uint256 n) internal pure returns (uint256 d) {
        while ((uint256(1) << d) < n) d++;
    }

    function _node(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 width = uint256(1) << depthFor(leaves.length);
        bytes32[] memory level = new bytes32[](width);
        for (uint256 i; i < leaves.length; i++) {
            level[i] = leaves[i];
        }
        while (width > 1) {
            width >>= 1;
            for (uint256 i; i < width; i++) {
                level[i] = _node(level[2 * i], level[2 * i + 1]);
            }
        }
        return level[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory p) {
        uint256 depth = depthFor(leaves.length);
        uint256 width = uint256(1) << depth;
        bytes32[] memory level = new bytes32[](width);
        for (uint256 i; i < leaves.length; i++) {
            level[i] = leaves[i];
        }
        p = new bytes32[](depth);
        for (uint256 d; d < depth; d++) {
            p[d] = level[index ^ 1];
            width >>= 1;
            for (uint256 i; i < width; i++) {
                level[i] = _node(level[2 * i], level[2 * i + 1]);
            }
            index >>= 1;
        }
    }
}
