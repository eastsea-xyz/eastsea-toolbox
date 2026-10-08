// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {ClaimCampaigns} from "../../claims/src/ClaimCampaigns.sol";
import {TestToken} from "../../common/test/Tokens.sol";

/// @dev This test deliberately imports only pre-personal-test contracts. It
///      also runs against the old source snapshot to prove the guards fail
///      before the implementation, rather than only checking a new getter.
contract BaselinePersonalPolicyFactory {
    bytes32 private constant MAGIC = keccak256("eastsea.personal-test/1");
    address public immutable owner;
    mapping(address => bool) public isPersonalTestInstance;

    constructor(address owner_) {
        owner = owner_;
    }

    function personalTestPolicy() external view returns (bytes32, address, uint256, uint256) {
        return (MAGIC, owner, 1e15, 5e18);
    }

    function deployClaim(address token) external returns (ClaimCampaigns instance) {
        require(msg.sender == owner, "owner");
        instance = new ClaimCampaigns(token, bytes32(0));
        isPersonalTestInstance[address(instance)] = true;
    }
}

contract BaselinePersonalTest is Test {
    TestToken private token;
    ClaimCampaigns private claims;
    address private secondAccount = makeAddr("unlisted second account");

    function setUp() public {
        token = new TestToken();
        claims = new BaselinePersonalPolicyFactory(address(this)).deployClaim(address(token));
        token.mint(address(this), 20e18);
        token.mint(secondAccount, 20e18);
        token.approve(address(claims), type(uint256).max);
        vm.prank(secondAccount);
        token.approve(address(claims), type(uint256).max);
    }

    function test_baseline_unlistedSecondAccountCannotFund() public {
        vm.prank(secondAccount);
        vm.expectRevert();
        claims.create(1, bytes32(uint256(1)), 1, secondAccount, uint64(block.number + 20), 1e18, bytes32(0));
        assertEq(token.balanceOf(address(claims)), 0);
        assertEq(claims.nextCampaign(), 1);
    }

    function test_baseline_aggregateValueCapRejectsSecondFunding() public {
        claims.create(1, bytes32(uint256(1)), 1, address(this), uint64(block.number + 20), 4e18, bytes32(0));
        vm.expectRevert();
        claims.create(2, bytes32(uint256(2)), 1, address(this), uint64(block.number + 20), 2e18, bytes32(0));
        assertEq(token.balanceOf(address(claims)), 4e18);
        assertEq(claims.nextCampaign(), 2);
    }
}
