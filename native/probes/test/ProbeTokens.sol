// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {TestToken} from "../../common/test/Tokens.sol";

/// @notice TEST-ONLY token shapes added by Lane C. The Lane B set in
///         common/test/Tokens.sol (fee, lying, blocking, false-return,
///         callback) is reused as is; these cover the remaining C0 cases.

/// @notice USDT-style token: `transfer`/`transferFrom` return no data at all.
///         Exact-transfer code must accept an empty return when the balance
///         deltas are exact.
contract NoBoolToken {
    string public name = "NoBool";
    string public symbol = "NB";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice Share-based rebasing token. Transfers are exact at the moment they
///         happen, so a one-transaction probe cannot see the rebase; holders'
///         balances change later when anyone calls `rebase`.
contract RebasingToken {
    string public name = "Rebase";
    string public symbol = "RB";
    uint8 public decimals = 18;
    uint256 internal constant ONE = 1e18;
    /// @dev balance = shares * index / ONE
    uint256 public index = ONE;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function balanceOf(address who) public view returns (uint256) {
        return sharesOf[who] * index / ONE;
    }

    function totalSupply() external view returns (uint256) {
        return totalShares * index / ONE;
    }

    /// @notice Multiply every balance by `newIndex / index`.
    function rebase(uint256 newIndex) external {
        require(newIndex != 0, "index");
        index = newIndex;
    }

    /// @dev Amounts are chosen as multiples of the index in tests so share
    ///      conversion is exact; a real rebasing token can also round.
    function mint(address to, uint256 amount) external {
        uint256 s = amount * ONE / index;
        totalShares += s;
        sharesOf[to] += s;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        uint256 s = amount * ONE / index;
        sharesOf[from] -= s;
        sharesOf[to] += s;
        emit Transfer(from, to, amount);
    }
}

/// @notice Issuer pause: while paused every transfer reverts (models a
///         globally frozen asset, distinct from a per-address blocklist).
contract PausableToken is TestToken {
    bool public paused;

    function setPaused(bool v) external {
        paused = v;
    }

    function _move(address from, address to, uint256 amount) internal override {
        require(!paused, "paused");
        super._move(from, to, amount);
    }
}
