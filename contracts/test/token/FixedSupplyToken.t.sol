// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

contract FixedSupplyTokenTest is Test {
    FixedSupplyToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant SUPPLY = 1_000_000e18;

    function setUp() public {
        token = new FixedSupplyToken("Island Coin", "ISLE", SUPPLY, alice);
    }

    // ---- 배치 ----

    function test_deploy_fullSupplyToRecipient() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_deploy_revertZeroRecipient() public {
        vm.expectRevert(FixedSupplyToken.ZeroRecipient.selector);
        new FixedSupplyToken("X", "X", 1, address(0));
    }

    function test_deploy_revertZeroSupply() public {
        vm.expectRevert(FixedSupplyToken.ZeroSupply.selector);
        new FixedSupplyToken("X", "X", 0, alice);
    }

    // ---- 출시 후 추가 발행 불가 ----

    function test_noMintEntryPointAfterLaunch() public {
        // ERC20의 _mint는 internal이다. 외부에서 mint 계열 selector를 호출하면
        // 함수 부재로 revert해야 한다.
        bytes memory bad = abi.encodeWithSignature("mint(address,uint256)", bob, 1);
        (bool ok,) = address(token).call(bad);
        assertFalse(ok, "mint(address,uint256) must not exist");

        bad = abi.encodeWithSignature("mint(address,uint256,uint256)", bob, 1, 0);
        (ok,) = address(token).call(bad);
        assertFalse(ok);

        bad = abi.encodeWithSignature("issue(uint256)", 1);
        (ok,) = address(token).call(bad);
        assertFalse(ok);

        assertEq(token.totalSupply(), SUPPLY, "total supply must stay fixed forever");
    }

    // ---- transfer / allowance ----

    function test_transfer_updatesBalances(uint128 amount) public {
        vm.assume(amount > 0 && amount <= SUPPLY);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(alice), SUPPLY - amount);
    }

    function test_transfer_revertInsufficient(uint128 amount) public {
        vm.assume(amount > SUPPLY);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, amount);
    }

    function test_allowance_transferFrom(uint128 amount) public {
        vm.assume(amount > 0 && amount <= SUPPLY);
        vm.prank(alice);
        token.approve(address(this), amount);
        assertEq(token.allowance(alice, address(this)), amount);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, address(this)), 0); // OZ 기본: 무한 아님
        assertEq(token.balanceOf(bob), amount);
    }

    // ---- permit (EIP-2612) ----

    function test_permit_signatureApproves() public {
        uint256 key = 0xA11CE;
        address holder = vm.addr(key);
        vm.prank(alice);
        token.transfer(holder, 100e18);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            key,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            keccak256(
                                "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                            ),
                            holder,
                            address(this),
                            100e18,
                            token.nonces(holder),
                            block.timestamp
                        )
                    )
                )
            )
        );
        token.permit(holder, address(this), 100e18, block.timestamp, v, r, s);
        assertEq(token.allowance(holder, address(this)), 100e18);
        token.transferFrom(holder, bob, 100e18);
        assertEq(token.balanceOf(bob), 100e18);
    }

    // ---- fuzz: 공급 보존 ----

    function test_fuzz_supplyConserved(uint8 seed) public {
        address[4] memory actors = [alice, bob, address(0xBEEF), address(0xCAFE)];
        for (uint256 i = 1; i < actors.length; i++) {
            vm.prank(alice);
            token.transfer(actors[i], SUPPLY / actors.length);
        }

        for (uint256 s = 0; s < 25; s++) {
            address from = actors[(seed + s) % actors.length];
            address to = actors[(uint256(seed) * 3 + s * 7) % actors.length];
            uint256 balBefore = token.balanceOf(from);
            uint256 amount = balBefore / 4; // 항상 지불 가능한 금액
            vm.prank(from);
            token.transfer(to, amount);
            uint256 expected = (from == to) ? balBefore : balBefore - amount;
            assertEq(token.balanceOf(from), expected);
        }

        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "sum of balances must equal total supply");
    }

    // ---- 상태 계량 (examples/token/GAS.md 원본 데이터) ----

    function test_meter_deploy() public {
        StateMeter.Result memory r;
        (, r) = StateMeter.measureDeploy(
            abi.encodePacked(type(FixedSupplyToken).creationCode, abi.encode("Island Coin", "ISLE", SUPPLY, alice))
        );
        emit log_named_uint("deploy gasUsed", r.gasUsed);
        emit log_named_uint("deploy codeBytes", r.codeBytes);
        emit log_named_uint("deploy newSlots (totalSupply+balances)", r.newSlots);
        emit log_named_uint("deploy stateUnits", r.stateUnits);
    }

    function test_meter_transferToNewHolder() public {
        vm.prank(alice);
        token.approve(address(this), type(uint256).max); // 슬롯 예열: 측정 대상 아님

        address[] memory tracked = new address[](1);
        tracked[0] = address(token);
        StateMeter.Result memory r =
            StateMeter.measureCall(alice, tracked, address(token), abi.encodeCall(token.transfer, (bob, 1e18)));
        emit log_named_uint("transfer-new-holder gasUsed", r.gasUsed);
        emit log_named_uint("transfer-new-holder newSlots", r.newSlots);
        emit log_named_uint("transfer-new-holder logBytes", r.logBytes);
        emit log_named_uint("transfer-new-holder stateUnits", r.stateUnits);

        // 두 번째 이체: 이미 잔액 슬롯이 있는 수신자 — 새 슬롯 0
        StateMeter.Result memory r2 =
            StateMeter.measureCall(alice, tracked, address(token), abi.encodeCall(token.transfer, (bob, 1e18)));
        emit log_named_uint("transfer-existing-holder gasUsed", r2.gasUsed);
        emit log_named_uint("transfer-existing-holder newSlots", r2.newSlots);
        emit log_named_uint("transfer-existing-holder stateUnits", r2.stateUnits);

        // 최초 approve: 허용량 슬롯 1개
        StateMeter.Result memory r3 =
            StateMeter.measureCall(alice, tracked, address(token), abi.encodeCall(token.approve, (bob, 1e18)));
        emit log_named_uint("approve-new-spender gasUsed", r3.gasUsed);
        emit log_named_uint("approve-new-spender newSlots", r3.newSlots);
        emit log_named_uint("approve-new-spender stateUnits", r3.stateUnits);
    }
}
