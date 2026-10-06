// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ClaimCampaigns} from "../src/ClaimCampaigns.sol";
import {INativeBrake} from "../../common/src/INativeBrake.sol";
import {ExactToken} from "../../common/src/ExactToken.sol";
import {TransientLock} from "../../common/src/TransientLock.sol";
import {TestToken, FeeOnTransferToken, BlockingToken, CallbackToken} from "../../common/test/Tokens.sol";
import {SlotDiff} from "../../common/test/SlotDiff.sol";
import {MerkleBuilder} from "./MerkleBuilder.sol";

abstract contract ClaimsBase is Test {
    TestToken token;
    ClaimCampaigns claims;
    address issuer = makeAddr("issuer");
    address refundTo = makeAddr("refundTo");
    address relayer = makeAddr("relayer");

    address[] accts;
    uint128[] amts;
    bytes32[] leaves;

    function _deploy(TestToken t) internal {
        token = t;
        claims = new ClaimCampaigns(address(t), keccak256("brake-doc"));
        t.mint(issuer, type(uint128).max);
        vm.prank(issuer);
        t.approve(address(claims), type(uint256).max);
    }

    function _alloc(uint256 n, uint256 seed) internal {
        delete accts;
        delete amts;
        for (uint256 i; i < n; i++) {
            accts.push(address(uint160(uint256(keccak256(abi.encode(seed, i, "a"))))));
            amts.push(uint128(1 + uint256(keccak256(abi.encode(seed, i))) % 1e21));
        }
    }

    function _leaves(uint256 id) internal returns (bytes32[] memory) {
        delete leaves;
        for (uint256 i; i < accts.length; i++) {
            leaves.push(claims.leafHash(id, i, accts[i], amts[i]));
        }
        return leaves;
    }

    function _sum() internal view returns (uint128 s) {
        for (uint256 i; i < amts.length; i++) {
            s += amts[i];
        }
    }

    function _create(uint128 funding, uint64 deadline) internal returns (uint256 id) {
        id = claims.nextCampaign();
        bytes32 root = MerkleBuilder.root(_leaves(id));
        vm.prank(issuer);
        claims.create(id, root, uint32(accts.length), refundTo, deadline, funding, bytes32(uint256(1)));
    }

    function _claim(uint256 id, uint256 i) internal {
        bytes32[] memory p = MerkleBuilder.proof(_leaves(id), i);
        vm.prank(relayer);
        claims.claim(id, i, accts[i], amts[i], p);
    }
}

