// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// Minimal cheatcode surface (no forge-std, so the proof bench has no
/// dependency on the contracts/ submodules).
interface Vm {
    function etch(address target, bytes calldata newRuntime) external;
    function startPrank(address msgSender, address txOrigin) external;
    function stopPrank() external;
    function roll(uint256 newBlock) external;
    function warp(uint256 newTimestamp) external;
    function prevrandao(bytes32 newPrevrandao) external;
}

/// @notice Shared base for the Foundry runners of the EastSea hazard probes.
///
/// Only the runners under test/ use cheatcodes. The probes under src/ are
/// standalone so the EastSea executor harness can compile and run them
/// unchanged; the runners stage what only a test chain can (etch, prank,
/// block fields) and set the block environment to EastSea's pinned values
/// (1 s blocks, prevrandao = 0). Tests named `test_Ethereum_*` show what the
/// same probe reports under Ethereum's environment; `test_Foundry_*` record
/// where Foundry's test chain differs from EastSea.
///
/// One runner per hazard keeps every test contract under EIP-170 (24,576 B),
/// which foundry.toml enforces like EastSea does.
abstract contract ProbeTest {
    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// Bare assertion (no forge-std).
    function check(bool cond, string memory what) internal pure {
        if (!cond) revert(what);
    }
}
