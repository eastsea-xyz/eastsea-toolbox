// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {TokenTimeLock} from "src/lock/TokenTimeLock.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";

/// @notice 회귀 — 완전 인출된 그랜트가 수혜자를 영구히 잠가두면 안 된다.
///         완료된 그랜트는 교체 전까지 기록으로 남고, 활성(released < amount)
///         그랜트는 여전히 거부된다. (aether-node ba9a973에서 포팅)
contract TimeLockReuseTest is Test {
    FixedSupplyToken internal token;
    TokenTimeLock internal lock;

    function _fixture() internal {
        vm.warp(1_000_000);
        token = new FixedSupplyToken("Lock Test", "LOCK", 200, address(this));
        lock = new TokenTimeLock(address(this), IERC20(address(token)));
        token.approve(address(lock), type(uint256).max);
        lock.lockFor(address(this), 100, 0, 10);
    }

    /// @dev 전량 해제된 그랜트는 교체할 수 있고, 교체 전까지 기록은 남는다.
    function test_lockFor_newGrantAfterFullRelease() public {
        _fixture();
        vm.warp(block.timestamp + 11); // 기간(10초) 경과 — 전액 vested
        lock.release();
        (uint128 amount, uint128 released,,,) = lock.locks(address(this));
        assertEq(amount, 100); // 교체 전까지 완료 기록은 남는다
        assertEq(released, 100);
        assertEq(lock.releasable(address(this)), 0); // 완료 그랜트의 미지급분은 0
        lock.lockFor(address(this), 75, 0, 5);
        (amount, released,,,) = lock.locks(address(this));
        assertEq(amount, 75); // 새 그랜트가 기록되었다
        assertEq(released, 0);
        vm.warp(block.timestamp + 6);
        lock.release();
        assertEq(token.balanceOf(address(this)), 200); // 새 그랜트까지 전액 지급
    }

    /// @dev 활성 그랜트는 여전히 교체가 거부된다.
    function test_lockFor_activeGrantCannotBeReplaced() public {
        _fixture();
        vm.expectRevert(abi.encodeWithSelector(TokenTimeLock.AlreadyLocked.selector, address(this)));
        lock.lockFor(address(this), 75, 0, 5);
    }

    /// @dev 만기했지만 미인출 그랜트도 여전히 교체가 거부된다.
    function test_lockFor_maturedButUnreleasedGrantCannotBeReplaced() public {
        _fixture();
        vm.warp(block.timestamp + 11);
        vm.expectRevert(abi.encodeWithSelector(TokenTimeLock.AlreadyLocked.selector, address(this)));
        lock.lockFor(address(this), 75, 0, 5);
    }
}
