// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice Plain mintable ERC-20 used as the exact-transfer asset in tests.
contract TestToken {
    string public name = "Test";
    string public symbol = "TST";
    uint8 public decimals = 18;
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

    /// @dev Test-only: remove tokens from any holder (models an issuer seizure
    ///      or a rebasing-down asset) to create a custody deficit.
    function burnFrom(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice Charges a 1% fee on every transfer (fee is burned).
contract FeeOnTransferToken is TestToken {
    function _move(address from, address to, uint256 amount) internal override {
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}

/// @notice Can switch into a mode where transfers return true but move nothing.
contract LyingToken is TestToken {
    bool public lying;

    function setLying(bool v) external {
        lying = v;
    }

    function _move(address from, address to, uint256 amount) internal override {
        if (lying) return;
        super._move(from, to, amount);
    }
}

/// @notice Issuer-style blocklist: transfers to or from a blocked address revert.
contract BlockingToken is TestToken {
    mapping(address => bool) public blocked;

    function setBlocked(address who, bool v) external {
        blocked[who] = v;
    }

    function _move(address from, address to, uint256 amount) internal override {
        require(!blocked[from] && !blocked[to], "blocked");
        super._move(from, to, amount);
    }
}

/// @notice Returns false instead of reverting on failure (and on demand).
contract FalseReturnToken is TestToken {
    bool public failNext;

    function setFail(bool v) external {
        failNext = v;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (failNext) return false;
        _move(msg.sender, to, amount);
        return true;
    }
}

interface ITransferHook {
    function onTokenTransfer(address from, uint256 amount) external;
}

/// @notice Calls the recipient after each transfer (ERC-777-style callback),
///         letting tests attempt reentrancy from inside a payout.
contract CallbackToken is TestToken {
    function _move(address from, address to, uint256 amount) internal override {
        super._move(from, to, amount);
        if (to.code.length != 0) {
            try ITransferHook(to).onTokenTransfer(from, amount) {} catch {}
        }
    }
}
