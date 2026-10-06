// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeLib} from "./ProbeLib.sol";

/// @notice H1 — opcode support on the target EVM (EastSea: revm, Osaka spec).
///
/// EastSea pin (clone-catalog H1/B4): PUSH0, TSTORE/TLOAD, MCOPY and CLZ are
/// active; BLOBHASH returns 0 because no transaction carries blobs; BLOBBASEFEE
/// is derived from the default blob excess and is at least 1 wei.
///
/// Every opcode is executed as raw runtime code deployed by ProbeLib so the
/// result does not depend on which opcodes the compiling solc emits.
contract H01Opcodes {
    /// Emitted for each raw probe so runs can be diffed as logs.
    event Observed(string what, bool ok, bytes returnValue);

    function run() external {
        push0();
        transientStorage();
        mcopy();
        clz();
        blobhash_();
        blobbasefee();
    }

    // PUSH0 (0x5f) — EIP-3855. Expected: pushes a zero value.
    function push0() public {
        // PUSH0 PUSH0 MSTORE(0, 0); RETURN(0, 32)
        (bool ok, bytes memory ret) = ProbeLib.call(ProbeLib.deployRuntime(hex"5f5f5260205ff3"), "");
        ProbeLib.expectTrue(ok, "H01/PUSH0: call failed (opcode not supported?)");
        ProbeLib.expectEqBytes(ret, new bytes(32), "H01/PUSH0: zero value");
        emit Observed("PUSH0", ok, ret);

        // PUSH1 0x2b PUSH0 MSTORE(0, 0x2b); RETURN(0, 32) — proves PUSH0 is
        // the *offset* zero, not the value.
        (ok, ret) = ProbeLib.call(ProbeLib.deployRuntime(hex"602b5f5260205ff3"), "");
        ProbeLib.expectTrue(ok, "H01/PUSH0(value): call failed");
        ProbeLib.expectEq(bytes32(ret), bytes32(uint256(0x2b)), "H01/PUSH0(value)");
        emit Observed("PUSH0-value", ok, ret);
    }

    // TSTORE/TLOAD (0x5d/0x5c) — EIP-1153. Expected: round-trip within one
    // transaction, per-contract visibility, fresh zero before the first store.
    function transientStorage() public {
        // Runtime: empty calldata -> return TLOAD(0); otherwise store
        // calldata[0..32] into transient slot 0.
        //   0x00 CALLDATASIZE ISZERO PUSH1 0x0b JUMPI    ; size==0 -> 0x0b
        //   0x05 PUSH1 0 CALLDATALOAD PUSH0 TSTORE STOP  ; tstore(key 0, value)
        //   0x0b JUMPDEST PUSH0 TLOAD PUSH1 0 MSTORE
        //        PUSH1 0x20 PUSH0 RETURN                 ; read branch
        address t = ProbeLib.deployRuntime(hex"3615600b576000355f5d005b5f5c60005260205ff3");

        (bool ok, bytes memory ret) = ProbeLib.call(t, "");
        ProbeLib.expectTrue(ok, "H01/TSTORE: initial read failed");
        ProbeLib.expectEq(bytes32(ret), bytes32(0), "H01/TSTORE: slot starts zero");

        (ok, ret) = ProbeLib.call(t, abi.encode(uint256(0x115c)));
        ProbeLib.expectTrue(ok, "H01/TSTORE: store call failed (opcode not supported?)");

        (ok, ret) = ProbeLib.call(t, "");
        ProbeLib.expectTrue(ok, "H01/TLOAD: read call failed");
        ProbeLib.expectEq(bytes32(ret), bytes32(uint256(0x115c)), "H01/TLOAD: persistence within tx");
        emit Observed("TSTORE/TLOAD", ok, ret);
    }

    // MCOPY (0x5e) — EIP-5656. Expected: memory copy with overlapping-safe
    // semantics; here a plain 32-byte copy.
    function mcopy() public {
        bytes32 val = keccak256("eastsea-mcopy-probe");
        // PUSH32 val PUSH0 MSTORE; PUSH1 0x20 PUSH0 PUSH1 0x20 MCOPY
        //   (dest=0x20, src=0, len=0x20); RETURN(0x20, 0x20)
        bytes memory code = abi.encodePacked(hex"7f", val, hex"6000526020600060205e60206020f3");
        (bool ok, bytes memory ret) = ProbeLib.call(ProbeLib.deployRuntime(code), "");
        ProbeLib.expectTrue(ok, "H01/MCOPY: call failed (opcode not supported?)");
        ProbeLib.expectEq(bytes32(ret), val, "H01/MCOPY: copied value");
        emit Observed("MCOPY", ok, ret);
    }

    // CLZ (0x1e) — EIP-7939. Expected: count of leading zero bits; CLZ(0) = 256.
    function clz() public {
        clzOne(bytes32(0), 256);
        clzOne(bytes32(uint256(1)), 255);
        clzOne(bytes32(uint256(1) << 255), 0);
        // top byte 0x00, next byte 0xff: exactly 8 leading zero bits
        clzOne(bytes32(bytes2(0x00ff)), 8);
    }

    function clzOne(bytes32 x, uint256 want) internal {
        // PUSH32 x CLZ PUSH0 MSTORE PUSH1 0x20 PUSH0 RETURN
        bytes memory code = abi.encodePacked(hex"7f", x, hex"1e5f5260205ff3");
        (bool ok, bytes memory ret) = ProbeLib.call(ProbeLib.deployRuntime(code), "");
        ProbeLib.expectTrue(ok, "H01/CLZ: call failed (opcode not supported?)");
        ProbeLib.expectEq(bytes32(ret), bytes32(want), "H01/CLZ: wrong leading-zero count");
        emit Observed("CLZ", ok, ret);
    }

    // BLOBHASH (0x49) — EIP-4844. Expected on EastSea: index 0 returns 0
    // (no blob-carrying transactions).
    function blobhash_() public {
        // PUSH1 0 BLOBHASH PUSH0 MSTORE PUSH1 0x20 PUSH0 RETURN
        (bool ok, bytes memory ret) = ProbeLib.call(ProbeLib.deployRuntime(hex"6000495f5260205ff3"), "");
        ProbeLib.expectTrue(ok, "H01/BLOBHASH: call failed");
        ProbeLib.expectEq(bytes32(ret), bytes32(0), "H01/BLOBHASH: expected 0 (no blobs)");
        emit Observed("BLOBHASH[0]", ok, ret);
    }

    // BLOBBASEFEE (0x4a) — EIP-7516. Expected: at least 1 wei (revm derives
    // it from the default blob excess).
    function blobbasefee() public view {
        uint256 fee = block.blobbasefee;
        ProbeLib.expectTrue(fee >= 1, "H01/BLOBBASEFEE: expected >= 1 wei");
    }
}
