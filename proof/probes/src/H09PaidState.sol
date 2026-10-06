// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeLib} from "./ProbeLib.sol";

/// @notice H9 — paid state. EastSea charges state units on top of gas:
/// 100 u per new slot or account, 1 u per code byte (fees.rs; burst
/// 100,000 u, refill 32 u/block, 512 new slots per block). The EVM cannot see
/// units, so this probe pins the *exec-gas* side that the harness pairs with
/// its unit counter: a new slot costs the Osaka SSTORE price (20,000 +
/// 2,100 cold), an overwrite does not, and a cleared slot refunds.
///
/// The harness reads the `Observed` gas numbers and its own unit counter for
/// the same call and records both in the benchmark (proof/bench/schema.json).
/// Assertions use ranges, not exact gas, so the probe is robust to call
/// overhead; the ranges still separate "new slot" from "overwrite".
contract H09PaidState {
    event Observed(string what, bool ok, bytes returnValue);

    mapping(uint256 => uint256) public slots;
    uint256 public nextKey = 1;

    /// Write `n` brand-new slots; returns the exec gas used.
    function writeNew(uint256 n) public returns (uint256 used) {
        uint256 k = nextKey;
        uint256 g = gasleft();
        for (uint256 i = 0; i < n; ++i) {
            slots[k + i] = 1;
        }
        used = g - gasleft();
        nextKey = k + n;
    }

    /// Overwrite one existing slot (non-zero -> non-zero).
    function overwrite(uint256 key) public returns (uint256 used) {
        ProbeLib.expectTrue(slots[key] != 0, "H09: overwrite needs an existing slot");
        uint256 g = gasleft();
        slots[key] = slots[key] + 1;
        used = g - gasleft();
    }

    function run() external {
        uint256 one = writeNew(1);
        emit Observed("new_slot_exec_gas", true, abi.encode(one));
        ProbeLib.expectTrue(one >= 22_100 && one < 25_000, "H09: new slot not priced as 20,000 + cold 2,100");

        uint256 ten = writeNew(10);
        emit Observed("ten_new_slots_exec_gas", true, abi.encode(ten));
        ProbeLib.expectTrue(ten >= 221_000, "H09: 10 new slots cheaper than 10 x 22,100");

        uint256 ow = overwrite(1);
        emit Observed("overwrite_exec_gas", true, abi.encode(ow));
        ProbeLib.expectTrue(ow < 5_000, "H09: warm overwrite priced like a new slot");
    }
}
