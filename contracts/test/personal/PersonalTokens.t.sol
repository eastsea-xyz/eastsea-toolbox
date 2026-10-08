// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {PersonalTestFixture} from "./PersonalTest.t.sol";
import {PersonalTest} from "src/common/PersonalTest.sol";
import {PersonalTestDeployer} from "src/common/PersonalTestDeployer.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";
import {OnchainNFT} from "src/nft/OnchainNFT.sol";
import {Editions1155} from "src/nft/Editions1155.sol";
import {FixedPriceMarket} from "src/market/FixedPriceMarket.sol";
import {RewardDistributor} from "src/rewards/RewardDistributor.sol";
import {TokenTimeLock} from "src/lock/TokenTimeLock.sol";
import {LinearVesting} from "src/lock/LinearVesting.sol";
import {AmmFactory} from "src/amm/AmmFactory.sol";
import {AmmPair} from "src/amm/AmmPair.sol";
import {AmmRouter} from "src/amm/AmmRouter.sol";
import {BondingLaunchpad} from "src/launchpad/BondingLaunchpad.sol";

contract PersonalTokenExamplesTest is PersonalTestFixture {
    function _token(string memory symbol) internal returns (FixedSupplyToken) {
        return FixedSupplyToken(
            _deploy(type(FixedSupplyToken).creationCode, abi.encode(symbol, symbol, uint256(100), address(this)))
        );
    }

    function test_tokenTransferApprovalAndPermitCannotInviteSecondAccount() public {
        FixedSupplyToken token = _token("OWN");
        vm.expectRevert(_denied());
        token.transfer(other, 1);
        vm.expectRevert(_denied());
        token.approve(other, 1);
        vm.prank(other);
        vm.expectRevert(_denied());
        token.permit(address(this), address(this), 1, block.timestamp + 60, 27, bytes32(0), bytes32(0));
        token.setPersonalTestAccount(other, true);
        token.transfer(other, 1);
        vm.prank(other);
        token.transfer(address(this), 1);
        assertEq(token.balanceOf(address(this)), 100);
    }

    function test_tokenSupplyCapRollback() public {
        bytes memory code = abi.encodePacked(
            type(FixedSupplyToken).creationCode, abi.encode("Too large", "BIG", uint256(101), address(this))
        );
        address predicted = deployer.predict(code, bytes32(uint256(123)));
        vm.expectRevert(PersonalTestDeployer.PersonalTestDeploymentFailed.selector);
        deployer.deploy(code, bytes32(uint256(123)));
        assertEq(predicted.code.length, 0);
    }

    function test_nftCreatorPreservedInheritedTransfersRestrictedRoyaltyZero() public {
        OnchainNFT nft = OnchainNFT(
            _deploy(
                type(OnchainNFT).creationCode,
                abi.encode("Personal NFT", "OWN", uint256(10), uint96(1000), address(this))
            )
        );
        assertEq(nft.creator(), address(this));
        (, uint256 royalty) = nft.royaltyInfo(1, 10000);
        assertEq(royalty, 0);
        vm.prank(other);
        vm.expectRevert(_denied());
        nft.mint(other, 0, 0, 0, 0);
        uint256 id = nft.mint(address(this), 0, 0, 0, 0);
        vm.expectRevert(_denied());
        nft.approve(other, id);
        vm.expectRevert(_denied());
        nft.transferFrom(address(this), other, id);
        nft.setPersonalTestAccount(other, true);
        nft.transferFrom(address(this), other, id);
        assertEq(nft.ownerOf(id), other);
    }

    function test_editionsCallerNativeCapInheritedTransferAndRoyaltyZero() public {
        Editions1155 editions = Editions1155(_deploy(type(Editions1155).creationCode, abi.encode(address(this))));
        uint256 id = editions.createEdition("Own edition", 10, 10, 60, 1000);
        (, uint256 royalty) = editions.royaltyInfo(id, 10000);
        assertEq(royalty, 0);
        vm.prank(other);
        vm.expectRevert(_denied());
        editions.mint{value: 60}(id);
        editions.mint{value: 60}(id);
        vm.expectRevert(_cap(120));
        editions.mint{value: 60}(id);
        vm.expectRevert(_denied());
        editions.safeTransferFrom(address(this), other, id, 1, "");
        vm.expectRevert(_denied());
        editions.setApprovalForAll(other, true);
        editions.withdraw(id);
        assertEq(address(editions).balance, 0);
    }

    function test_marketPrivateAccountsNativeCapAndRoyaltyDisabled() public {
        OnchainNFT nft = new OnchainNFT("Source NFT", "SRC", 2, 1000, address(this));
        FixedPriceMarket market =
            FixedPriceMarket(_deploy(type(FixedPriceMarket).creationCode, abi.encode(address(this))));
        uint256 id = nft.mint(address(this), 0, 0, 0, 0);
        nft.approve(address(market), id);
        uint256 listing = market.list(nft, id, 101);
        vm.prank(other);
        vm.expectRevert(_denied());
        market.buy{value: 101}(listing);
        vm.expectRevert(_cap(101));
        market.buy{value: 101}(listing);
        market.cancel(listing);
        nft.transferFrom(address(this), other, id);
        market.setPersonalTestAccount(other, true);
        vm.prank(other);
        nft.approve(address(market), id);
        vm.prank(other);
        listing = market.list(nft, id, 10);
        market.buy{value: 10}(listing);
        assertEq(market.credits(other), 10); // public royalty would route 1 to NFT creator
        assertEq(market.credits(address(this)), 0);
        vm.prank(other);
        market.withdraw();
        assertEq(address(market).balance, 0);
    }

    function test_rewardsAggregateTwoAssetCapAndCaller() public {
        FixedSupplyToken stakeToken = _token("STAKE");
        FixedSupplyToken rewardToken = _token("REWARD");
        RewardDistributor distributor = RewardDistributor(
            _deploy(
                type(RewardDistributor).creationCode,
                abi.encode(address(this), IERC20(address(stakeToken)), IERC20(address(rewardToken)))
            )
        );
        stakeToken.approve(address(distributor), type(uint256).max);
        rewardToken.approve(address(distributor), type(uint256).max);
        vm.prank(other);
        vm.expectRevert(_denied());
        distributor.stake(1);
        distributor.fundRewards(60, 60);
        vm.expectRevert(_cap(101));
        distributor.stake(41);
        distributor.stake(40);
        distributor.unstake(40);
        assertEq(distributor.totalStaked(), 0);
    }

    function test_timeLockAccountsCapAndExit() public {
        FixedSupplyToken token = _token("LOCK");
        TokenTimeLock lock =
            TokenTimeLock(_deploy(type(TokenTimeLock).creationCode, abi.encode(address(this), IERC20(address(token)))));
        token.approve(address(lock), type(uint256).max);
        vm.prank(other);
        vm.expectRevert(_denied());
        lock.lockFor(other, 1, 0, 60);
        vm.expectRevert(_denied());
        lock.lockFor(other, 1, 0, 60);
        lock.lockFor(address(this), 60, 0, 60);
        lock.setPersonalTestAccount(other, true);
        vm.expectRevert(_cap(101));
        lock.lockFor(other, 41, 0, 60);
        vm.warp(block.timestamp + 61);
        lock.release();
        assertEq(token.balanceOf(address(lock)), 0);
    }

    function test_vestingFactoryPullsUserWalletAtPredictedAddress() public {
        FixedSupplyToken token = _token("VEST");
        bytes memory args = abi.encode(IERC20(address(token)), address(this), uint256(60), uint256(0), uint256(60));
        bytes memory code = abi.encodePacked(type(LinearVesting).creationCode, args);
        address predicted = deployer.predict(code, bytes32(nonce + 1));
        token.setPersonalTestAccount(predicted, true);
        token.approve(predicted, 60);
        LinearVesting vesting = LinearVesting(_deploy(type(LinearVesting).creationCode, args));
        assertEq(address(vesting), predicted);
        assertEq(token.balanceOf(address(vesting)), 60);
        vm.prank(other);
        vm.expectRevert(_denied());
        vesting.claim();
        vm.warp(block.timestamp + 61);
        vesting.claim();
        assertEq(token.balanceOf(address(this)), 100);
    }
}

