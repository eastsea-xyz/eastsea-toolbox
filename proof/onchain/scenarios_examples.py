"""DAO and multisig journeys for the real EastSea executor harness.

SCENARIOS uses codex/onchain-harness's registry/Context interface. Each write
goes through ctx.tx, which requires a real finalized receipt; this module never
starts a node, uses test-only RPC methods or writes a passing result itself.
"""

UNIT = 10**18
PAY = 10**15


def _deploy(ctx, path, contract, constructor, args):
    return ctx.deploy("contracts", "src/" + path, contract, constructor, args)


def _ordered(ctx, senders):
    return sorted(senders, key=lambda sender: int(ctx.accounts[sender], 16))


def _signatures(ctx, senders, digest):
    return [ctx.account_signature(sender, digest) for sender in senders]


def _bool(ctx, contract, signature, args):
    value = ctx.read(contract, signature, args)[0]
    return value is True or str(value).lower() == "true"


def multisig(ctx):
    ordered = _ordered(ctx, (1, 2))
    owners = [ctx.accounts[sender] for sender in ordered]
    contract = _deploy(ctx, "multisig/SimpleMultisig.sol", "SimpleMultisig",
                       "(address[],uint256)", (owners, 2))
    ctx.check(ctx.uint(contract, "threshold()(uint256)") == 2, "multisig threshold is two")
    for owner in owners:
        ctx.check(_bool(ctx, contract, "isOwner(address)(bool)", (owner,)), "owner registered")
    ctx.tx(contract, "", value=4 * PAY)
    recipient = ctx.accounts[6]
    hash_signature = "getTransactionHash(address,uint256,bytes,uint256)(bytes32)"
    execute = "executeWithSigners(address,uint256,bytes,uint256,address[],bytes[])"
    args = (recipient, PAY, "0x", 1)
    digest = ctx.read(contract, hash_signature, args)[0]
    signatures = _signatures(ctx, ordered, digest)

    ctx.tx(contract, execute, (*args, owners[:1], signatures[:1]), sender=5, expect_revert=True)
    ctx.tx(contract, execute, (*args, [owners[0]] * 2, [signatures[0]] * 2),
           sender=5, expect_revert=True)
    ctx.tx(contract, execute, (*args, owners[::-1], signatures[::-1]), sender=5, expect_revert=True)
    wrong = signatures.copy()
    wrong[0] = ctx.account_signature(3, digest)
    ctx.tx(contract, execute, (*args, owners, wrong), sender=5, expect_revert=True)
    ctx.tx(contract, execute, (recipient, PAY + 1, "0x", 1, owners, signatures),
           sender=5, expect_revert=True)
    ctx.check(not _bool(ctx, contract, "executed(bytes32)(bool)", (digest,)),
              "rejected signatures preserve the operation")
    before = ctx.balance(recipient)
    ctx.tx(contract, execute, (*args, owners, signatures), sender=5)
    ctx.check(ctx.balance(recipient) - before == PAY, "ERC1271 quorum pays the signed recipient")
    ctx.check(_bool(ctx, contract, "executed(bytes32)(bool)", (digest,)), "operation consumed")
    ctx.tx(contract, execute, (*args, owners, signatures), sender=5, expect_revert=True)

    # A wallet without message signing approves its exact operation on-chain.
    direct_args = (recipient, PAY, "0x", 2)
    direct_digest = ctx.read(contract, hash_signature, direct_args)[0]
    empty = ["0x", "0x"]
    ctx.tx(contract, execute, (*direct_args, owners, empty), sender=5, expect_revert=True)
    approve = "approve(address,uint256,bytes,uint256)"
    ctx.tx(contract, approve, direct_args, sender=3, expect_revert=True)
    for sender in ordered:
        ctx.tx(contract, approve, direct_args, sender=sender)
        ctx.check(_bool(ctx, contract, "approvals(bytes32,address)(bool)",
                        (direct_digest, ctx.accounts[sender])), "approval belongs to account caller")
    ctx.tx(contract, execute, (*direct_args, [owners[0]] * 2, empty), sender=5, expect_revert=True)
    before = ctx.balance(recipient)
    ctx.tx(contract, execute, (*direct_args, owners, empty), sender=5)
    ctx.check(ctx.balance(recipient) - before == PAY, "direct approvals work without message signatures")
    ctx.tx(contract, execute, (*direct_args, owners, empty), sender=5, expect_revert=True)

    # Direct approvals and an account signature may share one quorum.
    mixed_args = (recipient, PAY, "0x", 3)
    mixed_digest = ctx.read(contract, hash_signature, mixed_args)[0]
    ctx.tx(contract, approve, mixed_args, sender=ordered[0])
    mixed = ["0x", ctx.account_signature(ordered[1], mixed_digest)]
    before = ctx.balance(recipient)
    ctx.tx(contract, execute, (*mixed_args, owners, mixed), sender=5)
    ctx.check(ctx.balance(recipient) - before == PAY, "mixed approval/signature quorum counts each owner once")

    # Read and sign before expiry; wait for ordinary real devnet blocks.
    deadline = ctx.now() + 12
    expired_args = (recipient, PAY, "0x", 4, deadline)
    expired_digest = ctx.read(contract,
        "getTransactionHash(address,uint256,bytes,uint256,uint256)(bytes32)", expired_args)[0]
    expired_signatures = _signatures(ctx, ordered, expired_digest)
    ctx.wait_until(deadline + 1)
    ctx.tx(contract, "executeWithSigners(address,uint256,bytes,uint256,uint256,address[],bytes[])",
           (*expired_args, owners, expired_signatures), sender=5, expect_revert=True)
    ctx.tx(contract, "approve(address,uint256,bytes,uint256,uint256)", expired_args,
           sender=ordered[0], expect_revert=True)
    ctx.check(not _bool(ctx, contract, "executed(bytes32)(bool)", (expired_digest,)),
              "expiry cannot consume the operation")
    ctx.check(ctx.balance(contract) == PAY, "only three authorized payouts left the multisig")
    ctx.notes.append("EIP712 v2 with ERC1271 P256 owners, direct approvals, mixed quorum, replay and deadline rejection.")


