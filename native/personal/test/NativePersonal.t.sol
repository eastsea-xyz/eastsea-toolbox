// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {PersonalTest} from "toolbox-personal/PersonalTest.sol";
import {PersonalTestDeployer} from "toolbox-personal/PersonalTestDeployer.sol";
import {ClaimCampaigns} from "../../claims/src/ClaimCampaigns.sol";
import {GrantLedger} from "../../streams/src/GrantLedger.sol";
import {EscrowBook} from "../../escrow/src/EscrowBook.sol";
import {SwapPool} from "../../swap-pool/src/SwapPool.sol";
import {TestToken} from "../../common/test/Tokens.sol";

abstract contract NativePersonalBase is Test {
    uint256 internal constant NATIVE_CAP = 1e15;
    uint256 internal constant TOKEN_CAP = 5e18;
    uint64 internal constant FAR = type(uint64).max;
    address internal owner = makeAddr("personal wallet");
    address internal ownAccount = makeAddr("another account of the personal wallet");
    address internal outsider = makeAddr("another person's wallet");
    PersonalTestDeployer internal factory;

    function _setupPersonal() internal {
        vm.roll(100);
        vm.warp(1_000);
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        factory = new PersonalTestDeployer(NATIVE_CAP, TOKEN_CAP);
    }

    function _deploy(bytes memory creationCode, bytes32 salt) internal returns (address instance) {
        vm.prank(owner);
        return factory.deploy(creationCode, salt);
    }

    function _allow(PersonalTest instance, address account) internal {
        vm.prank(owner);
        instance.setPersonalTestAccount(account, true);
    }

    function _mintAndApprove(TestToken token, address instance) internal {
        address[3] memory accounts = [owner, ownAccount, outsider];
        for (uint256 i; i < accounts.length; ++i) {
            token.mint(accounts[i], 100e18);
            vm.prank(accounts[i]);
            token.approve(instance, type(uint256).max);
        }
    }

    function _expectDenied(address account) internal {
        vm.expectRevert(abi.encodeWithSelector(PersonalTest.PersonalTestAccountDenied.selector, account));
    }

    function _expectCap(uint256 held, uint256 cap) internal {
        vm.expectRevert(abi.encodeWithSelector(PersonalTest.PersonalTestValueCap.selector, held, cap));
    }

    function _assertInitialPolicy(PersonalTest instance) internal view {
        assertEq(instance.instanceMode(), "personal-test");
        assertEq(instance.personalTestOwner(), owner);
        assertEq(instance.personalTestNativeCap(), NATIVE_CAP);
        assertEq(instance.personalTestTokenCap(), TOKEN_CAP);
        assertTrue(instance.personalTestEnabled());
        assertTrue(instance.personalTestAllowed(owner));
        assertFalse(instance.personalTestAllowed(ownAccount));
        assertFalse(instance.personalTestAllowed(outsider));
        assertFalse(instance.personalTestAllowed(address(factory)));
        assertTrue(factory.isPersonalTestInstance(address(instance)));
    }
}