contract PersonalAmmLaunchpadTest is PersonalTestFixture {
    function setUp() public override {
        super.setUp();
        deployer = new PersonalTestDeployer(100, 10_000);
    }

    function _token(string memory symbol) internal returns (FixedSupplyToken) {
        return FixedSupplyToken(
            _deploy(type(FixedSupplyToken).creationCode, abi.encode(symbol, symbol, uint256(10_000), address(this)))
        );
    }

    function _factory() internal returns (AmmFactory) {
        return AmmFactory(_deploy(type(AmmFactory).creationCode, abi.encode(address(this))));
    }

    function test_ammPrivateRouterAndPairPropagatePolicyNoFeeAndEnforceAggregateCap() public {
        AmmFactory factory = _factory();
        AmmRouter router = AmmRouter(_deploy(type(AmmRouter).creationCode, abi.encode(factory)));
        FixedSupplyToken a = _token("A");
        FixedSupplyToken b = _token("B");
        a.approve(address(router), type(uint256).max);
        b.approve(address(router), type(uint256).max);
        vm.prank(other);
        vm.expectRevert(_denied());
        router.addLiquidity(address(a), address(b), 2000, 2000, 0, 0, other, block.timestamp + 60);
        router.addLiquidity(address(a), address(b), 2000, 2000, 0, 0, address(this), block.timestamp + 60);
        AmmPair pair = AmmPair(factory.getPair(address(a), address(b)));
        assertEq(pair.instanceMode(), "personal-test");
        assertEq(pair.personalTestOwner(), address(this));
        assertTrue(deployer.isPersonalTestInstance(address(pair)));
        vm.prank(other);
        vm.expectRevert(_denied());
        pair.sync();
        vm.expectRevert(
            abi.encodeWithSelector(PersonalTest.PersonalTestValueCap.selector, uint256(12000), uint256(10000))
        );
        router.addLiquidity(address(a), address(b), 6000, 6000, 0, 0, address(this), block.timestamp + 60);
        vm.expectRevert(
            abi.encodeWithSelector(PersonalTest.PersonalTestValueCap.selector, uint256(11000), uint256(10000))
        );
        a.transfer(address(pair), 7000);
        assertEq(router.getAmountOut(100, 2000, 2000), 95); // 997/1000 fee would quote 94
        address[] memory path = new address[](2);
        (path[0], path[1]) = (address(a), address(b));
        router.swapExactTokensForTokens(100, 95, path, address(this), block.timestamp + 60);
        pair.approve(address(router), type(uint256).max);
        router.removeLiquidity(
            address(a), address(b), pair.balanceOf(address(this)), 0, 0, address(this), block.timestamp + 60
        );
    }

    function test_launchpadConstructorChildPolicyFeesAndGraduation() public {
        AmmFactory factory = _factory();
        FixedSupplyToken quote = _token("QUOTE");
        BondingLaunchpad.Config memory cfg = BondingLaunchpad.Config({
            name: "Own launch",
            symbol: "OWN",
            tokenSupply: 4000,
            quoteFloor: 1000,
            tokenFloor: 1000,
            graduationTarget: 2000,
            feeBps: 500,
            snipeTaxBps: 500,
            snipeWindow: 60,
            perBuyerCap: 0,
            treasury: address(this)
        });
        BondingLaunchpad launch = BondingLaunchpad(
            _deploy(
                type(BondingLaunchpad).creationCode, abi.encode(address(this), IERC20(address(quote)), factory, cfg)
            )
        );
        FixedSupplyToken curve = launch.curveToken();
        assertEq(curve.instanceMode(), "personal-test");
        assertEq(curve.personalTestOwner(), address(this));
        assertTrue(deployer.isPersonalTestInstance(address(curve)));
        assertEq(launch.feeBps(), 0);
        assertEq(launch.snipeTaxBps(), 0);
        quote.approve(address(launch), type(uint256).max);
        vm.prank(other);
        vm.expectRevert(_denied());
        launch.buy(1, 0);
        uint256 before = quote.balanceOf(address(this));
        launch.buy(1000, 0);
        assertEq(before - quote.balanceOf(address(this)), 1000);
        launch.buy(1000, 0);
        launch.graduate();
        AmmPair pair = AmmPair(launch.graduatePair());
        assertEq(pair.instanceMode(), "personal-test");
        assertTrue(deployer.isPersonalTestInstance(address(pair)));
        assertGt(pair.balanceOf(address(this)), 0); // personal LP belongs to wallet; no operator rescue
    }
}
