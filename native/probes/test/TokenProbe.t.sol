// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {TokenProbe} from "../src/TokenProbe.sol";
import {ExactToken} from "../../common/src/ExactToken.sol";
import {
    TestToken,
    FeeOnTransferToken,
    LyingToken,
    BlockingToken,
    FalseReturnToken,
    CallbackToken
} from "../../common/test/Tokens.sol";
import {NoBoolToken, RebasingToken, PausableToken} from "./ProbeTokens.sol";

/// @dev Pull-then-push through the shared exact-transfer library, so the
///      probe's verdict can be checked against what native templates accept.
contract ExactRoundTrip {
    function run(address token, address from, uint256 amount) external {
        ExactToken.pullExact(token, from, amount);
        ExactToken.pushExact(token, from, amount);
    }
}

/// @notice C0 reproducible token probes. Every token here is a TEST-ONLY
///         mock of a behaviour seen in the wild; the probe is the reusable
///         part, pointed at real assets on the executor (G8).
contract TokenProbeTest is Test {
    address owner = makeAddr("owner");
    TokenProbe p;
    ExactRoundTrip rt;
    uint256 constant AMT = 1_000_000;

    function setUp() public {
        p = new TokenProbe(owner);
        rt = new ExactRoundTrip();
    }

    function _fund(address token) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", owner, AMT * 10));
        require(ok, "mint");
        vm.startPrank(owner);
        (ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(p), type(uint256).max));
        (ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(rt), type(uint256).max));
        vm.stopPrank();
    }

    function _probe(address token) internal returns (TokenProbe.Report memory r) {
        vm.prank(owner);
        r = p.probe(token, AMT);
    }

    /// @dev The probe's `exact` verdict must equal ExactToken's acceptance.
    function _agreesWithExactToken(address token, bool exact) internal {
        vm.prank(owner);
        (bool ok,) = address(rt).call(abi.encodeCall(ExactRoundTrip.run, (token, owner, AMT)));
        assertEq(ok, exact, "probe verdict == ExactToken acceptance");
    }

    function test_plainToken_isExact_andFullyReturned() public {
        TestToken t = new TestToken();
        _fund(address(t));
        TokenProbe.Report memory r = _probe(address(t));
        assertTrue(r.exact);
        assertEq(r.pull.shape, p.SHAPE_TRUE());
        assertEq(r.pull.fromDebit, AMT);
        assertEq(r.back.toCredit, AMT);
        assertEq(r.refunded, AMT);
        assertEq(t.balanceOf(owner), AMT * 10, "probe keeps nothing");
        assertEq(r.codeHash, address(t).codehash);
        _agreesWithExactToken(address(t), true);
    }

    function test_noBoolToken_isExact_withEmptyReturn() public {
        NoBoolToken t = new NoBoolToken();
        _fund(address(t));
        TokenProbe.Report memory r = _probe(address(t));
        assertTrue(r.exact, "empty return + exact deltas is accepted");
        assertEq(r.pull.shape, p.SHAPE_EMPTY());
        assertEq(r.push.shape, p.SHAPE_EMPTY());
        assertEq(t.balanceOf(owner), AMT * 10);
        _agreesWithExactToken(address(t), true);
    }

    function test_feeOnTransfer_isNotExact_andShowsTheFee() public {
        FeeOnTransferToken t = new FeeOnTransferToken();
        _fund(address(t));
        TokenProbe.Report memory r = _probe(address(t));
        assertFalse(r.exact);
        assertEq(r.pull.fromDebit, AMT);
        assertEq(r.pull.toCredit, AMT - AMT / 100, "1% lost on the pull leg");
        _agreesWithExactToken(address(t), false);
    }

    function test_noopTrue_isNotExact() public {
        LyingToken t = new LyingToken();
        _fund(address(t));
        t.setLying(true);
        TokenProbe.Report memory r = _probe(address(t));
        assertFalse(r.exact);
        assertEq(r.pull.shape, p.SHAPE_TRUE(), "says true ...");
        assertEq(r.pull.toCredit, 0, "... moves nothing");
        _agreesWithExactToken(address(t), false);
    }

    function test_falseReturn_isNotExact_andTokensComeBack() public {
        FalseReturnToken t = new FalseReturnToken();
        _fund(address(t));
        t.setFail(true); // `transfer` returns false; transferFrom still works
        TokenProbe.Report memory r = _probe(address(t));
        assertFalse(r.exact);
        assertEq(r.pull.shape, p.SHAPE_TRUE());
        assertEq(r.push.shape, p.SHAPE_FALSE_OR_OTHER());
        assertEq(r.refunded, 0, "refund uses transfer too, which returns false");
        _agreesWithExactToken(address(t), false);
        t.setFail(false);
        vm.prank(owner);
        assertEq(p.sweep(address(t)), AMT, "owner recovers once the token works");
    }

    function test_blocklistedSink_showsRevertedLeg_atThisHeightOnly() public {
        BlockingToken t = new BlockingToken();
        _fund(address(t));
        t.setBlocked(address(p.sink()), true);
        TokenProbe.Report memory r = _probe(address(t));
        assertFalse(r.exact);
        assertEq(r.pull.shape, p.SHAPE_TRUE());
        assertEq(r.push.shape, p.SHAPE_REVERTED());
        assertEq(r.refunded, AMT, "the pulled amount still comes back");
        // The same token probes clean once the issuer lifts the block: a
        // clean report never proves the issuer cannot freeze later.
        t.setBlocked(address(p.sink()), false);
        assertTrue(_probe(address(t)).exact);
    }

    function test_pausedToken_revertsFirstLeg() public {
        PausableToken t = new PausableToken();
        _fund(address(t));
        t.setPaused(true);
        TokenProbe.Report memory r = _probe(address(t));
        assertFalse(r.exact);
        assertEq(r.pull.shape, p.SHAPE_REVERTED());
        assertEq(r.refunded, 0);
        assertEq(t.balanceOf(owner), AMT * 10);
    }

    function test_codelessAddress_isReported() public {
        vm.prank(owner);
        TokenProbe.Report memory r = p.probe(address(0xBEEF), AMT);
        assertFalse(r.exact);
        assertEq(r.codeSize, 0);
        assertEq(r.pull.shape, p.SHAPE_REVERTED());
    }

    function test_callbackToken_probesExact_butCallbacksAreSeparateRisk() public {
        CallbackToken t = new CallbackToken();
        _fund(address(t));
        // Callbacks do not change amounts, so the transfer probe is clean.
        // Reentrancy through them is checked per template (pool tests).
        assertTrue(_probe(address(t)).exact);
    }

    /// @notice Rebasing is invisible inside one transaction ...
    function test_rebasing_singleTxProbeIsClean_parkRevealsRebase() public {
        RebasingToken t = new RebasingToken();
        _fund(address(t));
        assertTrue(_probe(address(t)).exact, "exact at this height");
        // ... so park a balance and read it again at a later height.
        vm.prank(owner);
        assertEq(p.park(address(t), AMT), AMT);
        vm.roll(block.number + 100);
        t.rebase(0.9e18); // negative rebase / demurrage / seizure
        assertEq(p.parked(address(t)), AMT * 9 / 10, "balance fell with no transfer");
        t.rebase(1.2e18);
        assertEq(p.parked(address(t)), AMT * 12 / 10, "positive rebase");
        vm.prank(owner);
        p.sweep(address(t));
        assertEq(p.parked(address(t)), 0);
    }

    function test_onlyOwner() public {
        TestToken t = new TestToken();
        vm.expectRevert(TokenProbe.OnlyOwner.selector);
        p.probe(address(t), 1);
        vm.expectRevert(TokenProbe.OnlyOwner.selector);
        p.park(address(t), 1);
        vm.expectRevert(TokenProbe.OnlyOwner.selector);
        p.sweep(address(t));
    }

    /// @notice Upgradeable-token risk: a code-hash change is visible to the
    ///         probe (and trips pool brakes), but an upgrade hidden behind an
    ///         unchanged proxy facade is not.
    function test_codeHashChange_isVisible() public {
        TestToken t = new TestToken();
        _fund(address(t));
        bytes32 h0 = _probe(address(t)).codeHash;
        vm.etch(address(t), address(new FeeOnTransferToken()).code);
        TokenProbe.Report memory r = _probe(address(t));
        assertTrue(r.codeHash != h0);
        assertFalse(r.exact, "same address, now charges a fee");
    }

    function testFuzz_feeTokenNeverProbesExact(uint256 amount) public {
        amount = bound(amount, 100, AMT * 10);
        FeeOnTransferToken t = new FeeOnTransferToken();
        _fund(address(t));
        vm.prank(owner);
        assertFalse(p.probe(address(t), amount).exact);
    }

    function testFuzz_plainTokenAlwaysProbesExact_andReturnsAll(uint256 amount) public {
        amount = bound(amount, 1, AMT * 10);
        TestToken t = new TestToken();
        _fund(address(t));
        vm.prank(owner);
        TokenProbe.Report memory r = p.probe(address(t), amount);
        assertTrue(r.exact);
        assertEq(t.balanceOf(owner), AMT * 10);
    }
}