contract NativePersonalClaimsTest is NativePersonalBase {
    TestToken private token;
    ClaimCampaigns private claims;

    function setUp() public {
        _setupPersonal();
        token = new TestToken();
        claims = ClaimCampaigns(
            _deploy(
                abi.encodePacked(type(ClaimCampaigns).creationCode, abi.encode(address(token), bytes32(0))), "claims"
            )
        );
        _mintAndApprove(token, address(claims));
    }

    function _create(address recipient, uint128 amount) private returns (uint256 id) {
        id = claims.nextCampaign();
        bytes32 root = claims.leafHash(id, 0, recipient, amount);
        vm.prank(owner);
        claims.create(id, root, 1, owner, uint64(block.number + 20), amount, bytes32(0));
    }

    function test_claimsConstructorAtomicallySetsPersonalPolicy() public view {
        _assertInitialPolicy(claims);
    }

    function test_claimsAllMutationsRejectUnlistedCaller() public {
        vm.startPrank(outsider);
        _expectDenied(outsider);
        claims.create(1, bytes32(uint256(1)), 1, owner, 120, 1e18, bytes32(0));
        _expectDenied(outsider);
        claims.claim(1, 0, owner, 1e18, new bytes32[](0));
        _expectDenied(outsider);
        claims.close(1);
        _expectDenied(outsider);
        claims.prune(1, 0, 1);
        _expectDenied(outsider);
        claims.tripBrake();
        vm.stopPrank();
        assertEq(token.balanceOf(address(claims)), 0);
    }

    function test_claimsRejectUnlistedRefundAndMerkleBeneficiary() public {
        vm.prank(owner);
        _expectDenied(outsider);
        claims.create(1, bytes32(uint256(1)), 1, outsider, 120, 1e18, bytes32(0));
        uint256 id = _create(outsider, 1e18);
        vm.prank(owner);
        _expectDenied(outsider);
        claims.claim(id, 0, outsider, 1e18, new bytes32[](0));
        assertEq(claims.outstanding(), 1e18);
        assertFalse(claims.isClaimed(id, 0));
    }

    function test_claimsAddedOwnAccountCanReceiveWithoutFees() public {
        _allow(claims, ownAccount);
        uint256 id = _create(ownAccount, 1e18);
        uint256 before = token.balanceOf(ownAccount);
        vm.prank(ownAccount);
        claims.claim(id, 0, ownAccount, 1e18, new bytes32[](0));
        assertEq(token.balanceOf(ownAccount), before + 1e18);
        assertEq(claims.outstanding(), 0);
        assertEq(token.balanceOf(address(claims)), 0);
    }

    function test_claimsCapIncludesExistingCampaignsAndUnsolicitedTokens() public {
        token.mint(address(claims), 1e18);
        _create(owner, 4e18);
        vm.prank(owner);
        _expectCap(6e18, TOKEN_CAP);
        claims.create(2, bytes32(uint256(2)), 1, owner, 120, 1e18, bytes32(0));
        assertEq(claims.nextCampaign(), 2);
        assertEq(token.balanceOf(address(claims)), TOKEN_CAP);
    }

    function test_claimsExitWorksAfterUnsolicitedExcess() public {
        uint256 id = _create(owner, 1e18);
        token.mint(address(claims), 10e18);
        vm.deal(address(claims), NATIVE_CAP + 1);
        uint256 before = token.balanceOf(owner);
        vm.prank(owner);
        claims.claim(id, 0, owner, 1e18, new bytes32[](0));
        assertEq(token.balanceOf(owner), before + 1e18);
        assertEq(token.balanceOf(address(claims)), 10e18);
        assertEq(claims.outstanding(), 0);
        vm.prank(owner);
        claims.close(id);
        vm.prank(owner);
        claims.prune(id, 0, 1);
    }

    function test_claimsRefundWorksAfterUnsolicitedExcess() public {
        uint256 id = _create(owner, 1e18);
        token.mint(address(claims), 10e18);
        vm.roll(121);
        uint256 before = token.balanceOf(owner);
        vm.prank(owner);
        claims.close(id);
        assertEq(token.balanceOf(owner), before + 1e18);
        assertEq(token.balanceOf(address(claims)), 10e18);
        assertEq(claims.outstanding(), 0);
    }

    function test_claimsNewFundingRejectsForcedNativeExcess() public {
        vm.deal(address(claims), NATIVE_CAP + 1);
        vm.prank(owner);
        _expectCap(NATIVE_CAP + 1, NATIVE_CAP);
        claims.create(1, bytes32(uint256(1)), 1, owner, 120, 1e18, bytes32(0));
        assertEq(claims.nextCampaign(), 1);
    }
}

