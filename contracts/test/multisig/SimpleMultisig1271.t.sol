// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleMultisig} from "src/multisig/SimpleMultisig.sol";
import {EastSeaAccountMock} from "test/utils/EastSeaAccountMock.sol";

/// @dev Use an interface so these regressions also compile against the old
/// implementation. Tests exercise accepted new authorization, reconstruct the
/// typed digest, or detect an authorization bypass accepted by the old code.
interface ISimpleMultisig1271 {
    error NotOwner();
    error TransactionExpired(uint256 deadline);

    function executeWithSigners(
        address to,
        uint256 value,
        bytes calldata data,
        uint256 nonce,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external returns (bytes memory);

    function executeWithSigners(
        address to,
        uint256 value,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external returns (bytes memory);

    function getTransactionHash(address to, uint256 value, bytes calldata data, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32);

    function approve(address to, uint256 value, bytes calldata data, uint256 nonce) external;
    function approve(address to, uint256 value, bytes calldata data, uint256 nonce, uint256 deadline) external;
    function approvals(bytes32 digest, address owner) external view returns (bool);
}

contract False1271Signer {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}

contract Reverting1271Signer {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        revert("signature rejected");
    }
}

contract Malformed1271Signer {
    fallback() external {
        assembly {
            mstore(0, 0x1626ba7e)
            return(28, 4)
        }
    }
}

contract MultisigRejectingTarget {
    fallback() external payable {
        revert("target failed");
    }
}

contract SimpleMultisig1271Test is Test {
    uint256 private constant EOA_KEY = 0x1271;
    uint256 private constant P256_KEY = 0xB1;
    uint256 private constant P256_ORDER = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    uint256 private constant NO_DEADLINE = type(uint256).max;
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant TRANSACTION_TYPEHASH =
        keccak256("Transaction(address to,uint256 value,bytes data,uint256 nonce,uint256 deadline)");

    SimpleMultisig private wallet;
    ISimpleMultisig1271 private authorizations;
    EastSeaAccountMock private account;
    address private eoa;
    address private recipient;
    bytes32 private ownerX;
    bytes32 private ownerY;

    function setUp() public {
        vm.warp(1_000);
        eoa = vm.addr(EOA_KEY);
        recipient = makeAddr("1271 recipient");
        (uint256 x, uint256 y) = vm.publicKeyP256(P256_KEY);
        ownerX = bytes32(x);
        ownerY = bytes32(y);
        account = new EastSeaAccountMock(ownerX, ownerY);
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = address(account) < eoa ? (address(account), eoa) : (eoa, address(account));
        wallet = new SimpleMultisig(owners, 2);
        authorizations = ISimpleMultisig1271(address(wallet));
        vm.deal(address(wallet), 20 ether);
    }

    function test_erc1271P256OwnerExecutes() public {
        bytes32 digest = _executeP256(1);
        assertEq(recipient.balance, 1 ether);
        assertTrue(wallet.executed(digest));
    }

    function test_eoaExplicitSignerExecutes() public {
        SimpleMultisig eoaWallet = _singleOwnerWallet(eoa);
        uint256 deadline = block.timestamp + 20;
        bytes32 digest = _typedDigest(address(eoaWallet), recipient, 1 ether, "", 1, deadline);
        address[] memory signers = new address[](1);
        bytes[] memory signatures = new bytes[](1);
        signers[0] = eoa;
        signatures[0] = _signEOA(digest);
        ISimpleMultisig1271(address(eoaWallet))
            .executeWithSigners(recipient, 1 ether, "", 1, deadline, signers, signatures);
        assertEq(recipient.balance, 1 ether);
    }

    function test_legacyEOAEntryPointUsesTypedData() public {
        SimpleMultisig eoaWallet = _singleOwnerWallet(eoa);
        bytes32 digest = _typedDigest(address(eoaWallet), recipient, 1 ether, "", 1, NO_DEADLINE);
        assertEq(eoaWallet.getTransactionHash(recipient, 1 ether, "", 1), digest);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signEOA(digest);
        eoaWallet.execute(recipient, 1 ether, "", 1, signatures);
        assertEq(recipient.balance, 1 ether);
    }

    function test_legacyEOARejectsHighS() public {
        SimpleMultisig eoaWallet = _singleOwnerWallet(eoa);
        bytes32 digest = eoaWallet.getTransactionHash(recipient, 1 ether, "", 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_KEY, digest);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, bytes32(SECP256K1_ORDER - uint256(s)), uint8(v == 27 ? 28 : 27));
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        eoaWallet.execute(recipient, 1 ether, "", 1, signatures);
        assertFalse(eoaWallet.executed(digest));
    }

