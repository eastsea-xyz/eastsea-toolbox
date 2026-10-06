// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeLib} from "./ProbeLib.sol";

/// @notice Probe victim for H10 — plain contract with a selfdestruct entry.
contract SelfdestructVictim {
    function stillAlive() external pure returns (bool) {
        return true;
    }

    function destruct(address payable to) external {
        selfdestruct(to);
    }
}

/// @notice H10 — SELFDESTRUCT under EIP-6780 (Cancun+ semantics).
///
///   - Contract created in an EARLIER transaction: SELFDESTRUCT only moves
///     the balance; code and storage persist and stay callable. This is the
///     observable change vs pre-Cancun, and it is what old factories relying
///     on redeploy-after-destruct break on.
///   - Contract created in the SAME transaction: deleted at end of tx (the
///     wrapper/harness re-checks emptiness after the real tx boundary).
contract H10Selfdestruct {
    event Observed(string what, bool ok, bytes returnValue);

    /// Deployed by the wrapper in a prior call (its own "transaction"), then
    /// destructed from this transaction: EIP-6780 keeps the code.
    function checkCrossTxDestruct(SelfdestructVictim victim) external {
        uint256 sizeBefore = address(victim).code.length;
        (bool ok,) = address(victim).call(abi.encodeWithSignature("destruct(address)", address(this)));
        ProbeLib.expectTrue(ok, "H10: destruct call failed");
        ProbeLib.expectTrue(
            address(victim).code.length == sizeBefore && sizeBefore > 0,
            "H10: code vanished after cross-tx SELFDESTRUCT (pre-6780 semantics?)"
        );
        (ok,) = address(victim).call(abi.encodeWithSignature("stillAlive()"));
        ProbeLib.expectTrue(ok, "H10: victim not callable after cross-tx SELFDESTRUCT");
        emit Observed("selfdestruct_cross_tx_persists", true, abi.encode(address(victim)));
    }

    /// Created and destructed inside this same call: still visible until the
    /// end-of-tx sweep (deletion itself needs a real tx boundary — asserted
    /// by the EastSea harness afterwards).
    function run() external {
        SelfdestructVictim v = new SelfdestructVictim();
        (bool ok,) = address(v).call(abi.encodeWithSignature("destruct(address)", address(this)));
        ProbeLib.expectTrue(ok, "H10: same-tx destruct call failed");
        emit Observed("selfdestruct_same_tx_visible_until_tx_end", true, abi.encode(address(v)));
    }
}
