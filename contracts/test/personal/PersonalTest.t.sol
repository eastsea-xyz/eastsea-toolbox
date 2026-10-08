// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {PersonalTest} from "src/common/PersonalTest.sol";
import {PersonalTestDeployer} from "src/common/PersonalTestDeployer.sol";
import {InvoiceBook} from "src/invoice/InvoiceBook.sol";
import {MilestoneEscrow} from "src/escrow/MilestoneEscrow.sol";
import {AllOrNothingCrowdfund} from "src/crowdfund/AllOrNothingCrowdfund.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {CommitRevealRaffle} from "src/raffle/CommitRevealRaffle.sol";
import {MerkleAirdrop} from "src/airdrop/MerkleAirdrop.sol";
import {NameGatedDrop} from "src/names/NameGatedDrop.sol";
import {AgentVending} from "src/vending/AgentVending.sol";
import {SimpleDAO} from "src/dao/SimpleDAO.sol";
import {SimpleMultisig} from "src/multisig/SimpleMultisig.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";

contract UnguardedCloneFixture {
    uint256 public total;

    function deposit() external payable {
        total += msg.value;
    }
}

contract NamesReadOnlyFixture {
    function reverseOf(address) external pure returns (string memory) {
        return "own.aeth";
    }
}

contract SpoofedPersonalRelay {
    function personalTestPolicy() external pure returns (bytes32, address, uint256, uint256) {
        return (keccak256("eastsea.personal-test/1"), address(1), 100, 100);
    }

    function issue(InvoiceBook target) external {
        target.issue(1, 60, "spoof");
    }
}

abstract contract PersonalTestFixture is Test {
    PersonalTestDeployer internal deployer;
    address internal other = makeAddr("other-account");
    uint256 internal nonce;

    function setUp() public virtual {
        deployer = new PersonalTestDeployer(100, 100);
        vm.deal(address(this), 1 ether);
        vm.deal(other, 1 ether);
    }

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function _deploy(bytes memory creationCode, bytes memory args) internal returns (address instance) {
        instance = deployer.deploy(abi.encodePacked(creationCode, args), bytes32(++nonce));
        PersonalTest target = PersonalTest(instance);
        assertEq(target.instanceMode(), "personal-test");
        assertEq(target.personalTestOwner(), address(this));
        assertEq(target.personalTestAuthority(), address(deployer));
        assertEq(target.personalTestNativeCap(), 100);
        assertEq(target.personalTestTokenCap(), deployer.personalTestTokenCap());
        assertTrue(target.personalTestAllowed(address(this)));
        assertFalse(target.personalTestAllowed(other));
        assertTrue(deployer.isPersonalTestInstance(instance));
        assertLe(instance.code.length, 24_576, "personal runtime exceeds EIP-170");
    }

    function _denied() internal view returns (bytes memory) {
        return abi.encodeWithSelector(PersonalTest.PersonalTestAccountDenied.selector, other);
    }

    function _cap(uint256 held) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PersonalTest.PersonalTestValueCap.selector, held, 100);
    }

    function _send(address target, uint256 amount) internal returns (bool ok, bytes memory data) {
        (ok, data) = target.call{value: amount}("");
    }
}