contract ClaimCampaignsCreateTest is ClaimsBase {
    function setUp() public {
        _deploy(new TestToken());
        _alloc(5, 1);
    }

    // ------------------------------------------------------------ creation

    function test_runtimeWithinEip170() public view {
        assertLe(address(claims).code.length, 24576);
    }

    function test_constructor_rejectsCodelessToken() public {
        vm.expectRevert(ClaimCampaigns.TokenHasNoCode.selector);
        new ClaimCampaigns(address(0xdead), bytes32(0));
    }

    function test_create_storesThreeWordsAndPullsExactly() public {
        uint256 id = claims.nextCampaign();
        bytes32 root = MerkleBuilder.root(_leaves(id));
        SlotDiff.start();
        vm.prank(issuer);
        claims.create(id, root, 5, refundTo, 100, 1e18, bytes32(0));
        SlotDiff.Count memory c = SlotDiff.stop(address(claims));
        assertEq(c.occupied, 3, "C0-C2 only; M0 already occupied");
        assertEq(token.balanceOf(address(claims)), 1e18);
        assertEq(claims.outstanding(), 1e18);
        assertEq(claims.nextCampaign(), id + 1);
        ClaimCampaigns.Campaign memory k = claims.campaign(id);
        assertEq(k.root, root);
        assertEq(k.remaining, 1e18);
        assertEq(k.initiallyFunded, 1e18);
        assertEq(k.refundRecipient, refundTo);
        assertEq(k.deadline, 100);
        assertEq(k.leafCount, 5);
    }

    function test_create_expectedIdMismatchMovesNothing() public {
        _create(1e18, 100);
        uint256 bal = token.balanceOf(issuer);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.UnexpectedCampaignId.selector, 1, 2));
        claims.create(1, bytes32(uint256(1)), 5, refundTo, 100, 1e18, bytes32(0));
        assertEq(token.balanceOf(issuer), bal);
    }

    function test_create_validation() public {
        vm.startPrank(issuer);
        vm.expectRevert(ClaimCampaigns.ZeroRoot.selector);
        claims.create(1, 0, 5, refundTo, 100, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.BadLeafCount.selector, 0));
        claims.create(1, bytes32(uint256(1)), 0, refundTo, 100, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.BadLeafCount.selector, 65537));
        claims.create(1, bytes32(uint256(1)), 65537, refundTo, 100, 1, 0);
        vm.expectRevert(ClaimCampaigns.BadRefundRecipient.selector);
        claims.create(1, bytes32(uint256(1)), 5, address(0), 100, 1, 0);
        vm.expectRevert(ClaimCampaigns.BadRefundRecipient.selector);
        claims.create(1, bytes32(uint256(1)), 5, address(claims), 100, 1, 0);
        vm.expectRevert(ClaimCampaigns.BadDeadline.selector);
        claims.create(1, bytes32(uint256(1)), 5, refundTo, uint64(block.number), 1, 0);
        vm.expectRevert(ClaimCampaigns.ZeroAmount.selector);
        claims.create(1, bytes32(uint256(1)), 5, refundTo, 100, 0, 0);
        claims.create(1, bytes32(uint256(1)), 65536, refundTo, 100, type(uint128).max - 1, 0);
        vm.expectRevert(ClaimCampaigns.OutstandingOverflow.selector);
        claims.create(2, bytes32(uint256(1)), 5, refundTo, 100, 2, 0);
        vm.stopPrank();
    }

    function test_create_rejectsFeeOnTransferAsset() public {
        _deploy(new FeeOnTransferToken());
        uint256 id = claims.nextCampaign();
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ExactToken.NotExactTransfer.selector, 1000, 990));
        claims.create(id, bytes32(uint256(1)), 5, refundTo, 100, 1000, 0);
        assertEq(claims.outstanding(), 0);
        assertEq(claims.nextCampaign(), 1);
    }
}