contract NativePersonalStreamsTest is NativePersonalBase {
    TestToken private token;
    GrantLedger private ledger;

    function setUp() public {
        _setupPersonal();
        token = new TestToken();
        ledger = GrantLedger(
            _deploy(abi.encodePacked(type(GrantLedger).creationCode, abi.encode(address(token), bytes32(0))), "streams")
        );
        _mintAndApprove(token, address(ledger));
    }

    function _grant(address recipient, uint128 amount) private pure returns (GrantLedger.GrantParams memory) {
        return GrantLedger.GrantParams(recipient, amount, 1_000, 1_000, 1_010);
    }

    function test_streamsConstructorAtomicallySetsPersonalPolicy() public view {
        _assertInitialPolicy(ledger);
    }

    function test_streamsAllMutationsRejectUnlistedCaller() public {
        GrantLedger.GrantParams[] memory ps = new GrantLedger.GrantParams[](1);
        ps[0] = _grant(owner, 1e18);
        vm.startPrank(outsider);
        _expectDenied(outsider);
        ledger.create(ps[0]);
        _expectDenied(outsider);
        ledger.createBatch(ps);
        _expectDenied(outsider);
        ledger.claim(1);
        _expectDenied(outsider);
        ledger.tripBrake();
        vm.stopPrank();
    }

    function test_streamsRejectUnlistedBeneficiaryInSingleAndBatch() public {
        vm.prank(owner);
        _expectDenied(outsider);
        ledger.create(_grant(outsider, 1e18));
        GrantLedger.GrantParams[] memory ps = new GrantLedger.GrantParams[](2);
        ps[0] = _grant(owner, 1e18);
        ps[1] = _grant(outsider, 1e18);
        vm.prank(owner);
        _expectDenied(outsider);
        ledger.createBatch(ps);
        assertEq(ledger.nextId(), 1);
        assertEq(ledger.outstanding(), 0);
        assertEq(token.balanceOf(address(ledger)), 0);
    }

    function test_streamsBatchCountsAggregateFundingAgainstCap() public {
        GrantLedger.GrantParams[] memory ps = new GrantLedger.GrantParams[](2);
        ps[0] = _grant(owner, 3e18);
        ps[1] = _grant(owner, 3e18);
        vm.prank(owner);
        _expectCap(6e18, TOKEN_CAP);
        ledger.createBatch(ps);
        assertEq(ledger.nextId(), 1);
        assertEq(token.balanceOf(address(ledger)), 0);
    }

    function test_streamsAddedOwnAccountCanFundAndClaimWithoutFees() public {
        _allow(ledger, ownAccount);
        uint256 before = token.balanceOf(ownAccount);
        vm.prank(ownAccount);
        uint256 id = ledger.create(_grant(ownAccount, 1e18));
        vm.warp(1_010);
        vm.prank(ownAccount);
        assertEq(ledger.claim(id), 1e18);
        assertEq(token.balanceOf(ownAccount), before);
        assertEq(ledger.outstanding(), 0);
    }

    function test_streamsExistingBalanceCapAndExitAfterExcess() public {
        token.mint(address(ledger), 1e18);
        vm.prank(owner);
        uint256 id = ledger.create(_grant(owner, 4e18));
        vm.prank(owner);
        _expectCap(6e18, TOKEN_CAP);
        ledger.create(_grant(owner, 1e18));
        token.mint(address(ledger), 10e18);
        vm.deal(address(ledger), NATIVE_CAP + 1);
        vm.warp(1_010);
        vm.prank(owner);
        assertEq(ledger.claim(id), 4e18);
        assertEq(token.balanceOf(address(ledger)), 11e18);
        assertEq(ledger.outstanding(), 0);
    }
}

