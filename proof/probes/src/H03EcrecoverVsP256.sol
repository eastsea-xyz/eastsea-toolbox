// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeLib} from "./ProbeLib.sol";

/// @notice H3 — signature worlds: secp256k1 ecrecover vs P-256 P256VERIFY.
///
/// EastSea user accounts are P-256 (the 7702 authorisation is the signature).
/// The two curves are incompatible in BOTH directions, which this probe pins:
///
///   1. ecrecover never returns a P-256 key's account address: feeding the
///      RIP-7212 (r, s) pair to ecrecover yields empty or an unrelated
///      secp256k1 address — never address(pubkey).
///   2. P256VERIFY never accepts a secp256k1 ECDSA signature: the d=1
///      secp256k1 (r, s) under the secp256k1 generator fails P-256 verify.
///
/// Consequence (catalog B1/B6): every off-chain-signature flow that branches
/// on ERC-1271 for accounts-with-code needs the account to implement
/// isValidSignature; today's EastSeaAccount does not (blocker B1).
contract H03EcrecoverVsP256 {
    event Observed(string what, bool ok, bytes returnValue);

    // secp256k1 d=1: Q = G = (0x79be…, 0x483a…), address 0x7E5F…5Bdf.
    uint256 constant SECP_GX = 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798;
    uint256 constant SECP_GY = 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8;

    // P-256 key whose (r, s, Qx, Qy) is the RIP-7212 appendix vector.
    uint256 constant P256_QX = 0x7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978;
    uint256 constant P256_QY = 0x07775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1;

    function run() external {
        p256SignatureNeverEcrecovers();
        secpSignatureNeverP256Verifies();
    }

    /// keccak256(Qx || Qy)[12:] — the conventional account address a P-256
    /// pubkey maps to (EastSea derives account addresses from the P-256 key).
    function p256AccountAddress() public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(P256_QX, P256_QY)))));
    }

    function ecrecoverVec() internal pure returns (bytes32 h, uint8 v, bytes32 r, bytes32 s) {
        h = 0x9d944381ba8369ee99406398a6969380c20de44e8fd930bcbbf7f5274bf2d6aa;
        v = 27;
        r = 0xa3df1a863c1271b7ea9d2019f1c42d1eeb44e320e704fd781674c7ed94b527e7;
        s = 0x76ba229833b1d11e776a712f7cf8720d0ebeec1e90ae0e6d694b4513b0ba999a;
    }

    /// 1. The P-256 (r, s) fed to ecrecover (both v parities) recovers
    ///    nothing or an address != the P-256 account address.
    function p256SignatureNeverEcrecovers() public {
        bytes32 digest = 0x387185b4aa14a19c0b6dab44a8cc133394c73896e113258ac604a98c3407af96;
        bytes32 r = 0x60064f0b8cba0edaad89bf9c0eeeb4bd447461fb88b184950501cc1c34db3364;
        bytes32 s = 0x835115c0e0a393388ef444daf5fef46695e252d13fd26903e2b784222bf1f751;
        address want = p256AccountAddress();
        for (uint8 v = 27; v <= 28; ++v) {
            address got = ecrecover(digest, v, r, s);
            ProbeLib.expectTrue(got != want, "H03: ecrecover(P-256 sig) returned the P-256 account address");
            emit Observed("ecrecover(P256 sig)", got == address(0), abi.encodePacked(got));
        }
    }

    /// 2. The valid secp256k1 (r, s) over the same-class hash fails
    ///    P256VERIFY even with the correct secp generator as "public key".
    function secpSignatureNeverP256Verifies() public {
        (bytes32 h,, bytes32 r, bytes32 s) = ecrecoverVec();
        bytes memory in_ = abi.encodePacked(h, r, s, SECP_GX, SECP_GY);
        (bool ok, bytes memory ret) = ProbeLib.staticCall(address(0x100), in_);
        ProbeLib.expectTrue(ok, "H03: p256verify call errored");
        // Failure = empty output (EIP-7951); success = 32-byte 1.
        bool verified = ret.length == 32 && bytes32(ret) == bytes32(uint256(1));
        ProbeLib.expectTrue(!verified, "H03: P256VERIFY accepted a secp256k1 signature");
        emit Observed("p256verify(secp sig)", true, ret);
    }
}