contract ClaimCampaignsClaimTest is ClaimsBase {
    function setUp() public {
        _deploy(new TestToken());
        _alloc(5, 1);
    }

    // --------------------------------------------------------------- claims

    function test_claim_relayerPaysFixedAccount() public {
        uint256 id = _create(_sum(), 100);
        _claim(id, 2);
        assertEq(token.balanceOf(accts[2]), amts[2]);
        assertEq(token.balanceOf(relayer), 0);
        assertTrue(claims.isClaimed(id, 2));
        assertEq(claims.outstanding(), _sum() - amts[2]);
    }

    function test_claim_replayRejected() public {
        uint256 id = _create(_sum(), 100);
        _claim(id, 0);
        bytes32[] memory p = MerkleBuilder.proof(_leaves(id), 0);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.AlreadyClaimed.selector, id, 0));
        claims.claim(id, 0, accts[0], amts[0], p);
    }

    function test_claim_cannotRedirectOrInflate() public {
        uint256 id = _create(_sum(), 100);
        bytes32[] memory p = MerkleBuilder.proof(_leaves(id), 1);
        vm.expectRevert(ClaimCampaigns.InvalidProof.selector);
        claims.claim(id, 1, relayer, amts[1], p);
        vm.expectRevert(ClaimCampaigns.InvalidProof.selector);
        claims.claim(id, 1, accts[1], amts[1] + 1, p);
        vm.expectRevert(ClaimCampaigns.InvalidProof.selector);
        claims.claim(id, 0, accts[1], amts[1], p); // right leaf, wrong position
    }

    function test_claim_crossCampaignAndCrossInstanceReplay() public {
        uint256 a = _create(_sum(), 100);
        uint256 b = _create(_sum(), 100);
        bytes32[] memory pa = MerkleBuilder.proof(_leaves(a), 3);
        vm.expectRevert(ClaimCampaigns.InvalidProof.selector);
        claims.claim(b, 3, accts[3], amts[3], pa);

        ClaimCampaigns other = new ClaimCampaigns(address(token), 0);
        vm.prank(issuer);
        token.approve(address(other), type(uint256).max);
        bytes32 rootA = claims.campaign(a).root;
        uint128 sum = _sum();
        vm.prank(issuer);
        other.create(1, rootA, 5, refundTo, 100, sum, 0);
        vm.expectRevert(ClaimCampaigns.InvalidProof.selector);
        other.claim(1, 3, accts[3], amts[3], pa);
    }

    function test_claim_proofShapeChecks() public {
        uint256 id = _create(_sum(), 100);
        bytes32[] memory p = MerkleBuilder.proof(_leaves(id), 1);
        bytes32[] memory longer = new bytes32[](p.length + 1);
        for (uint256 i; i < p.length; i++) {
            longer[i] = p[i];
        }
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.BadProofLength.selector, 4, 3));
        claims.claim(id, 1, accts[1], amts[1], longer);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.IndexOutOfRange.selector, 5, 5));
        claims.claim(id, 5, accts[1], amts[1], p);
        vm.expectRevert(ClaimCampaigns.ZeroAmount.selector);
        claims.claim(id, 1, accts[1], 0, p);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.CampaignNotLive.selector, 99));
        claims.claim(99, 1, accts[1], amts[1], p);
    }

    function test_claim_singleLeafCampaignHasEmptyProof() public {
        _alloc(1, 7);
        uint256 id = _create(amts[0], 100);
        claims.claim(id, 0, accts[0], amts[0], new bytes32[](0));
        assertEq(token.balanceOf(accts[0]), amts[0]);
    }

    function test_claim_deadlineInclusive() public {
        uint256 id = _create(_sum(), 100);
        vm.roll(100);
        _claim(id, 0);
        vm.roll(101);
        bytes32[] memory p = MerkleBuilder.proof(_leaves(id), 1);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.ClaimWindowClosed.selector, id, 100));
        claims.claim(id, 1, accts[1], amts[1], p);
    }

    function test_claim_underfundedRootRacesForBacking() public {
        uint256 id = _create(amts[0] + amts[1], 100);
        _claim(id, 0);
        _claim(id, 1);
        bytes32[] memory p = MerkleBuilder.proof(_leaves(id), 2);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.InsufficientBacking.selector, 0, amts[2]));
        claims.claim(id, 2, accts[2], amts[2], p);
    }

    function test_claim_slotOccupancyPerBitmapWord() public {
        _alloc(300, 3);
        uint256 id = _create(_sum(), 1000);
        bytes32[] memory l = _leaves(id);
        uint256[3] memory idx = [uint256(0), 1, 256];
        uint256[3] memory want = [uint256(1), 0, 1];
        for (uint256 k; k < 3; k++) {
            bytes32[] memory p = MerkleBuilder.proof(l, idx[k]);
            SlotDiff.start();
            claims.claim(id, idx[k], accts[idx[k]], amts[idx[k]], p);
            assertEq(SlotDiff.stop(address(claims)).occupied, want[k]);
        }
    }

    function test_claim_blockedRecipientKeepsRight() public {
        BlockingToken bt = new BlockingToken();
        _deploy(bt);
        uint256 id = _create(_sum(), 100);
        bt.setBlocked(accts[0], true);
        bytes32[] memory p = MerkleBuilder.proof(_leaves(id), 0);
        vm.expectRevert();
        claims.claim(id, 0, accts[0], amts[0], p);
        assertFalse(claims.isClaimed(id, 0));
        assertEq(claims.outstanding(), _sum());
        bt.setBlocked(accts[0], false);
        claims.claim(id, 0, accts[0], amts[0], p);
        assertEq(bt.balanceOf(accts[0]), amts[0]);
    }
}