contract PersonalFactoryTest is PersonalTestFixture {
    function test_factory_onlyWalletCanDeployAndRawClonesRollback() public {
        bytes memory code = type(UnguardedCloneFixture).creationCode;
        address predicted = deployer.predict(code, bytes32(uint256(1)));
        vm.prank(other);
        vm.expectRevert(PersonalTestDeployer.PersonalTestOwnerOnly.selector);
        deployer.deploy(code, bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(PersonalTestDeployer.PersonalTestUnguardedInstance.selector, predicted));
        deployer.deploy(code, bytes32(uint256(1)));
        assertEq(predicted.code.length, 0);
        assertFalse(deployer.isPersonalTestInstance(predicted));
        assertFalse(deployer.isConstructingPersonalTestInstance(predicted));
    }

    function test_factory_rejectsZeroCaps() public {
        vm.expectRevert(PersonalTestDeployer.PersonalTestInvalidPolicy.selector);
        new PersonalTestDeployer(0, 100);
        vm.expectRevert(PersonalTestDeployer.PersonalTestInvalidPolicy.selector);
        new PersonalTestDeployer(100, 0);
    }

    function test_allowlistOwnerControlAndNoDisable() public {
        InvoiceBook book =
            InvoiceBook(payable(_deploy(type(InvoiceBook).creationCode, abi.encode(address(this), address(this)))));
        vm.prank(other);
        vm.expectRevert(_denied());
        book.issue(1, 60, "private");
        vm.prank(other);
        vm.expectRevert(PersonalTest.PersonalTestOwnerOnly.selector);
        book.setPersonalTestAccount(other, true);
        book.setPersonalTestAccount(other, true);
        assertTrue(book.personalTestAllowed(other));
        vm.prank(other);
        vm.expectRevert(PersonalTest.PersonalTestOwnerOnly.selector);
        book.setPersonalTestAccount(address(this), true);
        uint256 id = book.issue(1, 60, "own second account");
        vm.prank(other);
        book.settle{value: 1}(id);
        book.setPersonalTestAccount(other, false);
        vm.prank(other);
        vm.expectRevert(_denied());
        book.purge(id);
    }

    function test_ownerCannotRemoveItself() public {
        InvoiceBook book =
            InvoiceBook(payable(_deploy(type(InvoiceBook).creationCode, abi.encode(address(this), address(this)))));
        vm.expectRevert(PersonalTest.PersonalTestOwnerRequired.selector);
        book.setPersonalTestAccount(address(this), false);
        vm.expectRevert(PersonalTest.PersonalTestOwnerRequired.selector);
        book.setPersonalTestAccount(address(0), true);
    }

    function test_unregisteredPolicyRelayCannotForward() public {
        InvoiceBook book =
            InvoiceBook(payable(_deploy(type(InvoiceBook).creationCode, abi.encode(address(this), address(this)))));
        SpoofedPersonalRelay relay = new SpoofedPersonalRelay();
        vm.expectRevert(abi.encodeWithSelector(PersonalTest.PersonalTestAccountDenied.selector, address(relay)));
        relay.issue(book);
    }

    function test_testnetConstructorsRemainOpen() public {
        InvoiceBook book = new InvoiceBook(address(this), address(this));
        assertEq(book.instanceMode(), "testnet");
        uint256 id = book.issue(101, 60, "testnet demo");
        vm.prank(other);
        book.settle{value: 101}(id);
        assertEq(book.totalSettled(), 101);
    }
}

contract PersonalNativeExamplesTest is PersonalTestFixture {
    function test_invoiceUnauthorizedAndTransientValueCap() public {
        InvoiceBook book =
            InvoiceBook(payable(_deploy(type(InvoiceBook).creationCode, abi.encode(address(this), address(this)))));
        uint256 id = book.issue(101, 60, "over cap");
        vm.prank(other);
        vm.expectRevert(_denied());
        book.settle{value: 101}(id);
        vm.expectRevert(_cap(101));
        book.settle{value: 101}(id);
        assertEq(book.totalSettled(), 0);
        uint256 small = book.issue(1, 60, "own invoice");
        book.settle{value: 1}(small);
        assertEq(book.totalSettled(), 1);
    }

    function test_escrowOwnSecondAccountAggregateCapAndForcedDonationExit() public {
        MilestoneEscrow escrow =
            MilestoneEscrow(payable(_deploy(type(MilestoneEscrow).creationCode, abi.encode(address(this)))));
        vm.expectRevert(_denied());
        escrow.createDeal{value: 1}(other, 1);
        escrow.setPersonalTestAccount(other, true);
        escrow.createDeal{value: 60}(other, 1);
        vm.expectRevert(_cap(101));
        escrow.createDeal{value: 41}(other, 1);
        vm.deal(address(escrow), 200); // forced ETH cannot make legitimate refunds unavailable
        escrow.buyerRefund(1);
        assertEq(address(escrow).balance, 140);
    }

    function test_crowdfundCallerAndBalanceCap() public {
        AllOrNothingCrowdfund fund = AllOrNothingCrowdfund(
            payable(_deploy(
                    type(AllOrNothingCrowdfund).creationCode,
                    abi.encode(address(this), address(this), uint128(100), uint48(60))
                ))
        );
        vm.prank(other);
        vm.expectRevert(_denied());
        fund.contribute{value: 1}();
        fund.contribute{value: 60}();
        vm.expectRevert(_cap(101));
        fund.contribute{value: 41}();
        fund.contribute{value: 40}();
        fund.withdraw();
        assertEq(address(fund).balance, 0);
    }

    function test_subscriptionCallerCapAndOwnRefund() public {
        SubscriptionManager manager = SubscriptionManager(
            payable(_deploy(
                    type(SubscriptionManager).creationCode, abi.encode(address(this), address(this), uint256(1))
                ))
        );
        vm.prank(other);
        vm.expectRevert(_denied());
        manager.subscribe{value: 1}();
        manager.subscribe{value: 60}();
        vm.expectRevert(_cap(101));
        manager.subscribe{value: 41}();
        vm.deal(address(manager), 200);
        manager.cancel();
        assertEq(address(manager).balance, 140);
    }

    function test_raffleCallerAndAggregateNativeCap() public {
        CommitRevealRaffle raffle = CommitRevealRaffle(
            payable(_deploy(
                    type(CommitRevealRaffle).creationCode,
                    abi.encode(address(this), keccak256("seed"), uint256(60), uint48(60), uint48(60))
                ))
        );
        vm.prank(other);
        vm.expectRevert(_denied());
        raffle.enter{value: 60}();
        raffle.enter{value: 60}();
        vm.expectRevert(_cap(120));
        raffle.enter{value: 60}();
    }

    function test_airdropClaimCallerAndFundingCap() public {
        bytes32 root = keccak256(abi.encodePacked(address(this), uint256(50)));
        MerkleAirdrop drop = MerkleAirdrop(
            payable(_deploy(type(MerkleAirdrop).creationCode, abi.encode(root, address(this), uint48(60))))
        );
        vm.prank(other);
        vm.expectRevert(_denied());
        drop.claim(50, new bytes32[](0));
        (bool ok,) = _send(address(drop), 60);
        assertTrue(ok);
        bytes memory errorData;
        (ok, errorData) = _send(address(drop), 41);
        assertFalse(ok);
        assertEq(errorData, _cap(101));
        drop.claim(50, new bytes32[](0));
        assertEq(drop.totalClaimed(), 50);
    }

    function test_nameDropReadonlySystemDependencyCallerAndCap() public {
        NamesReadOnlyFixture names = new NamesReadOnlyFixture();
        NameGatedDrop drop = NameGatedDrop(
            payable(_deploy(
                    type(NameGatedDrop).creationCode, abi.encode(address(names), address(this), uint256(10), uint48(60))
                ))
        );
        vm.prank(other);
        vm.expectRevert(_denied());
        drop.claim();
        (bool ok,) = _send(address(drop), 101);
        assertFalse(ok);
        (ok,) = _send(address(drop), 10);
        assertTrue(ok);
        drop.claim();
        assertEq(drop.claimCount(), 1);
    }

    function test_vendingCallerAndAggregateCap() public {
        AgentVending vending = AgentVending(
            payable(_deploy(
                    type(AgentVending).creationCode, abi.encode(address(this), address(this), uint256(60), uint48(60))
                ))
        );
        vm.prank(other);
        vm.expectRevert(_denied());
        vending.order{value: 60}(keccak256("job"));
        uint256 id = vending.order{value: 60}(keccak256("own job"));
        vm.expectRevert(_cap(120));
        vending.order{value: 60}(keccak256("another"));
        vending.deliver(id, keccak256("result"));
        assertEq(address(vending).balance, 0);
    }
}

