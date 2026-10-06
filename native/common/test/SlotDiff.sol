// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Vm, VmSafe} from "forge-std/Vm.sol";

/// @title Final-diff storage occupancy for one account
/// @notice Counts slots that are zero before and nonzero after (newly
///         occupied, 100 u each under design 27) and nonzero-to-zero slots
///         (cleared; no burn refund). Uses each slot's FIRST previous value
///         and LAST new value, so set-then-clear inside one call counts zero,
///         matching "the final committed difference against pre-state".
/// @dev Foundry-level layout check only. It is not the EastSea executor meter:
///      envelope, receipt and proving costs are filled by the recorder (GAS.md).
library SlotDiff {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Count {
        uint256 occupied;
        uint256 cleared;
    }

    function start() internal {
        vm.startStateDiffRecording();
    }

    function stop(address target) internal returns (Count memory c) {
        VmSafe.AccountAccess[] memory diff = vm.stopAndReturnStateDiff();
        // Collect unique written slots with first-previous / last-new values.
        bytes32[] memory slots = new bytes32[](256);
        bytes32[] memory firstPrev = new bytes32[](256);
        bytes32[] memory lastNew = new bytes32[](256);
        uint256 n;
        for (uint256 i; i < diff.length; i++) {
            if (diff[i].reverted) continue;
            VmSafe.StorageAccess[] memory sa = diff[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                if (!sa[j].isWrite || sa[j].reverted || sa[j].account != target) continue;
                uint256 k;
                for (; k < n; k++) {
                    if (slots[k] == sa[j].slot) break;
                }
                if (k == n) {
                    slots[n] = sa[j].slot;
                    firstPrev[n] = sa[j].previousValue;
                    n++;
                }
                lastNew[k] = sa[j].newValue;
            }
        }
        for (uint256 k; k < n; k++) {
            if (firstPrev[k] == 0 && lastNew[k] != 0) c.occupied++;
            else if (firstPrev[k] != 0 && lastNew[k] == 0) c.cleared++;
        }
    }
}
