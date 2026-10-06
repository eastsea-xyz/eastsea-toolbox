// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {ProbeLib} from "./ProbeLib.sol";

/// @notice H2 - precompile suite 0x01-0x0a, BLS12-381 0x0b-0x11 (EIP-2537 final
///         layout), P256VERIFY 0x100.
///
/// Every vector is the canonical EIP test vector (sources in probes/README.md).
/// Gas is asserted *exactly* with cappedStaticCall: a precompile succeeds at
/// its EIP cost and fails at cost-1, independent of call overhead. If EastSea
/// ever adopts EIP-7667 hash-gas repricing (design 04), the sha256/ripemd
/// assertions here flip to failing - that is the point of the probe.
///
/// BLS12-381 gas is recorded but not asserted (EIP-2537 pricing history);
/// correctness of the point arithmetic is asserted instead.
contract H02Precompiles {
    address constant ECRECOVER = address(0x01);
    address constant SHA256 = address(0x02);
    address constant RIPEMD160 = address(0x03);
    address constant IDENTITY = address(0x04);
    address constant MODEXP = address(0x05);
    address constant ECADD = address(0x06);
    address constant ECMUL = address(0x07);
    address constant PAIRING = address(0x08);
    address constant BLAKE2F = address(0x09);
    address constant KZG_POINT_EVAL = address(0x0a);
    address constant BLS_G1ADD = address(0x0b);
    address constant BLS_G1MSM = address(0x0c);
    address constant BLS_G2ADD = address(0x0d);
    address constant BLS_G2MSM = address(0x0e);
    address constant BLS_PAIRING = address(0x0f);
    address constant BLS_MAP_FP_G1 = address(0x10);
    address constant BLS_MAP_FP2_G2 = address(0x11);
    address constant P256VERIFY = address(0x100);

    event Observed(string what, bool ok, bytes returnValue);

    // Single-literal hex constants (Solidity forbids adjacent literals after
    // hex""). Machine-generated from the EIP appendix tables and cross-checked
    // in Python (sha256/blake2b via hashlib); sources in probes/README.md.
    bytes constant ECREC_IN =
        hex"9d944381ba8369ee99406398a6969380c20de44e8fd930bcbbf7f5274bf2d6aa000000000000000000000000000000000000000000000000000000000000001ba3df1a863c1271b7ea9d2019f1c42d1eeb44e320e704fd781674c7ed94b527e776ba229833b1d11e776a712f7cf8720d0ebeec1e90ae0e6d694b4513b0ba999a";
    bytes constant ECREC_BAD =
        hex"9d944381ba8369ee99406398a6969380c20de44e8fd930bcbbf7f5274bf2d6aa000000000000000000000000000000000000000000000000000000000000001da3df1a863c1271b7ea9d2019f1c42d1eeb44e320e704fd781674c7ed94b527e776ba229833b1d11e776a712f7cf8720d0ebeec1e90ae0e6d694b4513b0ba999a";
    bytes constant MODEXP_V1 =
        hex"000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001030507";
    bytes constant MODEXP_V2 =
        hex"00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000103100005";
    bytes constant PAIR_G1 =
        hex"00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002";
    bytes constant PAIR_G1_NEG =
        hex"000000000000000000000000000000000000000000000000000000000000000130644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd45";
    bytes constant PAIR_G2 =
        hex"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa";
    bytes constant BN254_2G1 =
        hex"030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd315ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4";
    bytes constant BLAKE_IN =
        hex"0000000c48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000001";
    bytes constant BLAKE_OUT =
        hex"ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923";
    bytes constant KZG_IN =
        hex"01cf478a431837728dcec3461f4f53b8749cdc4e03496dcaed459dea82b82eb80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000197f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bbc00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    bytes constant BLS_G1 =
        hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb0000000000000000000000000000000008b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1";
    bytes constant BLS_2G1 =
        hex"000000000000000000000000000000000572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e00000000000000000000000000000000166a9d8cabc673a322fda673779d8e3822ba3ecb8670e461f73bb9021d5fd76a4c56d9d4cd16bd1bba86881979749d28";
    bytes constant BLS_G1ADD_IN =
        hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb0000000000000000000000000000000008b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    bytes constant BLS_G1MSM_IN =
        hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb0000000000000000000000000000000008b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e10000000000000000000000000000000000000000000000000000000000000002";
    bytes constant P256_IN =
        hex"387185b4aa14a19c0b6dab44a8cc133394c73896e113258ac604a98c3407af9660064f0b8cba0edaad89bf9c0eeeb4bd447461fb88b184950501cc1c34db3364835115c0e0a393388ef444daf5fef46695e252d13fd26903e2b784222bf1f7517cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1";

    function run() external {
        ecrecover_();
        sha256_();
        ripemd160_();
        identity();
        modexp();
        ecadd();
        ecmul();
        pairing();
        blake2f();
        kzg();
        bls();
        p256();
    }

    // 0x01 ecrecover (3000 gas) - key d=1 => 0x7E5F...5Bdf, low-s per EIP-2.
    function ecrecover_() public {
        (bool ok, bytes memory ret) = ProbeLib.cappedStaticCall(ECRECOVER, ECREC_IN, 3000);
        ProbeLib.expectTrue(ok, "H02/ecrecover: failed at gas 3000");
        ProbeLib.expectEq(
            bytes32(ret),
            bytes32(uint256(uint160(0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf))),
            "H02/ecrecover: wrong signer"
        );
        (ok,) = ProbeLib.cappedStaticCall(ECRECOVER, ECREC_IN, 2999);
        ProbeLib.expectTrue(!ok, "H02/ecrecover: succeeded at gas 2999");
        emit Observed("ecrecover", true, ret);

        // v = 29 is outside {27, 28}: must recover nothing (empty output).
        (ok, ret) = ProbeLib.staticCall(ECRECOVER, ECREC_BAD);
        ProbeLib.expectTrue(ok && ret.length == 0, "H02/ecrecover: bad sig not rejected");
    }

    // 0x02 sha256 - gas 60 + 12*words.
    function sha256_() public {
        (bool ok, bytes memory ret) = ProbeLib.cappedStaticCall(SHA256, "", 60);
        ProbeLib.expectTrue(ok, "H02/sha256: empty failed at gas 60");
        ProbeLib.expectEq(
            bytes32(ret),
            bytes32(hex"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            "H02/sha256: empty"
        );
        (ok,) = ProbeLib.cappedStaticCall(SHA256, "", 59);
        ProbeLib.expectTrue(!ok, "H02/sha256: empty succeeded at 59");

        (ok, ret) = ProbeLib.cappedStaticCall(SHA256, "abc", 72); // 60 + 12*1
        ProbeLib.expectTrue(ok, "H02/sha256: abc failed at gas 72");
        ProbeLib.expectEq(
            bytes32(ret),
            bytes32(hex"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            "H02/sha256: abc"
        );
        (ok,) = ProbeLib.cappedStaticCall(SHA256, "abc", 71);
        ProbeLib.expectTrue(!ok, "H02/sha256: abc succeeded at 71");
        emit Observed("sha256[empty,abc]", true, ret);
    }

    // 0x03 ripemd160 - gas 600 + 120*words; output is left-padded address word.
    function ripemd160_() public {
        (bool ok, bytes memory ret) = ProbeLib.cappedStaticCall(RIPEMD160, "", 600);
        ProbeLib.expectTrue(ok, "H02/ripemd160: failed at gas 600");
        ProbeLib.expectEq(
            bytes32(ret), bytes32(uint256(uint160(0x9c1185A5C5E9Fc54612808977ee8F548B2258D31))), "H02/ripemd160: empty"
        );
        (ok,) = ProbeLib.cappedStaticCall(RIPEMD160, "", 599);
        ProbeLib.expectTrue(!ok, "H02/ripemd160: succeeded at 599");
        emit Observed("ripemd160[empty]", true, ret);
    }

    // 0x04 identity - gas 15 + 3*words.
    function identity() public {
        bytes32 word = keccak256("eastsea-identity");
        (bool ok, bytes memory ret) = ProbeLib.cappedStaticCall(IDENTITY, abi.encodePacked(word), 18);
        ProbeLib.expectTrue(ok, "H02/identity: failed at gas 18");
        ProbeLib.expectEq(bytes32(ret), word, "H02/identity: echo");
        (ok,) = ProbeLib.cappedStaticCall(IDENTITY, abi.encodePacked(word), 17);
        ProbeLib.expectTrue(!ok, "H02/identity: succeeded at 17");
        emit Observed("identity", true, ret);
    }

    // 0x05 modexp. Osaka pricing (EIP-7883): floor 500 (was 200 under
    // EIP-2565). 3^5 mod 7 = 5; 3^4096 mod 5 = 1.
    function modexp() public {
        (bool ok, bytes memory ret) = ProbeLib.cappedStaticCall(MODEXP, MODEXP_V1, 500);
        ProbeLib.expectTrue(ok, "H02/modexp: v1 failed at gas 500 (Osaka EIP-7883 floor)");
        ProbeLib.expectEqBytes(ret, hex"05", "H02/modexp: 3^5 mod 7");
        (ok,) = ProbeLib.cappedStaticCall(MODEXP, MODEXP_V1, 499);
        ProbeLib.expectTrue(!ok, "H02/modexp: v1 succeeded at 499 (pre-Osaka pricing?)");

        (ok, ret) = ProbeLib.cappedStaticCall(MODEXP, MODEXP_V2, 500);
        ProbeLib.expectTrue(ok, "H02/modexp: v2 failed at gas 500");
        ProbeLib.expectEqBytes(ret, hex"01", "H02/modexp: 3^4096 mod 5");
        emit Observed("modexp", true, ret);
    }

    // 0x06 ecadd (EIP-1108: 150 gas): (1,2)+(1,2) = 2*G1.
    function ecadd() public {
        bytes memory in_ = abi.encode(uint256(1), uint256(2), uint256(1), uint256(2));
        (bool ok, bytes memory ret) = ProbeLib.cappedStaticCall(ECADD, in_, 150);
        ProbeLib.expectTrue(ok, "H02/ecadd: failed at gas 150");
        ProbeLib.expectEqBytes(ret, BN254_2G1, "H02/ecadd: 2*G1");
        (ok,) = ProbeLib.cappedStaticCall(ECADD, in_, 149);
        ProbeLib.expectTrue(!ok, "H02/ecadd: succeeded at 149");
        emit Observed("ecadd", true, ret);
    }

    // 0x07 ecmul (6000 gas): 2*(1,2) = 2*G1.
    function ecmul() public {
        bytes memory in_ = abi.encode(uint256(1), uint256(2), uint256(2));
        (bool ok, bytes memory ret) = ProbeLib.cappedStaticCall(ECMUL, in_, 6000);
        ProbeLib.expectTrue(ok, "H02/ecmul: failed at gas 6000");
        ProbeLib.expectEqBytes(ret, BN254_2G1, "H02/ecmul: 2*G1");
        (ok,) = ProbeLib.cappedStaticCall(ECMUL, in_, 5999);
        ProbeLib.expectTrue(!ok, "H02/ecmul: succeeded at 5999");
        emit Observed("ecmul", true, ret);
    }

    // 0x08 pairing (45000 + 34000*k): e(P,Q)*e(-P,Q) = 1; empty input = 1.
    function pairing() public {
        bytes memory good = abi.encodePacked(PAIR_G1, PAIR_G2, PAIR_G1_NEG, PAIR_G2);
        (bool ok, bytes memory ret) = ProbeLib.cappedStaticCall(PAIRING, good, 113000);
        ProbeLib.expectTrue(ok, "H02/pairing: 2 pairs failed at gas 113000");
        ProbeLib.expectEqBytes(
            ret,
            hex"0000000000000000000000000000000000000000000000000000000000000001",
            "H02/pairing: e(P,Q)*e(-P,Q) != 1"
        );
        (ok,) = ProbeLib.cappedStaticCall(PAIRING, good, 112999);
        ProbeLib.expectTrue(!ok, "H02/pairing: succeeded at 112999");

        (ok, ret) = ProbeLib.cappedStaticCall(PAIRING, "", 45000);
        ProbeLib.expectTrue(ok, "H02/pairing: 0 pairs failed at gas 45000");
        ProbeLib.expectEqBytes(
            ret, hex"0000000000000000000000000000000000000000000000000000000000000001", "H02/pairing: empty != 1"
        );

        // Same pair twice: e(P,Q)^2 != 1 -> 0.
        bytes memory twice = abi.encodePacked(PAIR_G1, PAIR_G2, PAIR_G1, PAIR_G2);
        (ok, ret) = ProbeLib.staticCall(PAIRING, twice);
        ProbeLib.expectTrue(ok, "H02/pairing: bad call failed");
        ProbeLib.expectEqBytes(
            ret, hex"0000000000000000000000000000000000000000000000000000000000000000", "H02/pairing: (P,Q)^2 != 0"
        );
        emit Observed("pairing[2 pairs -> 1]", true, ret);
    }

    // 0x09 blake2f (EIP-152): 12-round "abc" final block; gas = rounds.
    function blake2f() public {
        (bool ok, bytes memory ret) = ProbeLib.cappedStaticCall(BLAKE2F, BLAKE_IN, 12);
        ProbeLib.expectTrue(ok, "H02/blake2f: failed at gas 12 (= rounds)");
        ProbeLib.expectEqBytes(ret, BLAKE_OUT, "H02/blake2f: wrong digest (= blake2b-512 of abc)");
        (ok,) = ProbeLib.cappedStaticCall(BLAKE2F, BLAKE_IN, 11);
        ProbeLib.expectTrue(!ok, "H02/blake2f: succeeded at 11");
        emit Observed("blake2f[12 rounds]", true, ret);
    }

    // 0x0a KZG point evaluation (EIP-4844, 50000 gas): p(x) = 1 at z = 0,
    // commitment = compressed G1 generator, proof = compressed identity.
    // Success returns FIELD_ELEMENTS_PER_BLOB (4096) || BLS_MODULUS.
    function kzg() public {
        (bool ok, bytes memory ret) = ProbeLib.cappedStaticCall(KZG_POINT_EVAL, KZG_IN, 50000);
        ProbeLib.expectTrue(ok, "H02/kzg: failed at gas 50000");
        ProbeLib.expectEqBytes(
            ret,
            abi.encode(uint256(4096), uint256(0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001)),
            "H02/kzg: wrong success output"
        );
        (ok,) = ProbeLib.cappedStaticCall(KZG_POINT_EVAL, KZG_IN, 49999);
        ProbeLib.expectTrue(!ok, "H02/kzg: succeeded at 49999");
        emit Observed("kzg[p(x)=1]", true, ret);
    }

    // 0x0b-0x11 BLS12-381 (EIP-2537 final: G1ADD, G1MSM, G2ADD, G2MSM,
    // PAIRING_CHECK, MAP_FP_TO_G1, MAP_FP2_TO_G2), 64-byte right-aligned
    // coordinates. Correctness asserted; gas only recorded (see README).
    function bls() public {
        (bool ok, bytes memory ret) = ProbeLib.staticCall(BLS_G1ADD, BLS_G1ADD_IN);
        ProbeLib.expectTrue(ok, "H02/bls-g1add: call failed (precompile missing?)");
        ProbeLib.expectEqBytes(ret, BLS_G1, "H02/bls-g1add: G1 + O != G1");
        emit Observed("bls-g1add[G1+O]", ok, ret);

        // G1MSM with one (point, scalar) pair = scalar multiplication.
        (ok, ret) = ProbeLib.staticCall(BLS_G1MSM, BLS_G1MSM_IN);
        ProbeLib.expectTrue(ok, "H02/bls-g1msm: call failed (precompile missing?)");
        ProbeLib.expectEqBytes(ret, BLS_2G1, "H02/bls-g1msm: 2*G1");
        emit Observed("bls-g1msm[2*G1]", ok, ret);

        (ok, ret) = ProbeLib.staticCall(BLS_G2ADD, new bytes(512));
        ProbeLib.expectTrue(ok, "H02/bls-g2add: call failed (precompile missing?)");
        ProbeLib.expectEqBytes(ret, new bytes(256), "H02/bls-g2add: O + O != O");
        emit Observed("bls-g2add[O+O]", ok, ret);

        // G2MSM: O * 1 = O (256-byte point || 32-byte scalar).
        bytes memory g2msmIn = abi.encodePacked(new bytes(256), uint256(1));
        (ok, ret) = ProbeLib.staticCall(BLS_G2MSM, g2msmIn);
        ProbeLib.expectTrue(ok, "H02/bls-g2msm: call failed (precompile missing?)");
        ProbeLib.expectEqBytes(ret, new bytes(256), "H02/bls-g2msm: O*1 != O");
        emit Observed("bls-g2msm[O*1]", ok, ret);

        // PAIRING_CHECK: e(O, O) = 1 (one 384-byte pair of infinities).
        (ok, ret) = ProbeLib.staticCall(BLS_PAIRING, new bytes(384));
        ProbeLib.expectTrue(ok, "H02/bls-pairing: call failed (precompile missing?)");
        ProbeLib.expectEq(bytes32(ret), bytes32(uint256(1)), "H02/bls-pairing: e(O,O) != 1");
        emit Observed("bls-pairing[e(O,O)]", ok, ret);

        // MAP_FP_TO_G1 / MAP_FP2_TO_G2 of zero: shape only (a point, not O).
        (ok, ret) = ProbeLib.staticCall(BLS_MAP_FP_G1, new bytes(64));
        ProbeLib.expectTrue(ok && ret.length == 128, "H02/bls-map-fp-g1: call failed or bad length");
        ProbeLib.expectTrue(keccak256(ret) != keccak256(new bytes(128)), "H02/bls-map-fp-g1: mapped to O");
        emit Observed("bls-map-fp-to-g1[0]", ok, ret);

        (ok, ret) = ProbeLib.staticCall(BLS_MAP_FP2_G2, new bytes(128));
        ProbeLib.expectTrue(ok && ret.length == 256, "H02/bls-map-fp2-g2: call failed or bad length");
        ProbeLib.expectTrue(keccak256(ret) != keccak256(new bytes(256)), "H02/bls-map-fp2-g2: mapped to O");
        emit Observed("bls-map-fp2-to-g2[0]", ok, ret);
    }

    // 0x100 P256VERIFY (EIP-7951 in Osaka: 6900 gas; RIP-7212 L2s: 3450) - appendix vector; s+1 rejected.
    function p256() public {
        (bool ok, bytes memory ret) = ProbeLib.cappedStaticCall(P256VERIFY, P256_IN, 6900);
        ProbeLib.expectTrue(ok, "H02/p256: failed at gas 6900 (precompile missing?)");
        ProbeLib.expectEqBytes(
            ret,
            hex"0000000000000000000000000000000000000000000000000000000000000001",
            "H02/p256: valid sig not verified"
        );
        (ok,) = ProbeLib.cappedStaticCall(P256VERIFY, P256_IN, 6899);
        ProbeLib.expectTrue(!ok, "H02/p256: succeeded at 6899 (RIP-7212 pricing?)");
        emit Observed("p256verify[valid]", true, ret);

        // s + 1 must fail verification.
        bytes memory bad = abi.encodePacked(
            ProbeLib.slice(P256_IN, 0, 64),
            bytes32(uint256(0x835115c0e0a393388ef444daf5fef46695e252d13fd26903e2b784222bf1f751) + 1),
            ProbeLib.slice(P256_IN, 96, 64)
        );
        (ok, ret) = ProbeLib.staticCall(P256VERIFY, bad);
        ProbeLib.expectTrue(ok, "H02/p256: bad-sig call errored");
        // EIP-7951 / RIP-7212: a failed verification returns EMPTY output.
        ProbeLib.expectTrue(ret.length == 0, "H02/p256: s+1 verified (or non-empty failure output)");
    }
}