contract NativePersonalEscrowTest is NativePersonalBase {
    bytes32 private constant TERMS = keccak256("personal experiment");
    TestToken private token;
    EscrowBook private book;

    function setUp() public {
        _setupPersonal();
        token = new TestToken();
        book = _book(address(token), address(0), "escrow");
        _mintAndApprove(token, address(book));
    }

    function _book(address asset, address arbiter, bytes32 salt) private returns (EscrowBook) {
        return EscrowBook(
            _deploy(
                abi.encodePacked(
                    type(EscrowBook).creationCode,
                    abi.encode(asset, arbiter, arbiter == address(0) ? uint64(0) : uint64(100), TERMS, bytes32(0))
                ),
                salt
            )
        );
    }

    function _create(uint128 amount) private returns (uint256 id) {
        vm.prank(owner);
        return book.create(ownAccount, amount, 1_010, 1_020, 0, TERMS);
    }

    function test_escrowConstructorAtomicallySetsPersonalPolicy() public view {
        _assertInitialPolicy(book);
    }

    function test_escrowAllMutationsRejectUnlistedCaller() public {
        vm.startPrank(outsider);
        _expectDenied(outsider);
        book.create(owner, 1e18, 1_010, 1_020, 0, TERMS);
        _expectDenied(outsider);
        book.accept(1);
        _expectDenied(outsider);
        book.cancel(1);
        _expectDenied(outsider);
        book.release(1);
        _expectDenied(outsider);
        book.refund(1);
        _expectDenied(outsider);
        book.propose(1, 0);
        _expectDenied(outsider);
        book.acceptProposal(1, 1, 0);
        _expectDenied(outsider);
        book.dispute(1);
        _expectDenied(outsider);
        book.rule(1, 0);
        _expectDenied(outsider);
        book.resolveTimeout(1);
        _expectDenied(outsider);
        book.pay(1, false);
        _expectDenied(outsider);
        book.tripBrake();
        vm.stopPrank();
    }

    function test_escrowRequiresOwnSellerAndArbiter() public {
        vm.prank(owner);
        _expectDenied(ownAccount);
        book.create(ownAccount, 1e18, 1_010, 1_020, 0, TERMS);
        EscrowBook arbitrated = _book(address(token), outsider, "arbitrated");
        _allow(arbitrated, ownAccount);
        vm.prank(owner);
        _expectDenied(outsider);
        arbitrated.create(ownAccount, 1e18, 1_010, 1_020, 0, TERMS);
        assertEq(arbitrated.totalLiability(), 0);
    }

    function test_escrowTokenCapIncludesExistingDealsAndDonations() public {
        _allow(book, ownAccount);
        token.mint(address(book), 1e18);
        _create(4e18);
        vm.prank(owner);
        _expectCap(6e18, TOKEN_CAP);
        book.create(ownAccount, 1e18, 1_010, 1_020, 0, TERMS);
        assertEq(book.nextId(), 2);
        assertEq(book.totalLiability(), 4e18);
    }

    function test_escrowNativeCapIsAggregateAndRollsBackFunding() public {
        book = _book(address(0), address(0), "native escrow");
        _allow(book, ownAccount);
        vm.prank(owner);
        book.create{value: 9e14}(ownAccount, 9e14, 1_010, 1_020, 0, TERMS);
        uint256 before = owner.balance;
        vm.prank(owner);
        _expectCap(11e14, NATIVE_CAP);
        book.create{value: 2e14}(ownAccount, 2e14, 1_010, 1_020, 0, TERMS);
        assertEq(address(book).balance, 9e14);
        assertEq(owner.balance, before);
        assertEq(book.nextId(), 2);
    }

    function test_escrowNativeRefundWorksAfterForcedExcess() public {
        book = _book(address(0), address(0), "native refund");
        _allow(book, ownAccount);
        vm.prank(owner);
        uint256 id = book.create{value: 5e14}(ownAccount, 5e14, 1_010, 1_020, 0, TERMS);
        vm.deal(address(book), NATIVE_CAP * 2);
        vm.prank(owner);
        book.cancel(id);
        uint256 before = owner.balance;
        vm.prank(owner);
        book.pay(id, false);
        assertEq(owner.balance, before + 5e14);
        assertEq(address(book).balance, 15e14);
        assertEq(book.totalLiability(), 0);
    }

    function test_escrowOwnPartiesSettleWithoutFeesAfterTokenExcess() public {
        _allow(book, ownAccount);
        uint256 id = _create(1e18);
        vm.prank(ownAccount);
        book.accept(id);
        token.mint(address(book), 10e18);
        vm.prank(owner);
        book.release(id);
        uint256 before = token.balanceOf(ownAccount);
        vm.prank(owner);
        book.pay(id, true);
        assertEq(token.balanceOf(ownAccount), before + 1e18);
        assertEq(token.balanceOf(address(book)), 10e18);
        assertEq(book.totalLiability(), 0);
    }

    function test_escrowRejectsDirectNativeTransfers() public {
        book = _book(address(0), address(0), "no deposits");
        vm.prank(owner);
        (bool ok,) = address(book).call{value: 1}("");
        assertFalse(ok);
        assertEq(address(book).balance, 0);
    }
}

