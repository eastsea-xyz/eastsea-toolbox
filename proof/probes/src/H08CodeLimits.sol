// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice H8 — size and gas limits: EIP-170 (24,576 B code), EIP-3860
/// (49,152 B initcode), and the EIP-7825 per-tx gas cap (16,777,216).
///
/// Each CREATE runs in a gas-capped self-call, because the two limits fail
/// differently:
///   - runtime over 24,576 B: CREATE returns 0 and burns the gas it was given;
///   - initcode over 49,152 B: the *calling frame* aborts (EIP-3860), so it
///     must be isolated in its own frame to be observed.
/// The caps keep the whole run() under the EIP-7825 per-tx cap, so the same
/// probe fits one EastSea transaction. The cap itself is enforced by the
/// node, not observable from inside: run() only records gasleft().
contract H08CodeLimits {
    event Observed(string what, bool ok, bytes returnValue);

    uint256 constant CODE_LIMIT = 24576;
    uint256 constant INITCODE_LIMIT = 49152;
    uint256 constant TX_GAS_CAP = 16_777_216;
    /// 24,576 B x 200 gas deposit = 4.9 M; plus 32,000 and memory.
    uint256 constant BIG_DEPLOY_GAS = 5_500_000;
    uint256 constant SMALL_DEPLOY_GAS = 200_000;

    function run() external {
        emit Observed("gasleft_at_start", gasleft() <= TX_GAS_CAP, abi.encode(gasleft()));
        require(tryCreate(CODE_LIMIT + 14, CODE_LIMIT, BIG_DEPLOY_GAS), "H08: deploy at exactly 24,576 B failed");
        emit Observed("code_24576_ok", true, "");
        require(
            !tryCreate(CODE_LIMIT + 15, CODE_LIMIT + 1, BIG_DEPLOY_GAS), "H08: deploy of 24,577 B runtime succeeded"
        );
        emit Observed("code_24577_rejected", true, "");
        require(tryCreate(INITCODE_LIMIT, 100, SMALL_DEPLOY_GAS), "H08: initcode at exactly 49,152 B failed");
        emit Observed("initcode_49152_ok", true, "");
        require(!tryCreate(INITCODE_LIMIT + 1, 100, SMALL_DEPLOY_GAS), "H08: initcode of 49,153 B accepted");
        emit Observed("initcode_49153_rejected", true, "");
    }

    function tryCreate(uint256 initLen, uint256 runtimeLen, uint256 gasCap) internal returns (bool ok) {
        (ok,) = address(this).call{gas: gasCap}(abi.encodeCall(this.createSized, (initLen, runtimeLen)));
    }

    /// init = PUSH2 len PUSH1 14 PUSH1 0 CODECOPY PUSH2 len PUSH1 0 RETURN,
    /// followed by zero bytes (STOP). Initcode past the 14-byte prefix and
    /// the returned runtime is never executed but counts for the limits.
    /// Reverts if CREATE returned address(0).
    function createSized(uint256 initLen, uint256 runtimeLen) external returns (address a) {
        bytes memory init = new bytes(initLen);
        bytes memory prefix =
            abi.encodePacked(hex"61", uint16(runtimeLen), hex"600e600039", hex"61", uint16(runtimeLen), hex"6000f3");
        for (uint256 i = 0; i < prefix.length; ++i) {
            init[i] = prefix[i];
        }
        assembly {
            a := create(0, add(init, 0x20), mload(init))
        }
        require(a != address(0), "H08: create returned 0");
    }
}
