// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeLib} from "./ProbeLib.sol";

/// @notice Minimal ERC-721 subset for the H4 probe: safeTransferFrom with the
///         standard receiver check (standalone — no OpenZeppelin).
contract MiniERC721 {
    mapping(uint256 => address) public ownerOf;

    function safeMint(address to, uint256 id) external {
        ownerOf[id] = to;
        if (to.code.length > 0) {
            (bool ok, bytes memory ret) = to.call(abi.encodeWithSelector(0x150b7a02, msg.sender, address(0), id, ""));
            require(ok && abi.decode(ret, (bytes4)) == 0x150b7a02, "ERC721: receiver");
        }
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "ERC721: from");
        ownerOf[id] = to;
        if (to.code.length > 0) {
            (bool ok, bytes memory ret) = to.call(abi.encodeWithSelector(0x150b7a02, msg.sender, from, id, ""));
            require(ok && abi.decode(ret, (bytes4)) == 0x150b7a02, "ERC721: receiver");
        }
    }
}

/// @notice Today's EastSeaAccount shape under 7702: code present, receive()
///         only, no token receiver hooks (catalog B2).
contract NoHookAccount {
    receive() external payable {}
}

/// @notice The B2-fixed shape: receiver hooks present.
contract HookAccount {
    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }
}

/// @notice "No contracts at mint" guard as used by many NFT drops.
contract NoContractGuard {
    function check() external view {
        require(tx.origin == msg.sender, "guard: contract");
    }
}

/// @notice H4 — code on user accounts under EIP-7702 delegation.
///
/// A delegated EastSea user carries a 23-byte designator (0xef0100 || delegate)
/// instead of empty code. Pinned behaviours:
///
///   a. extcodesize(user) > 0 — "is contract" checks and tx.origin==msg.sender
///      mint guards branch to the CONTRACT side.
///   b. The current EastSeaAccount delegate has no token receiver hooks
///      (catalog B2), so safeTransferFrom/_safeMint to a delegated user
///      REVERT. This probe pins that failure; when B2 lands (hooks added),
///      the first assertion below flips to failing — that flip is the
///      regression signal to update the probe, not a bug.
///   c. With hooks present, the same transfer succeeds.
contract H04DelegatedAccounts {
    event Observed(string what, bool ok, bytes returnValue);

    MiniERC721 public token;
    NoContractGuard public guard;
    NoHookAccount public noHookDelegate;
    HookAccount public hookDelegate;

    constructor() {
        token = new MiniERC721();
        guard = new NoContractGuard();
        noHookDelegate = new NoHookAccount();
        hookDelegate = new HookAccount();
    }

    function run() external {
        receiverHooks();
    }

    /// b + c on plain contracts with the two delegate shapes.
    function receiverHooks() public {
        (bool ok,) =
            address(token).call(abi.encodeWithSignature("safeMint(address,uint256)", address(noHookDelegate), 1));
        ProbeLib.expectTrue(!ok, "H04: safeMint to hook-less delegate succeeded (B2 landed? update probe)");
        emit Observed("safeMint->no-hook reverts (B2)", true, "");

        (ok,) = address(token).call(abi.encodeWithSignature("safeMint(address,uint256)", address(hookDelegate), 2));
        ProbeLib.expectTrue(ok, "H04: safeMint to hooked account failed");
        (ok,) = address(token)
            .call(
                abi.encodeWithSignature(
                    "safeTransferFrom(address,address,uint256)", address(hookDelegate), address(hookDelegate), 2
                )
            );
        ProbeLib.expectTrue(ok, "H04: safeTransferFrom hooked->hooked failed");
        emit Observed("safeMint->hooked ok", true, "");
    }

    /// b on a REAL delegated user (7702 designator in place). The harness
    /// passes an EastSea user delegated to today's EastSeaAccount and
    /// `expectOk = false` (B2 open); after B2, `expectOk = true`.
    function safeMintToDelegatedUser(address user, uint256 id, bool expectOk) external {
        ProbeLib.expectTrue(user.code.length == 23, "H04: user is not 7702-delegated (code != 23 bytes)");
        (bool ok,) = address(token).call(abi.encodeWithSignature("safeMint(address,uint256)", user, id));
        ProbeLib.expectTrue(ok == expectOk, "H04: safeMint to delegated user: unexpected outcome");
        emit Observed("safeMint->delegated user", ok, abi.encode(user));
    }

    /// a: a 23-byte 0xef0100||delegate designator counts as code. The wrapper
    /// (or the EastSea harness) etches the designator on a plain address and
    /// calls this to confirm the shape EastSea produces.
    function delegatedCodeShape(address a) external view returns (uint256 size, bool isDesignator) {
        size = a.code.length;
        isDesignator = size == 23 && a.code[0] == 0xef && a.code[1] == 0x01 && a.code[2] == 0x00;
    }

    /// The designator bytes for a delegate — vm.etch input for the wrapper.
    function designatorFor(address delegate) external pure returns (bytes memory) {
        return abi.encodePacked(bytes3(0xef0100), delegate);
    }
}