contract ClaimCampaignsExitTest is ClaimsBase {
    function setUp() public {
        _deploy(new TestToken());
        _alloc(5, 1);
    }

    // -------------------------------------------------------- close / prune

    function test_close_onlyAfterDeadlineOrEmpty() public {
        uint256 id = _create(_sum(), 100);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.NotClosable.selector, id));
        claims.close(id);
        _claim(id, 0);
        vm.roll(101);
        SlotDiff.start();
        claims.close(id);
        SlotDiff.Count memory c = SlotDiff.stop(address(claims));
        assertEq(c.cleared, 3);
        assertEq(token.balanceOf(refundTo), _sum() - amts[0]);
        assertEq(claims.outstanding(), 0);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.CampaignNotLive.selector, id));
        claims.close(id);
        bytes32[] memory p = MerkleBuilder.proof(_leaves(id), 1);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.CampaignNotLive.selector, id));
        claims.claim(id, 1, accts[1], amts[1], p);
    }

    function test_close_earlyWhenFullyPaid() public {
        uint256 id = _create(_sum(), 100);
        for (uint256 i; i < 5; i++) {
            _claim(id, i);
        }
        claims.close(id);
        assertEq(token.balanceOf(refundTo), 0);
        assertEq(token.balanceOf(address(claims)), 0);
    }

    function test_close_failedRefundKeepsCampaign() public {
        BlockingToken bt = new BlockingToken();
        _deploy(bt);
        uint256 id = _create(_sum(), 100);
        vm.roll(101);
        bt.setBlocked(refundTo, true);
        vm.expectRevert();
        claims.close(id);
        assertEq(claims.campaign(id).remaining, _sum());
        bt.setBlocked(refundTo, false);
        claims.close(id);
        assertEq(bt.balanceOf(refundTo), _sum());
    }

    function test_prune_onlyClosedAndNoResurrection() public {
        _alloc(600, 9);
        uint256 id = _create(_sum(), 100);
        _claim(id, 0);
        _claim(id, 300);
        _claim(id, 599);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.NotClosed.selector, id));
        claims.prune(id, 0, 3);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.NotClosed.selector, 7));
        claims.prune(7, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.BadPruneCount.selector, 9));
        claims.prune(id, 0, 9);
        vm.roll(101);
        claims.close(id);
        SlotDiff.start();
        claims.prune(id, 0, 3);
        assertEq(SlotDiff.stop(address(claims)).cleared, 3);
        assertFalse(claims.isClaimed(id, 300));
        // An old proof cannot come back: the id is never reissued.
        bytes32[] memory p = MerkleBuilder.proof(_leaves(id), 300);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.CampaignNotLive.selector, id));
        claims.claim(id, 300, accts[300], amts[300], p);
        bytes32 oldLeaf = claims.leafHash(id, 0, accts[0], amts[0]);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.UnexpectedCampaignId.selector, id, id + 1));
        claims.create(id, oldLeaf, 1, refundTo, 200, 1, 0);
    }

    // ---------------------------------------------------------------- brake

    function test_brake_deficitClosesEntryKeepsBackedExits() public {
        uint256 a = _create(_sum(), 100);
        (uint8 s, address g,) = claims.brakeState();
        assertEq(s, 0);
        assertEq(g, address(0));
        vm.expectRevert(INativeBrake.BrakePredicateFalse.selector);
        claims.tripBrake();

        token.burnFrom(address(claims), 1); // issuer seizure / rebase-down
        assertEq(claims.brakePredicate(), 2);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.EntryBraked.selector, 2, 0));
        claims.create(2, bytes32(uint256(1)), 1, refundTo, 100, 1, 0);
        vm.roll(5);
        claims.tripBrake();

        // While short, a payout would consume another right's backing.
        bytes32[] memory p = MerkleBuilder.proof(_leaves(a), 0);
        vm.expectRevert();
        claims.claim(a, 0, accts[0], amts[0], p);

        // Anyone may restore backing; exits reopen, entry stays latched.
        token.mint(address(claims), 1);
        claims.claim(a, 0, accts[0], amts[0], p);
        uint64 since;
        (s,, since) = claims.brakeState();
        assertEq(s, 1);
        assertEq(since, 5);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.EntryBraked.selector, 0, 5));
        claims.create(2, bytes32(uint256(1)), 1, refundTo, 100, 1, 0);
        vm.roll(101);
        claims.close(a);
    }

    function test_brake_tokenCodeChange() public {
        vm.etch(address(token), address(new FeeOnTransferToken()).code);
        assertEq(claims.brakePredicate() & 1, 1);
        claims.tripBrake();
        (uint8 s,,) = claims.brakeState();
        assertEq(s, 1);
    }

    function test_brake_idExhaustion() public {
        // M0 is slot 0: nextCampaign (low 64 bits) | brakeSince | outstanding.
        vm.store(address(claims), bytes32(0), bytes32(uint256(type(uint64).max)));
        assertEq(claims.brakePredicate(), 4);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(INativeBrake.EntryBraked.selector, 4, 0));
        claims.create(type(uint64).max, bytes32(uint256(1)), 1, refundTo, 100, 1, 0);
    }

    // --------------------------------------------------------- reentrancy

    function test_reentrancy_fromRecipientCallback() public {
        CallbackToken ct = new CallbackToken();
        _deploy(ct);
        Reenterer r = new Reenterer();
        accts[0] = address(r);
        uint256 id = _create(_sum(), 100);
        bytes32[] memory p0 = MerkleBuilder.proof(_leaves(id), 0);
        bytes32[] memory p1 = MerkleBuilder.proof(_leaves(id), 1);
        r.arm(claims, id, 1, accts[1], amts[1], p1);
        claims.claim(id, 0, address(r), amts[0], p0);
        assertTrue(r.tried());
        assertEq(r.err(), TransientLock.Reentrancy.selector);
        assertFalse(claims.isClaimed(id, 1));
    }
}