/// @dev A wallet-controlled nested caller used only to test registry admission.
contract NativePersonalPoolCaller is PersonalTest {
    function add(SwapPool pool, TestToken a, TestToken b, uint256 amount) external personalTestAccess {
        _requirePersonalTestAccount(address(pool));
        a.approve(address(pool), amount);
        b.approve(address(pool), amount);
        pool.add(amount, amount, 0, type(uint64).max);
    }
}

contract NativePersonalSwapTest is NativePersonalBase {
    TestToken private a;
    TestToken private b;
    SwapPool private pool;

    function setUp() public {
        _setupPersonal();
        a = new TestToken();
        b = new TestToken();
        pool = SwapPool(
            _deploy(
                abi.encodePacked(
                    type(SwapPool).creationCode, abi.encode(address(a), address(b), uint256(30), bytes32(0))
                ),
                "swap"
            )
        );
        _mintAndApprove(a, address(pool));
        _mintAndApprove(b, address(pool));
    }

    function _add(uint256 amount) private {
        vm.prank(owner);
        pool.add(amount, amount, 0, FAR);
    }

    function test_swapConstructorAtomicallySetsPersonalPolicyAndZeroFees() public view {
        _assertInitialPolicy(pool);
        assertEq(pool.feeBps(), 0);
    }

    function test_swapOrdinaryConstructorKeepsOriginalFeeAndPublicMode() public {
        SwapPool ordinary = new SwapPool(address(a), address(b), 30, bytes32(0));
        assertEq(ordinary.feeBps(), 30);
        assertEq(ordinary.instanceMode(), "testnet");
        assertFalse(ordinary.personalTestEnabled());
    }

    function test_swapAllMutationsRejectUnlistedCaller() public {
        vm.startPrank(outsider);
        _expectDenied(outsider);
        pool.add(1e18, 1e18, 0, FAR);
        _expectDenied(outsider);
        pool.swapExactInput(address(a), 1e17, 0, owner, FAR);
        _expectDenied(outsider);
        pool.swapExactOutput(address(a), 1e17, 1e18, owner, FAR);
        _expectDenied(outsider);
        pool.remove(1, 0, 0, owner, FAR);
        _expectDenied(outsider);
        pool.tripBrake();
        vm.stopPrank();
    }

    function test_swapRejectsUnlistedRecipientsOnBothSwapsAndExit() public {
        _add(1e18);
        vm.startPrank(owner);
        _expectDenied(outsider);
        pool.swapExactInput(address(a), 1e17, 0, outsider, FAR);
        _expectDenied(outsider);
        pool.swapExactOutput(address(a), 1e17, 1e18, outsider, FAR);
        _expectDenied(outsider);
        pool.remove(1, 0, 0, outsider, FAR);
        vm.stopPrank();
        assertEq(a.balanceOf(address(pool)), 1e18);
        assertEq(b.balanceOf(address(pool)), 1e18);
    }

    function test_swapLiquidityCapSumsBothAssetsAndRollsBack() public {
        vm.prank(owner);
        _expectCap(6e18, TOKEN_CAP);
        pool.add(3e18, 3e18, 0, FAR);
        assertEq(pool.totalShares(), 0);
        assertEq(pool.shares(owner), 0);
        assertEq(a.balanceOf(address(pool)), 0);
        assertEq(b.balanceOf(address(pool)), 0);
    }

    function test_swapCapIncludesExistingLiquidityAndBothNewLegs() public {
        _add(2e18);
        uint128 before = pool.totalShares();
        vm.prank(owner);
        _expectCap(52e17, TOKEN_CAP);
        pool.add(6e17, 6e17, 0, FAR);
        assertEq(pool.totalShares(), before);
        assertEq(a.balanceOf(address(pool)), 2e18);
        assertEq(b.balanceOf(address(pool)), 2e18);
    }

    function test_swapCapAppliesBeforeOutputReducesHoldings() public {
        _add(24e17);
        // The final post-swap sum would fit. The temporary incoming balance
        // still exceeds the cap, so the whole swap must be rejected.
        vm.prank(owner);
        _expectCap(51e17, TOKEN_CAP);
        pool.swapExactInput(address(a), 3e17, 0, owner, FAR);
        assertEq(a.balanceOf(address(pool)), 24e17);
        assertEq(b.balanceOf(address(pool)), 24e17);
    }

    function test_swapOutputUsesFeeFreeCurve() public {
        _add(1e18);
        uint256 expected = uint256(1e17) * 1e18 / 11e17;
        assertEq(pool.quoteExactInput(address(a), 1e17), expected);
        uint256 before = b.balanceOf(owner);
        vm.prank(owner);
        assertEq(pool.swapExactInput(address(a), 1e17, expected, owner, FAR), expected);
        assertEq(b.balanceOf(owner), before + expected);
    }

    function test_swapOwnAccountCanProvideLiquidityAfterAdmission() public {
        _allow(pool, ownAccount);
        vm.prank(ownAccount);
        (,, uint256 minted) = pool.add(1e18, 1e18, 0, FAR);
        assertEq(pool.shares(ownAccount), minted);
        vm.prank(ownAccount);
        pool.remove(minted, 0, 0, ownAccount, FAR);
        assertEq(pool.shares(ownAccount), 0);
    }

    function test_swapExitWorksAfterUnsolicitedTokenAndNativeExcess() public {
        _add(1e18);
        a.mint(address(pool), 10e18);
        vm.deal(address(pool), NATIVE_CAP + 1);
        uint256 beforeA = a.balanceOf(owner);
        uint256 beforeB = b.balanceOf(owner);
        uint256 ownedShares = pool.shares(owner);
        vm.prank(owner);
        (uint256 outA, uint256 outB) = pool.remove(ownedShares, 0, 0, owner, FAR);
        assertGt(outA, 1e18);
        assertGt(outB, 0);
        assertEq(a.balanceOf(owner), beforeA + outA);
        assertEq(b.balanceOf(owner), beforeB + outB);
        assertEq(pool.shares(owner), 0);
        assertEq(address(pool).balance, NATIVE_CAP + 1);
    }

    function test_swapAdmitsGuardedNestedCallerOnlyFromOwnFactory() public {
        NativePersonalPoolCaller caller =
            NativePersonalPoolCaller(_deploy(type(NativePersonalPoolCaller).creationCode, "own caller"));
        a.mint(address(caller), 1e18);
        b.mint(address(caller), 1e18);
        assertFalse(pool.personalTestAllowed(address(caller)));
        vm.prank(owner);
        caller.add(pool, a, b, 1e18);
        assertGt(pool.shares(address(caller)), 0);
        vm.prank(outsider);
        _expectDenied(outsider);
        caller.add(pool, a, b, 1);

        vm.prank(outsider);
        PersonalTestDeployer otherFactory = new PersonalTestDeployer(NATIVE_CAP, TOKEN_CAP);
        vm.prank(outsider);
        NativePersonalPoolCaller otherCaller =
            NativePersonalPoolCaller(otherFactory.deploy(type(NativePersonalPoolCaller).creationCode, "other caller"));
        // Admission is scoped to this owner's factory, even for a second
        // contract with a valid personal-test policy for a different wallet.
        vm.prank(owner);
        _expectDenied(address(otherCaller));
        pool.swapExactInput(address(a), 1e17, 0, address(otherCaller), FAR);
        vm.prank(address(otherCaller));
        _expectDenied(address(otherCaller));
        pool.swapExactInput(address(a), 1e17, 0, owner, FAR);
    }
}
