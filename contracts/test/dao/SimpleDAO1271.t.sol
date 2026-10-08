// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SimpleDAO} from "src/dao/SimpleDAO.sol";
import {FixedSupplyToken} from "src/token/FixedSupplyToken.sol";
import {SimpleBrake} from "src/system/SimpleBrake.sol";
import {EastSeaAccountMock} from "test/utils/EastSeaAccountMock.sol";
import {StateMeter} from "test/utils/StateMeter.sol";

/// @dev Separate interface keeps these regressions executable against the old DAO.
interface IDAO1271 {
    function executeWithSigners(
        uint256 proposalId,
        address target,
        uint256 value,
        bytes calldata data,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external returns (bytes memory);

    function vote(uint256 proposalId) external;
    function approvedVotes(uint256 proposalId, address voter) external view returns (bool);
    function domainSeparator() external view returns (bytes32);
    function VOTE_TYPEHASH() external view returns (bytes32);
}

contract DAO1271Target {
    uint256 public calls;
    uint256 public received;
    bool public reject;

    error Rejected();

    function setReject(bool value) external {
        reject = value;
    }

    function record(uint256 value) external payable returns (uint256) {
        if (reject) revert Rejected();
        ++calls;
        received += msg.value;
        return value;
    }
}

contract DAOInvalid1271 {
    uint8 private immutable mode;

    constructor(uint8 mode_) {
        mode = mode_;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        if (mode == 1) revert("invalid owner");
        if (mode == 2) {
            assembly {
                return(0, 0)
            }
        }
        if (mode == 3) {
            assembly {
                mstore(0, 0x1626ba7e)
                return(28, 4)
            }
        }
        return 0xffffffff;
    }
}

contract SimpleDAO1271Test is Test {
    uint256 private constant EOA_KEY = 0xA11CE;
    uint256 private constant P256_KEY = 0xB0B;
    uint256 private constant WRONG_KEY = 0xBAD;
    uint256 private constant P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    uint256 private constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 private constant WEIGHT = 100e18;
    uint48 private constant VOTING_PERIOD = 3 days;
    uint48 private constant TIMELOCK_DELAY = 2 days;
    uint48 private constant GRACE_PERIOD = 7 days;
    bytes32 private constant VOTE_TYPEHASH =
        keccak256("Vote(uint256 proposalId,bytes32 executionHash,uint48 votingEnds,uint48 expires)");
    bytes4 private constant SIGNATURE_COUNT_MISMATCH = bytes4(keccak256("SignatureCountMismatch()"));
    bytes4 private constant VOTE_ALREADY_APPROVED = bytes4(keccak256("VoteAlreadyApproved(uint256,address)"));
    bytes4 private constant VOTING_CLOSED = bytes4(keccak256("VotingClosed(uint256,uint256)"));

    SimpleDAO private dao;
    FixedSupplyToken private token;
    EastSeaAccountMock private account;
    DAO1271Target private target;
    address private eoa;
    address private guardian;

    function setUp() public {
        eoa = vm.addr(EOA_KEY);
        guardian = makeAddr("dao guardian");
        token = new FixedSupplyToken("Vote", "VOTE", 1_000_000e18, address(this));
        (uint256 x, uint256 y) = vm.publicKeyP256(P256_KEY);
        account = new EastSeaAccountMock(bytes32(x), bytes32(y));
        target = new DAO1271Target();
        dao = _newDAO(WEIGHT);
        token.transfer(eoa, WEIGHT);
        token.transfer(address(account), WEIGHT);
    }

    function test_erc1271AccountVotesWithRealP256Signature() public {
        uint256 id = _propose(dao);
        bytes memory signature = _p256Signature(dao.getVoteHash(id), P256_KEY);
        assertEq(account.isValidSignature(dao.getVoteHash(id), signature), bytes4(0x1626ba7e));
        _mature(dao, id);
        bytes memory result = _executeOne(dao, id, address(account), signature);
        assertEq(abi.decode(result, (uint256)), 42);
        assertEq(target.calls(), 1);
        assertEq(target.received(), 1 ether);
        assertEq(dao.state(id), 4);
    }

    function test_eoaVotesThroughExplicitSignerAPI() public {
        _executeEOAControl();
        assertEq(target.calls(), 1);
        assertEq(target.received(), 1 ether);
    }

    function test_voteHashUsesExactEIP712DomainAndContents() public {
        uint256 id = _propose(dao);
        (bytes32 executionHash, uint48 ends,, uint48 expires,) = dao.proposals(id);
        bytes32 domain = _domain(dao);
        bytes32 contents = keccak256(abi.encode(VOTE_TYPEHASH, id, executionHash, ends, expires));
        assertEq(dao.getVoteHash(id), keccak256(abi.encodePacked("\x19\x01", domain, contents)));
        assertEq(IDAO1271(address(dao)).domainSeparator(), domain);
        assertEq(IDAO1271(address(dao)).VOTE_TYPEHASH(), VOTE_TYPEHASH);
    }

    function test_wrongEoaSignerRejected() public {
        _executeEOAControl();
        uint256 id = _propose(dao);
        bytes memory signature = _eoaSignature(dao.getVoteHash(id), WRONG_KEY);
        _mature(dao, id);
        _expectInvalidOne(dao, id, eoa, signature);
        assertEq(dao.state(id), 3);
    }

    function test_wrongP256OwnerRejected() public {
        _executeEOAControl();
        uint256 id = _propose(dao);
        bytes memory signature = _p256Signature(dao.getVoteHash(id), WRONG_KEY);
        _mature(dao, id);
        _expectInvalidOne(dao, id, address(account), signature);
        assertEq(target.calls(), 1);
    }

    function test_proposalNoncePreventsSignatureReplay() public {
        uint256 first = _propose(dao);
        uint256 second = _propose(dao);
        bytes memory signature = _eoaSignature(dao.getVoteHash(first), EOA_KEY);
        _mature(dao, first);
        _executeOne(dao, first, eoa, signature);
        _expectInvalidOne(dao, second, eoa, signature);
        _executeOne(dao, second, eoa, _eoaSignature(dao.getVoteHash(second), EOA_KEY));
        assertEq(target.calls(), 2);
    }

    function test_contractAddressPreventsSignatureReplay() public {
        SimpleDAO other = _newDAO(WEIGHT);
        uint256 id = _propose(dao);
        uint256 otherId = _propose(other);
        assertEq(id, otherId);
        bytes memory signature = _eoaSignature(dao.getVoteHash(id), EOA_KEY);
        _mature(dao, id);
        _executeOne(dao, id, eoa, signature);
        _expectInvalidOne(other, otherId, eoa, signature);
        _executeOne(other, otherId, eoa, _eoaSignature(other.getVoteHash(otherId), EOA_KEY));
        assertEq(target.calls(), 2);
    }

    function test_chainIdPreventsSignatureReplayAndUpdatesDomain() public {
        _executeEOAControl();
        uint256 id = _propose(dao);
        bytes32 originalHash = dao.getVoteHash(id);
        bytes memory signature = _eoaSignature(originalHash, EOA_KEY);
        _mature(dao, id);
        vm.chainId(block.chainid + 1);
        assertNotEq(dao.getVoteHash(id), originalHash);
        assertEq(IDAO1271(address(dao)).domainSeparator(), _domain(dao));
        _expectInvalidOne(dao, id, eoa, signature);
        _executeOne(dao, id, eoa, _eoaSignature(dao.getVoteHash(id), EOA_KEY));
        assertEq(target.calls(), 2);
    }

    function test_erc1271ProposalReplayAndExecutionReplayRejected() public {
        uint256 first = _propose(dao);
        uint256 second = _propose(dao);
        bytes memory signature = _p256Signature(dao.getVoteHash(first), P256_KEY);
        _mature(dao, first);
        _executeOne(dao, first, address(account), signature);
        _expectInvalidOne(dao, second, address(account), signature);
        (address[] memory signers, bytes[] memory signatures) = _one(address(account), signature);
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.AlreadyExecuted.selector, first));
        _execute(dao, first, signers, signatures);
        assertEq(target.calls(), 1);
    }

    function test_expiredProposalRejectsEoaAndP256Votes() public {
        _executeEOAControl();
        uint256 eoaId = _propose(dao);
        uint256 accountId = _propose(dao);
        bytes memory eoaSignature = _eoaSignature(dao.getVoteHash(eoaId), EOA_KEY);
        bytes memory accountSignature = _p256Signature(dao.getVoteHash(accountId), P256_KEY);
        (,,, uint48 expires,) = dao.proposals(eoaId);
        vm.warp(uint256(expires) + 1);
        (address[] memory signers, bytes[] memory signatures) = _one(eoa, eoaSignature);
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.ProposalExpired.selector, block.timestamp, expires));
        _execute(dao, eoaId, signers, signatures);
        (signers, signatures) = _one(address(account), accountSignature);
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.ProposalExpired.selector, block.timestamp, expires));
        _execute(dao, accountId, signers, signatures);
        assertEq(target.calls(), 1);
    }

    function test_contractAccountCanVoteWithoutOffchainSignature() public {
        uint256 id = _propose(dao);
        _accountVote(id);
        assertTrue(IDAO1271(address(dao)).approvedVotes(id, address(account)));
        assertFalse(IDAO1271(address(dao)).approvedVotes(id, eoa));
        _mature(dao, id);
        _executeOne(dao, id, address(account), "");
        assertEq(target.calls(), 1);
    }

    function test_directVoteBelongsToCallerAndRejectsDuplicate() public {
        uint256 id = _propose(dao);
        _voteAs(eoa, id);
        assertTrue(IDAO1271(address(dao)).approvedVotes(id, eoa));
        assertFalse(IDAO1271(address(dao)).approvedVotes(id, address(account)));
        vm.expectRevert(abi.encodeWithSelector(VOTE_ALREADY_APPROVED, id, eoa));
        vm.prank(eoa);
        IDAO1271(address(dao)).vote(id);
        _mature(dao, id);
        _expectInvalidOne(dao, id, address(account), "");
        _executeOne(dao, id, eoa, "");
        assertEq(target.calls(), 1);
    }

    function test_directVoteClosesAtExactVotingEndAndRejectsMissingProposal() public {
        uint256 id = _propose(dao);
        _voteAs(eoa, id);
        (, uint48 ends,,,) = dao.proposals(id);
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.ProposalNotFound.selector, 999));
        vm.prank(eoa);
        IDAO1271(address(dao)).vote(999);
        vm.warp(ends);
        vm.expectRevert(abi.encodeWithSelector(VOTING_CLOSED, block.timestamp, uint256(ends)));
        vm.prank(address(account));
        IDAO1271(address(dao)).vote(id);
    }

    function test_mixedDirectApprovalAndEoaSignatureReachQuorum() public {
        dao = _newDAO(2 * WEIGHT);
        uint256 id = _propose(dao);
        _accountVote(id);
        bytes memory signature = _eoaSignature(dao.getVoteHash(id), EOA_KEY);
        (address[] memory signers, bytes[] memory signatures) = _two(eoa, signature, address(account), "");
        _mature(dao, id);
        _execute(dao, id, signers, signatures);
        assertEq(target.calls(), 1);
    }

    function test_mixedP256AndEoaSignaturesReachQuorum() public {
        dao = _newDAO(2 * WEIGHT);
        uint256 id = _propose(dao);
        bytes32 hash = dao.getVoteHash(id);
        (address[] memory signers, bytes[] memory signatures) =
            _two(eoa, _eoaSignature(hash, EOA_KEY), address(account), _p256Signature(hash, P256_KEY));
        _mature(dao, id);
        _execute(dao, id, signers, signatures);
        assertEq(target.calls(), 1);
    }

    function test_approvalAndSignatureCannotCountSameSignerTwice() public {
        dao = _newDAO(2 * WEIGHT);
        uint256 id = _propose(dao);
        _voteAs(eoa, id);
        bytes memory eoaSignature = _eoaSignature(dao.getVoteHash(id), EOA_KEY);
        bytes memory accountSignature = _p256Signature(dao.getVoteHash(id), P256_KEY);
        _mature(dao, id);
        address[] memory signers = new address[](2);
        bytes[] memory signatures = new bytes[](2);
        signers[0] = eoa;
        signers[1] = eoa;
        signatures[1] = eoaSignature;
        vm.expectRevert(SimpleDAO.InvalidSignature.selector);
        _execute(dao, id, signers, signatures);
        (signers, signatures) = _one(eoa, eoaSignature);
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.QuorumNotReached.selector, WEIGHT, 2 * WEIGHT));
        _execute(dao, id, signers, signatures);
        (signers, signatures) = _one(eoa, "");
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.QuorumNotReached.selector, WEIGHT, 2 * WEIGHT));
        _execute(dao, id, signers, signatures);
        (signers, signatures) = _two(eoa, "", address(account), accountSignature);
        _execute(dao, id, signers, signatures);
        assertEq(target.calls(), 1);
    }

    function test_directAndSignedWeightsUseCurrentBalances() public {
        dao = _newDAO(2 * WEIGHT);
        uint256 id = _propose(dao);
        _accountVote(id);
        bytes memory signature = _eoaSignature(dao.getVoteHash(id), EOA_KEY);
        (address[] memory signers, bytes[] memory signatures) = _two(eoa, signature, address(account), "");
        vm.prank(address(account));
        token.transfer(address(this), 10e18);
        _mature(dao, id);
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.QuorumNotReached.selector, 190e18, 2 * WEIGHT));
        _execute(dao, id, signers, signatures);
        token.transfer(address(account), 10e18);
        _execute(dao, id, signers, signatures);
        assertEq(target.calls(), 1);
    }

    function test_directApprovalDoesNotCountUnlistedVoters() public {
        uint256 id = _propose(dao);
        _voteAs(eoa, id);
        _mature(dao, id);
        bytes[] memory noSignatures = new bytes[](0);
        vm.expectRevert(abi.encodeWithSelector(SimpleDAO.QuorumNotReached.selector, 0, WEIGHT));
        dao.execute(id, address(target), 1 ether, _data(), noSignatures);
        _executeOne(dao, id, eoa, "");
        assertEq(target.calls(), 1);
    }

    function test_duplicateUnsortedAndZeroSignersRejected() public {
        _executeEOAControl();
        uint256 id = _propose(dao);
        bytes32 hash = dao.getVoteHash(id);
        bytes memory eoaSignature = _eoaSignature(hash, EOA_KEY);
        bytes memory accountSignature = _p256Signature(hash, P256_KEY);
        _mature(dao, id);
        address[] memory signers = new address[](2);
        bytes[] memory signatures = new bytes[](2);
        signers[0] = eoa;
        signers[1] = eoa;
        signatures[0] = eoaSignature;
        signatures[1] = eoaSignature;
        vm.expectRevert(SimpleDAO.InvalidSignature.selector);
        _execute(dao, id, signers, signatures);
        (signers, signatures) = _two(eoa, eoaSignature, address(account), accountSignature);
        (signers[0], signers[1]) = (signers[1], signers[0]);
        (signatures[0], signatures[1]) = (signatures[1], signatures[0]);
        vm.expectRevert(SimpleDAO.InvalidSignature.selector);
        _execute(dao, id, signers, signatures);
        _expectInvalidOne(dao, id, address(0), eoaSignature);
    }

    function test_signerAndSignatureArrayLengthsMustMatch() public {
        _executeEOAControl();
        uint256 id = _propose(dao);
        _mature(dao, id);
        address[] memory signers = new address[](1);
        signers[0] = eoa;
        bytes[] memory signatures = new bytes[](0);
        vm.expectRevert(SIGNATURE_COUNT_MISMATCH);
        _execute(dao, id, signers, signatures);
        signers = new address[](0);
        signatures = new bytes[](1);
        vm.expectRevert(SIGNATURE_COUNT_MISMATCH);
        _execute(dao, id, signers, signatures);
    }

    function test_contractFalseRevertAndMalformedReturnRejected() public {
        _executeEOAControl();
        uint256 id = _propose(dao);
        _mature(dao, id);
        for (uint8 mode; mode < 4; ++mode) {
            DAOInvalid1271 invalidAccount = new DAOInvalid1271(mode);
            token.transfer(address(invalidAccount), WEIGHT);
            _expectInvalidOne(dao, id, address(invalidAccount), hex"1234");
        }
        assertEq(dao.state(id), 3);
    }

    function test_contractSignatureRevocationCheckedAtExecution() public {
        uint256 first = _propose(dao);
        bytes memory firstSignature = _p256Signature(dao.getVoteHash(first), P256_KEY);
        _mature(dao, first);
        _executeOne(dao, first, address(account), firstSignature);
        uint256 second = _propose(dao);
        bytes memory signature = _p256Signature(dao.getVoteHash(second), P256_KEY);
        account.setEnabled(false);
        _mature(dao, second);
        _expectInvalidOne(dao, second, address(account), signature);
        account.setEnabled(true);
        _executeOne(dao, second, address(account), signature);
        assertEq(target.calls(), 2);
    }

    function test_highSEoaSignaturesRejectedByBothExecutionAPIs() public {
        _executeEOAControl();
        uint256 id = _propose(dao);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_KEY, dao.getVoteHash(id));
        bytes memory signature = abi.encodePacked(r, bytes32(SECP256K1_N - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        _mature(dao, id);
        _expectInvalidOne(dao, id, eoa, signature);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;
        vm.expectRevert(SimpleDAO.InvalidSignature.selector);
        dao.execute(id, address(target), 1 ether, _data(), signatures);
    }

    function test_legacyRecoveryCannotBypassContractSignaturePolicy() public {
        _executeEOAControl();
        uint256 id = _propose(dao);
        bytes memory signature = _eoaSignature(dao.getVoteHash(id), EOA_KEY);
        vm.etch(eoa, address(account).code);
        _mature(dao, id);
        _expectInvalidOne(dao, id, eoa, signature);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = signature;
        vm.expectRevert(SimpleDAO.InvalidSignature.selector);
        dao.execute(id, address(target), 1 ether, _data(), signatures);
        assertEq(target.calls(), 1);
    }

    function test_brakeBlocksNewVotesButPreservesApprovedExecution() public {
        uint256 id = _propose(dao);
        _accountVote(id);
        vm.prank(guardian);
        dao.engageBrake(1);
        vm.expectRevert(abi.encodeWithSelector(SimpleBrake.BrakedNewEntry.selector, 1));
        vm.prank(eoa);
        IDAO1271(address(dao)).vote(id);
        _mature(dao, id);
        _executeOne(dao, id, address(account), "");
        assertEq(target.calls(), 1);
    }

    function test_failedTargetRollsBackExecutionAndKeepsApproval() public {
        uint256 id = _propose(dao);
        _accountVote(id);
        target.setReject(true);
        _mature(dao, id);
        (address[] memory signers, bytes[] memory signatures) = _one(address(account), "");
        vm.expectRevert(
            abi.encodeWithSelector(
                SimpleDAO.ExecutionFailed.selector, abi.encodeWithSelector(DAO1271Target.Rejected.selector)
            )
        );
        _execute(dao, id, signers, signatures);
        assertEq(dao.state(id), 3);
        assertTrue(IDAO1271(address(dao)).approvedVotes(id, address(account)));
        target.setReject(false);
        _execute(dao, id, signers, signatures);
        assertEq(dao.state(id), 4);
        assertEq(target.calls(), 1);
    }

    function test_meter_directVoteAndApprovedExecution() public {
        uint256 id = _propose(dao);
        address[] memory tracked = new address[](1);
        tracked[0] = address(dao);
        StateMeter.Result memory voteResult =
            StateMeter.measureCall(eoa, tracked, address(dao), abi.encodeCall(IDAO1271.vote, (id)));
        assertTrue(IDAO1271(address(dao)).approvedVotes(id, eoa));
        emit log_named_uint("directVote gasUsed", voteResult.gasUsed);
        emit log_named_uint("directVote newSlots", voteResult.newSlots);
        emit log_named_uint("directVote logBytes", voteResult.logBytes);
        emit log_named_uint("directVote stateUnits", voteResult.stateUnits);
        _mature(dao, id);
        (address[] memory signers, bytes[] memory signatures) = _one(eoa, "");
        StateMeter.Result memory result = StateMeter.measureCall(
            address(this),
            tracked,
            address(dao),
            abi.encodeCall(IDAO1271.executeWithSigners, (id, address(target), 1 ether, _data(), signers, signatures))
        );
        assertEq(target.calls(), 1);
        emit log_named_uint("executeApprovedVote gasUsed", result.gasUsed);
        emit log_named_uint("executeApprovedVote newSlots", result.newSlots);
        emit log_named_uint("executeApprovedVote logBytes", result.logBytes);
        emit log_named_uint("executeApprovedVote stateUnits", result.stateUnits);
    }

    function _newDAO(uint256 quorum) private returns (SimpleDAO result) {
        result = new SimpleDAO(guardian, token, quorum, VOTING_PERIOD, TIMELOCK_DELAY, GRACE_PERIOD);
        vm.deal(address(result), 100 ether);
    }

    function _data() private pure returns (bytes memory) {
        return abi.encodeCall(DAO1271Target.record, (42));
    }

    function _propose(SimpleDAO instance) private returns (uint256) {
        return instance.propose(keccak256(abi.encode(address(target), 1 ether, _data())));
    }

    function _mature(SimpleDAO instance, uint256 id) private {
        (,, uint48 executableFrom,,) = instance.proposals(id);
        vm.warp(executableFrom);
    }

    function _domain(SimpleDAO instance) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("EastSeaSimpleDAO"),
                keccak256("2"),
                block.chainid,
                address(instance)
            )
        );
    }

    function _eoaSignature(bytes32 hash, uint256 key) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        return abi.encodePacked(r, s, v);
    }

    function _p256Signature(bytes32 hash, uint256 key) private view returns (bytes memory) {
        (uint256 x, uint256 y) = vm.publicKeyP256(key);
        (bytes32 r, bytes32 s) = vm.signP256(key, account.signatureDigest(hash));
        if (uint256(s) > P256_N / 2) s = bytes32(P256_N - uint256(s));
        return abi.encodePacked(r, s, bytes32(x), bytes32(y));
    }

    function _voteAs(address voter, uint256 id) private {
        vm.prank(voter);
        IDAO1271(address(dao)).vote(id);
    }

    function _accountVote(uint256 id) private {
        EastSeaAccountMock.Call[] memory calls = new EastSeaAccountMock.Call[](1);
        calls[0] = EastSeaAccountMock.Call(address(dao), 0, abi.encodeCall(IDAO1271.vote, (id)));
        vm.prank(address(account));
        account.execute(calls);
    }

    function _one(address signer, bytes memory signature)
        private
        pure
        returns (address[] memory signers, bytes[] memory signatures)
    {
        signers = new address[](1);
        signatures = new bytes[](1);
        signers[0] = signer;
        signatures[0] = signature;
    }

    function _two(address a, bytes memory aSignature, address b, bytes memory bSignature)
        private
        pure
        returns (address[] memory signers, bytes[] memory signatures)
    {
        signers = new address[](2);
        signatures = new bytes[](2);
        if (a < b) {
            signers[0] = a;
            signatures[0] = aSignature;
            signers[1] = b;
            signatures[1] = bSignature;
        } else {
            signers[0] = b;
            signatures[0] = bSignature;
            signers[1] = a;
            signatures[1] = aSignature;
        }
    }

    function _execute(SimpleDAO instance, uint256 id, address[] memory signers, bytes[] memory signatures)
        private
        returns (bytes memory)
    {
        return IDAO1271(address(instance))
            .executeWithSigners(id, address(target), 1 ether, _data(), signers, signatures);
    }

    function _executeOne(SimpleDAO instance, uint256 id, address signer, bytes memory signature)
        private
        returns (bytes memory)
    {
        (address[] memory signers, bytes[] memory signatures) = _one(signer, signature);
        return _execute(instance, id, signers, signatures);
    }

    function _expectInvalidOne(SimpleDAO instance, uint256 id, address signer, bytes memory signature) private {
        (address[] memory signers, bytes[] memory signatures) = _one(signer, signature);
        vm.expectRevert(SimpleDAO.InvalidSignature.selector);
        _execute(instance, id, signers, signatures);
    }

    function _executeEOAControl() private {
        uint256 id = _propose(dao);
        bytes memory signature = _eoaSignature(dao.getVoteHash(id), EOA_KEY);
        _mature(dao, id);
        _executeOne(dao, id, eoa, signature);
    }
}