contract Reenterer {
    ClaimCampaigns c;
    uint256 id;
    uint256 index;
    address acct;
    uint128 amt;
    bytes32[] proof;
    bool public tried;
    bytes4 public err;

    function arm(ClaimCampaigns c_, uint256 id_, uint256 i, address a, uint128 m, bytes32[] memory p) external {
        (c, id, index, acct, amt, proof) = (c_, id_, i, a, m, p);
    }

    function onTokenTransfer(address, uint256) external {
        if (tried) return;
        tried = true;
        try c.claim(id, index, acct, amt, proof) {}
        catch (bytes memory e) {
            err = bytes4(e);
        }
    }
}

/// @dev No setUp: the fixture binds the instance address, so this contract
///      must deploy the token at nonce 1 and the instance at nonce 2.
contract ClaimsExportTest is Test {
    using stdJson for string;

    address refundTo = makeAddr("refundTo");

    // ------------------------------------------------- export compatibility

    function test_exportedDataset_matchesContract() public {
        // Fixture produced by tools/claims_tree.py for chain 31337 and the
        // instance this test deploys second from its own address.
        vm.chainId(31337);
        TestToken t = new TestToken(); // nonce 1
        ClaimCampaigns c = new ClaimCampaigns(address(t), 0); // nonce 2
        string memory json = vm.readFile("claims/test/fixtures/campaign1.json");
        assertEq(json.readAddress(".instance"), address(c), "fixture instance");
        bytes32 root = json.readBytes32(".root");
        uint256 n = json.readUint(".leafCount");
        t.mint(address(this), 3508);
        t.approve(address(c), 3508);
        // The root does not prove the sum: this dataset totals > 2^128 and is
        // deliberately funded only for the four small leaves.
        c.create(1, root, uint32(n), refundTo, 100, 3508, json.readBytes32(".dataHash"));
        for (uint256 i; i < n; i++) {
            string memory k = string.concat(".leaves[", vm.toString(i), "]");
            address acct = json.readAddress(string.concat(k, ".account"));
            uint256 amt = json.readUint(string.concat(k, ".amount"));
            bytes32[] memory p = json.readBytes32Array(string.concat(k, ".proof"));
            assertEq(json.readBytes32(string.concat(k, ".leaf")), c.leafHash(1, i, acct, amt));
            assertTrue(c.verify(1, i, acct, amt, p));
            if (i == 3) {
                vm.expectRevert(abi.encodeWithSelector(ClaimCampaigns.InsufficientBacking.selector, 7, amt));
                c.claim(1, i, acct, uint128(amt), p);
            } else {
                c.claim(1, i, acct, uint128(amt), p);
            }
        }
        assertEq(t.balanceOf(address(0xb0b)), 2507);
    }
}
