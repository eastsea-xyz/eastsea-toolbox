// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {NativePersonalBase} from "./NativePersonal.t.sol";
import {TokenProbe, ProbeSink} from "../../probes/src/TokenProbe.sol";
import {TestToken, FeeOnTransferToken, FalseReturnToken} from "../../common/test/Tokens.sol";

contract NativePersonalProbeTest is NativePersonalBase {
    TokenProbe private probe;
    TestToken private token;

    function setUp() public {
        _setupPersonal();
        probe = TokenProbe(
            _deploy(abi.encodePacked(type(TokenProbe).creationCode, abi.encode(outsider)), "personal diagnostic")
        );
        token = new TestToken();
        _mintAndApprove(token, address(probe));
    }

    function test_probeAndSinkHaveAtomicPersonalPolicyAndWalletOwner() public view {
        _assertInitialPolicy(probe);
        _assertInitialPolicy(probe.sink());
        assertEq(probe.owner(), owner);
        assertEq(probe.sink().probe(), address(probe));
    }

    function test_probeOrdinaryConstructorPreservesExplicitOwnerAndSinkController() public {
        TokenProbe ordinary = new TokenProbe(outsider);
        assertEq(ordinary.owner(), outsider);
        assertEq(ordinary.instanceMode(), "testnet");
        assertEq(ordinary.sink().instanceMode(), "testnet");
        assertEq(ordinary.sink().probe(), address(ordinary));
    }

    function test_probeAllMovementsRejectUnlistedCaller() public {
        vm.startPrank(outsider);
        _expectDenied(outsider);
        probe.probe(address(token), 1e18);
        _expectDenied(outsider);
        probe.park(address(token), 1e18);
        _expectDenied(outsider);
        probe.sweep(address(token));
        vm.stopPrank();
        assertEq(token.balanceOf(address(probe)), 0);
        assertEq(token.balanceOf(address(probe.sink())), 0);
    }

    function test_probeSinkRejectsExternalControllerAndUnlistedRecipient() public {
        ProbeSink sink = probe.sink();
        vm.prank(outsider);
        _expectDenied(outsider);
        sink.send(address(token), owner, 1);
        vm.prank(outsider);
        _expectDenied(outsider);
        sink.admitPersonalTestToken(address(token));
        vm.prank(owner);
        vm.expectRevert("probe only");
        sink.send(address(token), owner, 1);
        vm.prank(address(probe));
        _expectDenied(outsider);
        sink.send(address(token), outsider, 1);
        vm.prank(address(probe));
        vm.expectRevert(abi.encodeWithSelector(ProbeSink.PersonalProbeUnlistedToken.selector, address(token)));
        sink.send(address(token), owner, 1);
    }

    function test_probeCapSumsTokensHeldByBothProbeAndSink() public {
        FalseReturnToken stranded = new FalseReturnToken();
        _mintAndApprove(stranded, address(probe));
        stranded.setFail(true);
        vm.prank(owner);
        TokenProbe.Report memory r = probe.probe(address(stranded), 3e18);
        assertEq(r.refunded, 0);
        assertEq(stranded.balanceOf(address(probe)), 3e18);
        vm.prank(owner);
        probe.park(address(token), 2e18);
        assertEq(token.balanceOf(address(probe.sink())), 2e18);
        vm.prank(owner);
        _expectCap(6e18, TOKEN_CAP);
        probe.park(address(token), 1e18);
        assertEq(token.balanceOf(address(probe.sink())), 2e18);
    }

    function test_probeParkingCapIncludesMultipleAssetsAndExistingGifts() public {
        token.mint(address(probe), 1e18);
        vm.prank(owner);
        probe.park(address(token), 4e18);
        TestToken other = new TestToken();
        _mintAndApprove(other, address(probe));
        vm.prank(owner);
        _expectCap(6e18, TOKEN_CAP);
        probe.park(address(other), 1e18);
        assertEq(other.balanceOf(address(probe.sink())), 0);
    }

    function test_probeRoundTripAndRecoveryLeaveUnsolicitedDeposits() public {
        token.mint(address(probe), 1e18);
        token.mint(address(probe.sink()), 1e18);
        uint256 before = token.balanceOf(owner);
        vm.prank(owner);
        TokenProbe.Report memory r = probe.probe(address(token), 1e18);
        assertTrue(r.exact);
        assertEq(r.refunded, 1e18);
        assertEq(token.balanceOf(owner), before);
        assertEq(token.balanceOf(address(probe)), 1e18);
        assertEq(token.balanceOf(address(probe.sink())), 1e18);
        vm.prank(owner);
        probe.sweep(address(token));
        assertEq(token.balanceOf(owner), before);
        assertEq(token.balanceOf(address(probe)), 1e18);
        assertEq(token.balanceOf(address(probe.sink())), 1e18);
    }

    function test_probeSweepRejectsUnadmittedTokenRatherThanTakingDeposits() public {
        token.mint(address(probe), 1e18);
        token.mint(address(probe.sink()), 1e18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TokenProbe.PersonalProbeUnlistedToken.selector, address(token)));
        probe.sweep(address(token));
        assertEq(token.balanceOf(address(probe)), 1e18);
        assertEq(token.balanceOf(address(probe.sink())), 1e18);
    }

    function test_probeRecoveryWorksAfterUnsolicitedExcess() public {
        FalseReturnToken stranded = new FalseReturnToken();
        _mintAndApprove(stranded, address(probe));
        stranded.setFail(true);
        vm.prank(owner);
        probe.probe(address(stranded), 1e18);
        stranded.mint(address(probe), 10e18);
        stranded.setFail(false);
        uint256 before = stranded.balanceOf(owner);
        vm.prank(owner);
        assertEq(probe.sweep(address(stranded)), 1e18);
        assertEq(stranded.balanceOf(owner), before + 1e18);
        assertEq(stranded.balanceOf(address(probe)), 10e18);
    }

    function test_probeNativeCapCoversBothAddressesWithoutBlockingRecovery() public {
        vm.prank(owner);
        probe.park(address(token), 1e18);
        address sink = address(probe.sink());
        vm.deal(address(probe), NATIVE_CAP / 2);
        vm.deal(sink, NATIVE_CAP / 2 + 1);
        vm.prank(owner);
        _expectCap(NATIVE_CAP + 1, NATIVE_CAP);
        probe.park(address(token), 1e18);
        uint256 before = token.balanceOf(owner);
        vm.prank(owner);
        probe.sweep(address(token));
        assertEq(token.balanceOf(owner), before + 1e18);
        assertEq(token.balanceOf(sink), 0);
    }

    function test_probeFeeOnTransferStillReportsObservedDeltas() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        _mintAndApprove(feeToken, address(probe));
        vm.prank(owner);
        TokenProbe.Report memory r = probe.probe(address(feeToken), 1e18);
        assertFalse(r.exact);
        assertEq(r.pull.fromDebit, 1e18);
        assertEq(r.pull.toCredit, 99e16);
        assertEq(feeToken.balanceOf(address(probe)), 0);
        assertEq(feeToken.balanceOf(address(probe.sink())), 0);
    }

    function test_probeRejectsZeroFundingButCanReportCodelessToken() public {
        vm.prank(owner);
        vm.expectRevert(TokenProbe.PersonalProbeZeroAmount.selector);
        probe.park(address(token), 0);
        vm.prank(owner);
        vm.expectRevert(TokenProbe.PersonalProbeZeroAmount.selector);
        probe.probe(address(token), 0);
        vm.prank(owner);
        TokenProbe.Report memory r = probe.probe(address(0xbeef), 1);
        assertEq(r.codeSize, 0);
        assertFalse(r.exact);
    }
}
