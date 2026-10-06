// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice Shared helpers for the EastSea hazard probes.
///
/// Probes must stay standalone: no forge-std, no cheatcodes — the same files
/// are recompiled inside the EastSea executor harness. Every helper is
/// `internal`, so nothing here links into a separate contract.
library ProbeLib {
    /// @notice Deploy `runtime` as contract code (14-byte codecopy
    ///         constructor) and return the address. Used to execute raw
    ///         opcodes that the compiling solc may not emit itself.
    function deployRuntime(bytes memory runtime) internal returns (address addr) {
        bytes memory init = abi.encodePacked(
            hex"61", uint16(runtime.length), hex"600e60003961", uint16(runtime.length), hex"6000f3", runtime
        );
        assembly {
            addr := create(0, add(init, 0x20), mload(init))
        }
        require(addr != address(0), "ProbeLib: raw deploy failed");
    }

    /// @notice Plain CALL (TSTORE probes need a non-static frame).
    function call(address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }

    /// @notice STATICCALL with all gas forwarded.
    function staticCall(address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = target.staticcall(data);
    }

    /// @notice STATICCALL with an explicit gas cap — a precision gas probe:
    ///         a precompile succeeds at exactly its EIP cost and fails at
    ///         cost-1, regardless of call overhead.
    function cappedStaticCall(address target, bytes memory data, uint64 cap)
        internal
        returns (bool ok, bytes memory ret)
    {
        assembly {
            ok := staticcall(cap, target, add(data, 0x20), mload(data), 0, 0)
            let n := returndatasize()
            ret := mload(0x40)
            mstore(0x40, add(ret, add(n, 0x20)))
            mstore(ret, n)
            returndatacopy(add(ret, 0x20), 0, n)
        }
    }

    // ------------------------------------------------------------------ //
    //                       revert-on-mismatch checks                     //
    // ------------------------------------------------------------------ //

    function expectTrue(bool cond, string memory what) internal pure {
        if (!cond) revert(what);
    }

    function expectEq(bytes32 a, bytes32 b, string memory what) internal pure {
        if (a != b) revert(string.concat(what, ": got ", toHex(a), " want ", toHex(b)));
    }

    function expectEqBytes(bytes memory got, bytes memory want, string memory what) internal pure {
        bool same = got.length == want.length;
        for (uint256 i = 0; same && i < got.length; ++i) {
            same = got[i] == want[i];
        }
        if (!same) revert(string.concat(what, ": output mismatch"));
    }

    function expectEqAddr(address a, address b, string memory what) internal pure {
        if (a != b) revert(string.concat(what, ": address mismatch"));
    }

    function toHex(bytes32 v) internal pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        bytes memory s = new bytes(66);
        s[0] = "0";
        s[1] = "x";
        for (uint256 i = 0; i < 32; ++i) {
            s[2 + i * 2] = digits[uint8(v[i] >> 4)];
            s[3 + i * 2] = digits[uint8(v[i] & 0x0f)];
        }
        return string(s);
    }

    /// @notice bytes-memory slice (offset, length) — used to build precompile
    ///         inputs from shared constants.
    function slice(bytes memory b, uint256 start, uint256 len) internal pure returns (bytes memory r) {
        r = new bytes(len);
        for (uint256 i = 0; i < len; ++i) {
            r[i] = b[start + i];
        }
    }
}
