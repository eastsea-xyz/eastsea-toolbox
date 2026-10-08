// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

interface IPersonalTestPolicy {
    function personalTestPolicy() external view returns (bytes32, address, uint256, uint256);
    function personalTestAuthority() external view returns (address);
    function isPersonalTestInstance(address instance) external view returns (bool);
    function isConstructingPersonalTestInstance(address instance) external view returns (bool);
    function registerChild(address child) external;
    function deployChild(bytes calldata creationCode, bytes32 salt) external returns (address);
    function checkPersonalTestTokenReceipt(address token) external;
}

/// @notice An immutable, wallet-owned deployment policy for local mainnet experiments.
/// @dev Constructors keep their testnet ABI. A personal factory supplies the policy
///      while creating an instance, before any application code can be used. Mutable
///      state lives in a namespace so inheriting this base preserves application slots.
abstract contract PersonalTest {
    bytes32 public constant PERSONAL_TEST_MAGIC = keccak256("eastsea.personal-test/1");
    bytes32 private constant _PERSONAL_STORAGE = keccak256("eastsea.toolbox.personal-test.storage/1");

    bool public immutable personalTestEnabled;
    address public immutable personalTestOwner;
    uint256 public immutable personalTestNativeCap;
    uint256 public immutable personalTestTokenCap;
    address public immutable personalTestAuthority;

    struct PersonalState {
        mapping(address => bool) allowed;
        mapping(address => bool) registered;
        address[] tokens;
    }

    error PersonalTestAccountDenied(address account);
    error PersonalTestOwnerOnly();
    error PersonalTestInvalidPolicy();
    error PersonalTestOwnerRequired();
    error PersonalTestValueCap(uint256 held, uint256 cap);

    event PersonalTestCreated(address indexed owner, uint256 nativeCap, uint256 tokenCap, string mode);
    event PersonalTestAccountChanged(address indexed account, bool allowed);

    constructor() {
        (bool ok, bytes memory policy) =
            msg.sender.staticcall(abi.encodeCall(IPersonalTestPolicy.personalTestPolicy, ()));
        bool enabled;
        address owner;
        uint256 nativeCap;
        uint256 tokenCap;
        address authority;
        if (ok && policy.length == 128) {
            bytes32 magic;
            (magic, owner, nativeCap, tokenCap) = abi.decode(policy, (bytes32, address, uint256, uint256));
            if (magic == PERSONAL_TEST_MAGIC) {
                if (owner == address(0) || nativeCap == 0 || tokenCap == 0) revert PersonalTestInvalidPolicy();
                enabled = true;
                (bool authorityOk, bytes memory authorityData) =
                    msg.sender.staticcall(abi.encodeCall(IPersonalTestPolicy.personalTestAuthority, ()));
                authority =
                    authorityOk && authorityData.length == 32 ? abi.decode(authorityData, (address)) : msg.sender;
                if (authority == address(0)) revert PersonalTestInvalidPolicy();
            }
        }
        personalTestEnabled = enabled;
        personalTestOwner = enabled ? owner : address(0);
        personalTestNativeCap = enabled ? nativeCap : 0;
        personalTestTokenCap = enabled ? tokenCap : 0;
        personalTestAuthority = enabled ? authority : address(0);
        if (enabled) {
            _personalState().allowed[owner] = true;
            emit PersonalTestCreated(owner, nativeCap, tokenCap, "personal-test");
        }
    }

    modifier personalTestAccess() {
        _requirePersonalTestAccount(msg.sender);
        _;
    }

    function instanceMode() public view returns (string memory) {
        return personalTestEnabled ? "personal-test" : "testnet";
    }

    function personalTestPolicy() public view returns (bytes32, address, uint256, uint256) {
        return (
            personalTestEnabled ? PERSONAL_TEST_MAGIC : bytes32(0),
            personalTestOwner,
            personalTestNativeCap,
            personalTestTokenCap
        );
    }

    function personalTestAllowed(address account) public view returns (bool) {
        return _personalState().allowed[account];
    }

    /// @notice Add only your own other accounts. The policy cannot be disabled or enlarged.
    function setPersonalTestAccount(address account, bool allowed) external {
        if (!personalTestEnabled || msg.sender != personalTestOwner) revert PersonalTestOwnerOnly();
        if (account == address(0) || (account == personalTestOwner && !allowed)) revert PersonalTestOwnerRequired();
        _personalState().allowed[account] = allowed;
        emit PersonalTestAccountChanged(account, allowed);
    }

    /// @dev Controlled personal tokens notify recipients after transfer. This also
    ///      caps token funding of DAO/multisig treasuries without an admin deposit API.
    function checkPersonalTestTokenReceipt(address token) external personalTestAccess {
        if (!personalTestEnabled || msg.sender != token) revert PersonalTestInvalidPolicy();
        _checkPersonalTestTokenCap(token);
    }

    function _isPersonalTest() internal view returns (bool) {
        return personalTestEnabled;
    }

    function _exampleDeployer() internal view returns (address) {
        return personalTestEnabled ? personalTestOwner : msg.sender;
    }

    function _requirePersonalTestAccount(address account) internal view {
        if (!personalTestEnabled || account == address(this) || _personalState().allowed[account]) return;
        // A policy-shaped public relay is insufficient: it must actually have been
        // created and verified by this wallet's own deployment authority.
        (bool ok, bytes memory data) =
            personalTestAuthority.staticcall(abi.encodeCall(IPersonalTestPolicy.isPersonalTestInstance, (account)));
        if (ok && data.length == 32 && abi.decode(data, (bool))) return;
        (ok, data) = personalTestAuthority.staticcall(
            abi.encodeCall(IPersonalTestPolicy.isConstructingPersonalTestInstance, (account))
        );
        if (ok && data.length == 32 && abi.decode(data, (bool))) return;
        revert PersonalTestAccountDenied(account);
    }

    function _checkPersonalTestNativeCap() internal view {
        if (personalTestEnabled && address(this).balance > personalTestNativeCap) {
            revert PersonalTestValueCap(address(this).balance, personalTestNativeCap);
        }
    }

    function _registerPersonalTestToken(address token) internal {
        if (!personalTestEnabled || _personalState().registered[token]) return;
        if (token.code.length == 0) revert PersonalTestInvalidPolicy();
        _personalState().registered[token] = true;
        _personalState().tokens.push(token);
    }

    /// @dev Raw token base units are summed, rather than trusting an external price oracle.
    function _checkPersonalTestTokenCaps() internal view {
        if (!personalTestEnabled) return;
        address[] storage tokens = _personalState().tokens;
        uint256 remaining = personalTestTokenCap;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 held = IERC20(tokens[i]).balanceOf(address(this));
            if (held > remaining) {
                revert PersonalTestValueCap(personalTestTokenCap - remaining + held, personalTestTokenCap);
            }
            remaining -= held;
        }
    }

    function _checkPersonalTestTokenCap(address token) internal {
        _registerPersonalTestToken(token);
        _checkPersonalTestTokenCaps();
    }

    function _checkPersonalTestTokenDeposit(address token, uint256 amount) internal {
        if (!personalTestEnabled) return;
        _registerPersonalTestToken(token);
        address[] storage tokens = _personalState().tokens;
        uint256 remaining = personalTestTokenCap;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 held = IERC20(tokens[i]).balanceOf(address(this));
            if (held > remaining) {
                revert PersonalTestValueCap(personalTestTokenCap - remaining + held, personalTestTokenCap);
            }
            remaining -= held;
        }
        if (amount > remaining) {
            revert PersonalTestValueCap(personalTestTokenCap - remaining + amount, personalTestTokenCap);
        }
    }

    function _registerPersonalTestChild(address child) internal {
        if (personalTestEnabled) IPersonalTestPolicy(personalTestAuthority).registerChild(child);
    }

    function _personalState() private pure returns (PersonalState storage state) {
        bytes32 slot = _PERSONAL_STORAGE;
        assembly { state.slot := slot }
    }
}