    function test_legacyRecoveredOwnerWithCodeUses1271() public {
        SimpleMultisig eoaWallet = _singleOwnerWallet(eoa);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signEOA(eoaWallet.getTransactionHash(recipient, 1 ether, "", 1));
        eoaWallet.execute(recipient, 1 ether, "", 1, signatures);
        assertEq(recipient.balance, 1 ether);

        vm.etch(eoa, type(False1271Signer).runtimeCode);
        bytes32 digest = eoaWallet.getTransactionHash(recipient, 1 ether, "", 2);
        signatures[0] = _signEOA(digest);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        eoaWallet.execute(recipient, 1 ether, "", 2, signatures);
        assertFalse(eoaWallet.executed(digest));
    }

    function test_wrongP256KeyRejected() public {
        _executeP256(1);
        bytes32 digest = wallet.getTransactionHash(recipient, 1 ether, "", 2);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, false);
        signatures[_accountIndex()] = _signP256(digest, P256_KEY + 1);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        authorizations.executeWithSigners(recipient, 1 ether, "", 2, signers, signatures);
        assertFalse(wallet.executed(digest));
    }

    function test_wrongOwnerRejected() public {
        _executeP256(1);
        bytes32 digest = wallet.getTransactionHash(recipient, 1 ether, "", 2);
        uint256 outsiderKey = 0xBAD;
        address outsider = vm.addr(outsiderKey);
        address[] memory signers = new address[](2);
        bytes[] memory signatures = new bytes[](2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(outsiderKey, digest);
        (signers[0], signers[1]) =
            address(account) < outsider ? (address(account), outsider) : (outsider, address(account));
        signatures[0] = signers[0] == address(account) ? _signP256(digest, P256_KEY) : abi.encodePacked(r, s, v);
        signatures[1] = signers[1] == address(account) ? _signP256(digest, P256_KEY) : abi.encodePacked(r, s, v);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        authorizations.executeWithSigners(recipient, 1 ether, "", 2, signers, signatures);
    }

    function test_replayRejected() public {
        bytes32 digest = _executeP256(1);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, false);
        vm.expectRevert(SimpleMultisig.AlreadyExecuted.selector);
        authorizations.executeWithSigners(recipient, 1 ether, "", 1, signers, signatures);
        assertEq(recipient.balance, 1 ether);
    }

    function test_expiredTransactionRejected() public {
        _executeP256(1);
        uint256 deadline = block.timestamp + 10;
        bytes32 digest = authorizations.getTransactionHash(recipient, 1 ether, "", 2, deadline);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, false);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ISimpleMultisig1271.TransactionExpired.selector, deadline));
        authorizations.executeWithSigners(recipient, 1 ether, "", 2, deadline, signers, signatures);
        assertFalse(wallet.executed(digest));
    }

    function test_deadlineBoundaryIsInclusive() public {
        uint256 deadline = block.timestamp;
        bytes32 digest = _typedDigest(address(wallet), recipient, 1 ether, "", 1, deadline);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, false);
        authorizations.executeWithSigners(recipient, 1 ether, "", 1, deadline, signers, signatures);
        assertTrue(wallet.executed(digest));
    }

    function test_deadlineCannotBeChangedByRelayer() public {
        _executeP256(1);
        uint256 deadline = block.timestamp + 10;
        bytes32 digest = authorizations.getTransactionHash(recipient, 1 ether, "", 2, deadline);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, false);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        authorizations.executeWithSigners(recipient, 1 ether, "", 2, signers, signatures);
    }

    function test_accountDirectApprovalMixesWithEOASignature() public {
        bytes32 digest = _approveFromAccount(recipient, 1 ether, "", 1, NO_DEADLINE);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, true);
        authorizations.executeWithSigners(recipient, 1 ether, "", 1, signers, signatures);
        assertTrue(wallet.executed(digest));
        assertEq(recipient.balance, 1 ether);
    }

    function test_onlyDirectApprovalsExecuteWithoutOffchainSigning() public {
        uint256 deadline = block.timestamp + 10;
        bytes32 digest = _approveFromAccount(recipient, 1 ether, "", 1, deadline);
        vm.prank(eoa);
        authorizations.approve(recipient, 1 ether, "", 1, deadline);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, true);
        signatures[1 - _accountIndex()] = "";
        vm.prank(makeAddr("relayer"));
        authorizations.executeWithSigners(recipient, 1 ether, "", 1, deadline, signers, signatures);
        assertTrue(wallet.executed(digest));
    }

    function test_directApprovalRejectsNonOwner() public {
        _approveFromAccount(recipient, 1 ether, "", 1, NO_DEADLINE);
        vm.prank(makeAddr("nonowner"));
        vm.expectRevert(ISimpleMultisig1271.NotOwner.selector);
        authorizations.approve(recipient, 1 ether, "", 1);
    }

    function test_directApprovalRejectsExpired() public {
        _approveFromAccount(recipient, 1 ether, "", 1, NO_DEADLINE);
        uint256 deadline = block.timestamp - 1;
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(ISimpleMultisig1271.TransactionExpired.selector, deadline));
        authorizations.approve(recipient, 1 ether, "", 2, deadline);
    }

    function test_directApprovalRejectsExecutedTransaction() public {
        _executeP256(1);
        vm.prank(eoa);
        vm.expectRevert(SimpleMultisig.AlreadyExecuted.selector);
        authorizations.approve(recipient, 1 ether, "", 1);
    }

    function test_directApprovalIsBoundToTransactionContents() public {
        _approveFromAccount(recipient, 1 ether, "", 1, NO_DEADLINE);
        bytes32 changedDigest = wallet.getTransactionHash(recipient, 2 ether, "", 1);
        (address[] memory signers, bytes[] memory signatures) = _pair(changedDigest, true);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        authorizations.executeWithSigners(recipient, 2 ether, "", 1, signers, signatures);
    }

    function test_unsortedSignersRejected() public {
        _executeP256(1);
        bytes32 digest = wallet.getTransactionHash(recipient, 1 ether, "", 2);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, false);
        (signers[0], signers[1]) = (signers[1], signers[0]);
        (signatures[0], signatures[1]) = (signatures[1], signatures[0]);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        authorizations.executeWithSigners(recipient, 1 ether, "", 2, signers, signatures);
    }

    function test_duplicateSignerRejected() public {
        _executeP256(1);
        bytes32 digest = wallet.getTransactionHash(recipient, 1 ether, "", 2);
        address[] memory signers = new address[](2);
        bytes[] memory signatures = new bytes[](2);
        signers[0] = address(account);
        signers[1] = address(account);
        signatures[0] = _signP256(digest, P256_KEY);
        signatures[1] = signatures[0];
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        authorizations.executeWithSigners(recipient, 1 ether, "", 2, signers, signatures);
    }

    function test_signerSignatureLengthMismatchRejected() public {
        _executeP256(1);
        bytes32 digest = wallet.getTransactionHash(recipient, 1 ether, "", 2);
        (address[] memory signers,) = _pair(digest, false);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signEOA(digest);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        authorizations.executeWithSigners(recipient, 1 ether, "", 2, signers, signatures);
    }

    function test_insufficientSignersRejected() public {
        _executeP256(1);
        bytes32 digest = wallet.getTransactionHash(recipient, 1 ether, "", 2);
        address[] memory signers = new address[](1);
        bytes[] memory signatures = new bytes[](1);
        signers[0] = address(account);
        signatures[0] = _signP256(digest, P256_KEY);
        vm.expectRevert(abi.encodeWithSelector(SimpleMultisig.InsufficientConfirmations.selector, 1, 2));
        authorizations.executeWithSigners(recipient, 1 ether, "", 2, signers, signatures);
    }

    function test_erc1271FalseResultRejected() public {
        _executeP256(1);
        _assertInvalidContractSigner(address(new False1271Signer()));
    }

    function test_erc1271RevertRejected() public {
        _executeP256(1);
        _assertInvalidContractSigner(address(new Reverting1271Signer()));
    }

    function test_erc1271MalformedResultRejected() public {
        _executeP256(1);
        _assertInvalidContractSigner(address(new Malformed1271Signer()));
    }

    function test_erc1271RevocationCheckedAtExecution() public {
        _executeP256(1);
        bytes32 digest = wallet.getTransactionHash(recipient, 1 ether, "", 2);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, false);
        account.setEnabled(false);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        authorizations.executeWithSigners(recipient, 1 ether, "", 2, signers, signatures);
    }

    function test_typedDataBindsCurrentChainAndNonce() public {
        bytes32 digest = _typedDigest(address(wallet), recipient, 1 ether, "", 1, NO_DEADLINE);
        assertEq(wallet.getTransactionHash(recipient, 1 ether, "", 1), digest);
        assertNotEq(wallet.getTransactionHash(recipient, 1 ether, "", 2), digest);
        bytes32 oldDomain = wallet.domainSeparator();
        vm.chainId(block.chainid + 1);
        assertNotEq(wallet.domainSeparator(), oldDomain);
        assertEq(
            wallet.getTransactionHash(recipient, 1 ether, "", 1),
            _typedDigest(address(wallet), recipient, 1 ether, "", 1, NO_DEADLINE)
        );
        assertNotEq(wallet.getTransactionHash(recipient, 1 ether, "", 1), digest);
    }

    function test_crossInstanceSignaturesRejected() public {
        _executeP256(1);
        bytes32 digest = wallet.getTransactionHash(recipient, 1 ether, "", 2);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, false);
        SimpleMultisig other = new SimpleMultisig(signers, 2);
        vm.deal(address(other), 2 ether);
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        ISimpleMultisig1271(address(other)).executeWithSigners(recipient, 1 ether, "", 2, signers, signatures);
    }

    function test_targetFailureRollsBackExecution() public {
        _executeP256(1);
        address target = address(new MultisigRejectingTarget());
        bytes32 digest = _approveFromAccount(target, 0, "", 2, NO_DEADLINE);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, true);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "target failed");
        vm.expectRevert(abi.encodeWithSelector(SimpleMultisig.ExecutionFailed.selector, reason));
        authorizations.executeWithSigners(target, 0, "", 2, signers, signatures);
        assertFalse(wallet.executed(digest));
        assertTrue(authorizations.approvals(digest, address(account)));
    }

    function _executeP256(uint256 nonce) private returns (bytes32 digest) {
        digest = wallet.getTransactionHash(recipient, 1 ether, "", nonce);
        (address[] memory signers, bytes[] memory signatures) = _pair(digest, false);
        vm.prank(makeAddr("relayer"));
        authorizations.executeWithSigners(recipient, 1 ether, "", nonce, signers, signatures);
    }

    function _approveFromAccount(address to, uint256 value, bytes memory data, uint256 nonce, uint256 deadline)
        private
        returns (bytes32 digest)
    {
        digest = _typedDigest(address(wallet), to, value, data, nonce, deadline);
        EastSeaAccountMock.Call[] memory calls = new EastSeaAccountMock.Call[](1);
        bytes memory payload = deadline == NO_DEADLINE
            ? abi.encodeWithSignature("approve(address,uint256,bytes,uint256)", to, value, data, nonce)
            : abi.encodeWithSignature(
                "approve(address,uint256,bytes,uint256,uint256)", to, value, data, nonce, deadline
            );
        calls[0] = EastSeaAccountMock.Call(address(wallet), 0, payload);
        vm.prank(address(account));
        account.execute(calls);
        assertTrue(authorizations.approvals(digest, address(account)));
    }

    function _pair(bytes32 digest, bool useApproval)
        private
        view
        returns (address[] memory signers, bytes[] memory signatures)
    {
        signers = new address[](2);
        signatures = new bytes[](2);
        uint256 accountIndex = _accountIndex();
        signers[accountIndex] = address(account);
        signers[1 - accountIndex] = eoa;
        signatures[accountIndex] = useApproval ? bytes("") : _signP256(digest, P256_KEY);
        signatures[1 - accountIndex] = _signEOA(digest);
    }

    function _accountIndex() private view returns (uint256) {
        return address(account) < eoa ? 0 : 1;
    }

    function _signEOA(bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signP256(bytes32 digest, uint256 privateKey) private view returns (bytes memory) {
        (bytes32 r, bytes32 s) = vm.signP256(privateKey, account.signatureDigest(digest));
        if (uint256(s) > P256_ORDER / 2) s = bytes32(P256_ORDER - uint256(s));
        return abi.encodePacked(r, s, ownerX, ownerY);
    }

    function _singleOwnerWallet(address owner) private returns (SimpleMultisig deployed) {
        address[] memory owners = new address[](1);
        owners[0] = owner;
        deployed = new SimpleMultisig(owners, 1);
        vm.deal(address(deployed), 2 ether);
    }

    function _assertInvalidContractSigner(address signer) private {
        SimpleMultisig invalidWallet = _singleOwnerWallet(signer);
        address[] memory signers = new address[](1);
        bytes[] memory signatures = new bytes[](1);
        signers[0] = signer;
        signatures[0] = hex"01";
        vm.expectRevert(SimpleMultisig.InvalidSignature.selector);
        ISimpleMultisig1271(address(invalidWallet)).executeWithSigners(recipient, 1 ether, "", 1, signers, signatures);
    }

    function _typedDigest(
        address verifyingContract,
        address to,
        uint256 value,
        bytes memory data,
        uint256 nonce,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("EastSeaSimpleMultisig"), keccak256("2"), block.chainid, verifyingContract
            )
        );
        bytes32 structHash = keccak256(abi.encode(TRANSACTION_TYPEHASH, to, value, keccak256(data), nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }
}
