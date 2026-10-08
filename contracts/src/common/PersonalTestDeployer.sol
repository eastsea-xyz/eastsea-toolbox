// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PersonalTest, IPersonalTestPolicy} from "./PersonalTest.sol";

/// @notice Deploy this factory from your own wallet, then create only your own copies.
/// @dev No ETH custody, keys, operator, withdrawals, fees, or public deployment entry.
contract PersonalTestDeployer {
    bytes32 public constant PERSONAL_TEST_MAGIC = keccak256("eastsea.personal-test/1");
    address public immutable personalTestOwner;
    uint256 public immutable personalTestNativeCap;
    uint256 public immutable personalTestTokenCap;
    mapping(address => bool) public isPersonalTestInstance;
    mapping(address => bool) private _constructing;

    error PersonalTestOwnerOnly();
    error PersonalTestInvalidPolicy();
    error PersonalTestDeploymentFailed();
    error PersonalTestUnguardedInstance(address instance);

    event PersonalInstanceDeployed(address indexed owner, address indexed instance, bytes32 salt);

    constructor(uint256 nativeCap, uint256 tokenCap) {
        if (nativeCap == 0 || tokenCap == 0) revert PersonalTestInvalidPolicy();
        personalTestOwner = msg.sender;
        personalTestNativeCap = nativeCap;
        personalTestTokenCap = tokenCap;
    }

    function instanceMode() external pure returns (string memory) {
        return "personal-test";
    }

    function personalTestAllowed(address account) external view returns (bool) {
        return account == personalTestOwner;
    }

    function personalTestAuthority() external view returns (address) {
        return address(this);
    }

    function personalTestPolicy() external view returns (bytes32, address, uint256, uint256) {
        return (PERSONAL_TEST_MAGIC, personalTestOwner, personalTestNativeCap, personalTestTokenCap);
    }

    function isConstructingPersonalTestInstance(address instance) external view returns (bool) {
        return _constructing[instance];
    }

    function deploy(bytes calldata creationCode, bytes32 salt) external returns (address instance) {
        if (msg.sender != personalTestOwner) revert PersonalTestOwnerOnly();
        return _deploy(creationCode, salt);
    }

    /// @dev A constructor-created child must receive the policy from deployed code,
    ///      since its parent does not have runtime code until construction finishes.
    function deployChild(bytes calldata creationCode, bytes32 salt) external returns (address instance) {
        if (!isPersonalTestInstance[msg.sender] && !_constructing[msg.sender]) revert PersonalTestOwnerOnly();
        return _deploy(creationCode, keccak256(abi.encode(msg.sender, salt)));
    }

    function predict(bytes calldata creationCode, bytes32 salt) external view returns (address) {
        return _predict(creationCode, salt);
    }

    function registerChild(address child) external {
        if (!isPersonalTestInstance[msg.sender]) revert PersonalTestOwnerOnly();
        _verify(child);
        isPersonalTestInstance[child] = true;
    }

    function _deploy(bytes memory creationCode, bytes32 salt) private returns (address instance) {
        address predicted = _predict(creationCode, salt);
        _constructing[predicted] = true;
        assembly { instance := create2(0, add(creationCode, 32), mload(creationCode), salt) }
        delete _constructing[predicted];
        if (instance == address(0)) revert PersonalTestDeploymentFailed();
        _verify(instance);
        isPersonalTestInstance[instance] = true;
        emit PersonalInstanceDeployed(personalTestOwner, instance, salt);
    }

    function _verify(address instance) private view {
        if (instance.code.length == 0) revert PersonalTestUnguardedInstance(instance);
        (bool ok, bytes memory data) = instance.staticcall(abi.encodeCall(IPersonalTestPolicy.personalTestPolicy, ()));
        if (!ok || data.length != 128) revert PersonalTestUnguardedInstance(instance);
        (bytes32 magic, address owner, uint256 nativeCap, uint256 tokenCap) =
            abi.decode(data, (bytes32, address, uint256, uint256));
        if (
            magic != PERSONAL_TEST_MAGIC || owner != personalTestOwner || nativeCap != personalTestNativeCap
                || tokenCap != personalTestTokenCap
        ) revert PersonalTestUnguardedInstance(instance);
        PersonalTest target = PersonalTest(instance);
        if (
            !target.personalTestEnabled() || target.personalTestAuthority() != address(this)
                || !target.personalTestAllowed(owner)
                || keccak256(bytes(target.instanceMode())) != keccak256("personal-test")
        ) {
            revert PersonalTestUnguardedInstance(instance);
        }
    }

    function _predict(bytes memory creationCode, bytes32 salt) private view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(creationCode)))))
        );
    }
}