def dao(ctx):
    votes = _deploy(ctx, "token/FixedSupplyToken.sol", "FixedSupplyToken",
                    "(string,string,uint256,address)", ("Journey Votes", "JVT", 1_000 * UNIT, ctx.accounts[1]))
    ctx.tx(votes, "transfer(address,uint256)", (ctx.accounts[2], 200 * UNIT))
    contract = _deploy(ctx, "dao/SimpleDAO.sol", "SimpleDAO",
                       "(address,address,uint256,uint48,uint48,uint48)",
                       (ctx.accounts[1], votes, 900 * UNIT, 30, 6, 90))
    ctx.tx(contract, "", value=3 * PAY)
    recipient = ctx.accounts[6]
    payload_hash = ctx.keccak(ctx.abi_encode("f(address,uint256,bytes)", (recipient, PAY, "0x")))
    ctx.tx(contract, "propose(bytes32)", (payload_hash,), sender=3)
    proposal = ctx.read(contract, "proposals(uint256)(bytes32,uint48,uint48,uint48,bool)", (1,))
    ctx.check(proposal[0].lower() == payload_hash.lower(), "proposal commits exact execution")
    ctx.check(int(proposal[2]) - int(proposal[1]) == 6, "proposal preserves its timelock")
    ordered = _ordered(ctx, (1, 2))
    signers = [ctx.accounts[sender] for sender in ordered]
    digest = ctx.read(contract, "getVoteHash(uint256)(bytes32)", (1,))[0]
    signatures = _signatures(ctx, ordered, digest)
    execute = "executeWithSigners(uint256,address,uint256,bytes,address[],bytes[])"
    args = (1, recipient, PAY, "0x")
    ctx.tx(contract, execute, (*args, signers, signatures), sender=5, expect_revert=True)
    ctx.wait_until(int(proposal[2]))
    ctx.tx(contract, execute, (*args, signers[:1], signatures[:1]), sender=5, expect_revert=True)
    ctx.tx(contract, execute, (*args, [signers[0]] * 2, [signatures[0]] * 2),
           sender=5, expect_revert=True)
    ctx.tx(contract, execute, (*args, signers[::-1], signatures[::-1]), sender=5, expect_revert=True)
    wrong = signatures.copy()
    wrong[0] = ctx.account_signature(3, digest)
    ctx.tx(contract, execute, (*args, signers, wrong), sender=5, expect_revert=True)
    ctx.tx(contract, execute, (1, recipient, PAY + 1, "0x", signers, signatures),
           sender=5, expect_revert=True)
    before = ctx.balance(recipient)
    ctx.tx(contract, execute, (*args, signers, signatures), sender=5)
    ctx.check(ctx.balance(recipient) - before == PAY, "P256 quorum executes the treasury payout")
    ctx.check(ctx.uint(contract, "state(uint256)(uint8)", (1,)) == 4, "proposal executed")
    ctx.tx(contract, execute, (*args, signers, signatures), sender=5, expect_revert=True)

    # Two direct account votes need no off-chain message signatures.
    ctx.tx(contract, "propose(bytes32)", (payload_hash,), sender=3)
    direct = ctx.read(contract, "proposals(uint256)(bytes32,uint48,uint48,uint48,bool)", (2,))
    for sender in ordered:
        ctx.tx(contract, "vote(uint256)", (2,), sender=sender)
        ctx.check(_bool(ctx, contract, "approvedVotes(uint256,address)(bool)",
                        (2, ctx.accounts[sender])), "vote belongs to its account caller")
    ctx.tx(contract, "vote(uint256)", (2,), sender=ordered[0], expect_revert=True)
    ctx.wait_until(int(direct[2]))
    ctx.tx(contract, "vote(uint256)", (2,), sender=3, expect_revert=True)
    empty = ["0x", "0x"]
    ctx.tx(contract, execute, (2, recipient, PAY, "0x", [signers[0]] * 2, empty),
           sender=5, expect_revert=True)
    before = ctx.balance(recipient)
    ctx.tx(contract, execute, (2, recipient, PAY, "0x", signers, empty), sender=5)
    ctx.check(ctx.balance(recipient) - before == PAY, "direct votes execute without message signatures")

    # The next proposal demonstrates mixed votes, and an unexecuted proposal
    # provides a genuine expiry rejection instead of a replay rejection.
    ctx.tx(contract, "propose(bytes32)", (payload_hash,), sender=3)
    mixed_proposal = ctx.read(contract, "proposals(uint256)(bytes32,uint48,uint48,uint48,bool)", (3,))
    mixed_digest = ctx.read(contract, "getVoteHash(uint256)(bytes32)", (3,))[0]
    ctx.tx(contract, "vote(uint256)", (3,), sender=ordered[0])
    mixed = ["0x", ctx.account_signature(ordered[1], mixed_digest)]
    ctx.tx(contract, "propose(bytes32)", (payload_hash,), sender=3)
    expiring = ctx.read(contract, "proposals(uint256)(bytes32,uint48,uint48,uint48,bool)", (4,))
    expired_digest = ctx.read(contract, "getVoteHash(uint256)(bytes32)", (4,))[0]
    expired_signatures = _signatures(ctx, ordered, expired_digest)
    ctx.tx(contract, "engageBrake(uint8)", (1,))
    ctx.tx(contract, "vote(uint256)", (4,), sender=ordered[0], expect_revert=True)
    ctx.wait_until(int(mixed_proposal[2]))
    before = ctx.balance(recipient)
    ctx.tx(contract, execute, (3, recipient, PAY, "0x", signers, mixed), sender=5)
    ctx.check(ctx.balance(recipient) - before == PAY, "mixed quorum executes under the entry brake")
    ctx.wait_until(int(expiring[3]) + 1)
    ctx.tx(contract, execute, (4, recipient, PAY, "0x", signers, expired_signatures),
           sender=5, expect_revert=True)
    ctx.check(ctx.uint(contract, "state(uint256)(uint8)", (4,)) == 5, "unexecuted proposal expired")
    ctx.check(ctx.balance(contract) == 0, "only three authorized payouts left the treasury")
    ctx.notes.append("EIP712 v2 with ERC1271 P256 votes, direct and mixed approvals, timelock, replay and expiry rejection.")


SCENARIOS = [
    {
        "id": "example:" + slug,
        "group": "examples",
        "slug": slug,
        "folder": "examples/" + slug,
        "contracts": ["contracts/src/" + source],
        "run": journey,
    }
    for slug, source, journey in (
        ("multisig", "multisig/SimpleMultisig.sol:SimpleMultisig", multisig),
        ("dao", "dao/SimpleDAO.sol:SimpleDAO", dao),
    )
]