contract PersonalTreasuriesTest is PersonalTestFixture {
    function _token(string memory symbol) internal returns (FixedSupplyToken) {
        return FixedSupplyToken(
            _deploy(type(FixedSupplyToken).creationCode, abi.encode(symbol, symbol, uint256(100), address(this)))
        );
    }

    function test_multisigFundingSignersTargetsAndAggregateTokenCap() public {
        address[] memory owners = new address[](1);
        owners[0] = address(this);
        SimpleMultisig safe =
            SimpleMultisig(payable(_deploy(type(SimpleMultisig).creationCode, abi.encode(owners, uint256(1)))));
        vm.prank(other);
        vm.expectRevert(_denied());
        safe.approve(address(this), 1, "", 0);
        (bool ok,) = _send(address(safe), 60);
        assertTrue(ok);
        (ok,) = _send(address(safe), 41);
        assertFalse(ok);
        vm.expectRevert(_denied());
        safe.approve(other, 1, "", 0);
        FixedSupplyToken a = _token("A");
        FixedSupplyToken b = _token("B");
        a.transfer(address(safe), 60);
        vm.expectRevert(_cap(101));
        b.transfer(address(safe), 41);
        assertEq(a.balanceOf(address(safe)), 60);
        assertEq(b.balanceOf(address(safe)), 0);
        safe.approve(address(this), 60, "", 1);
        bytes[] memory signatures = new bytes[](1);
        safe.executeWithSigners(address(this), 60, "", 1, owners, signatures);
        assertEq(address(safe).balance, 0);
    }

    function test_daoProposalVotingExecutionTargetAndCap() public {
        FixedSupplyToken votes = _token("VOTE");
        SimpleDAO dao = SimpleDAO(
            payable(_deploy(
                    type(SimpleDAO).creationCode,
                    abi.encode(address(this), IERC20(address(votes)), uint256(1), uint48(10), uint48(10), uint48(60))
                ))
        );
        vm.prank(other);
        vm.expectRevert(_denied());
        dao.propose(keccak256("public proposal"));
        (bool ok,) = _send(address(dao), 101);
        assertFalse(ok);
        (ok,) = _send(address(dao), 60);
        assertTrue(ok);
        uint256 id = dao.propose(keccak256(abi.encode(address(this), uint256(60), bytes(""))));
        dao.vote(id);
        vm.warp(block.timestamp + 21);
        address[] memory signers = new address[](1);
        signers[0] = address(this);
        dao.executeWithSigners(id, address(this), 60, "", signers, new bytes[](1));
        assertEq(address(dao).balance, 0);
    }
}
