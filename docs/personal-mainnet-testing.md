# Personal mainnet testing

Every executable toolbox example can be tested using the user's own private
instance. Pipln and the founder provide repository code, not a shared
financial service, signing key, hosted mainnet frontend or treasury. Testnet
may have a shared demonstration with test coins. Mainnet always uses
`personal-test`, a wallet-owned allowlist and fixed admitted-value caps.

## Deploy and open a personal copy

Start with an offline plan (substitute your wallet's account and actual chain
ID; no chain is inferred from an RPC hostname):

```bash
python3 scripts/publish.py --network mainnet --personal-test --dry-run \
  --from "$YOUR_ACCOUNT" --chain-id "$MAINNET_CHAIN_ID" --apps invoice,escrow
```

Build the existing pinned Solidity sources with `make publish-build`. When
you choose to deploy, remove `--dry-run` and add `--rpc "$YOUR_NODE_RPC"`.
The publisher prints a loopback wallet-connection URL. Open it in your wallet
browser, select your own account and approve the transactions there.
Alternatively, `--wallet-rpc` must point to your own loopback wallet/node
provider. Mainnet rejects command-based signing adapters and requires an
explicit chain ID. No private key or seed is accepted or read by this code.
`--names` is required only for the names example's read-only chain dependency.

The wallet first creates its own `PersonalTestDeployer`, then calls
`deploy(bytes,bytes32)` for each copy. Policy is initialized inside the same
CREATE2 transaction as the application constructor. There is no public
activation window, administrator policy reset, fee recipient or new rescue
withdrawal. The factory verifies policy and registers guarded children. AMM
pairs and launchpad tokens inherit the policy; ordinary constructors retain
their existing testnet ABI. Constructor roles belong to the original wallet.

Personal mode defaults to `--bundle-mode local`; `rpc` and `stub` upload
modes are rejected. It never calls AppRegistry, creates `.sea` subdomains,
binds app names, produces upload requests or uploads assets. Outputs must
stay below this repository's `tmp/`, isolated by chain and account. Reuse
the same output to resume pending receipts; changed account, mode, caps,
chain or currency settings cannot reuse an incompatible journal.

Use a loopback server to load the bundle's runtime manifest in an ordinary
browser (opening a `file://` page directly may block `fetch`):

```bash
python3 -m http.server 8000 --bind 127.0.0.1 \
  --directory tmp/publish-personal/YOUR_RUN/bundles
# Open http://127.0.0.1:8000/invoice/ in your own wallet browser.
```

The wallet browser can instead load these assets itself. Do not put the
bundle on shared hosting. The frontend fixes the personal instance addresses
and checks their on-chain mode, owner, caps, authority, factory registration
and allowed account before submitting a write. It also checks account and
chain again after those reads. Signing and B5 fee approval remain in the
user's wallet.

## Policy, quantities and exits

`instanceMode()` reports `personal-test`; `personalTestOwner()`,
`personalTestNativeCap()`, `personalTestTokenCap()` and
`personalTestAuthority()` expose immutable configuration.
`PersonalTestCreated(owner,nativeCap,tokenCap,"personal-test")` records
construction. Initially `personalTestAllowed(owner)` is true and other
user accounts are false. Only the owner calls
`setPersonalTestAccount(address,bool)`; the owner cannot be removed. Add
only other accounts you own, including any account acting as seller,
beneficiary, arbiter or signer. The chain enforces the address allowlist;
it cannot establish that two addresses belong to the same human. Removing
an account also blocks its mutation/exit calls; re-add it to finish those
positions. Existing parties' ownership and signature rules still apply.

Defaults are `10000000000000000` native base units (0.01 at 18 decimals)
and `5000000000000000000` aggregate 18-decimal own test-token units (5).
Use `--personal-native-cap` and `--personal-token-cap` to choose smaller
quantities suitable for your experiment. Token balances are summed in raw
base units across tracked custody assets, including both AMM legs; these
are **not dollar prices**, and mixed decimals are not normalized. Use own
small test tokens, never interpret the default as a five-dollar limit on
an arbitrary token. `--native-symbol` defaults to DBLN on mainnet and SEA
on testnet; `--native-decimals` defaults to 18. Confirm both with your node.
Personal mode has zero protocol/trading fees and zero configured royalties;
network execution, proving and state fees remain payable by the wallet.

Liquidity recipes also need enough integer units for their locked minimum
liquidity: the publisher requires at least 4,000 token base units for AMM
and 10,000 for launchpad. Other recipes remain usable with smaller positive
caps. Invalid combinations are rejected before wallet or output work.

Caps reject admitted ingress using aggregate current holdings and revert
the entire operation on failure. They cannot stop an external ERC-20
contract from transferring unsolicited tokens, or forced native transfers.
Controlled personal test-token transfers additionally check recipients'
custody caps. Exits do not impose an ingress cap, so unsolicited excess
does not freeze legitimate refunds, claims or withdrawals. There is no
new administrator sweep of other people's funds. A cap is an admission
rule, not a universal ceiling against transfers the recipient cannot reject.

## Wallet browser interface

The later aether-node lane's button label is **“Try on mainnet (just for
you)”** (`personal_test.try_mainnet`). The browser should:

1. Select the user's account and exact chain through its EIP-1193 provider.
2. Show the selected example, native/token caps, counterparties as own
   accounts, and the local-only result. Request a publisher plan using an
   argument array, never a shell-interpolated command.
3. Invoke `scripts/publish.py --network mainnet --personal-test --chain-id
   <id> --from <account> --rpc <user-node> --apps <slug> --bundle-mode local`.
   `--dry-run` is the same validated offline planning surface. Do not pass
   company signing keys, `WALLET_COMMAND`, AppRegistry or hosting settings.
4. Connect to the publisher's loopback EIP-1193 bridge or the user's
   loopback wallet RPC. Supported signing-surface requests are
   `eth_accounts`, `eth_chainId` and `eth_sendTransaction`. Provider code
   4001 is a rejection; an uncertain submission is not automatically resent.
5. Read the account-scoped `state.json` once each operation finalizes.
   The publisher writes schema `toolbox-publish-state/1`, with `network`,
   `mode`, `policy`, `native_currency` and `apps[slug]`. A personal app result
   contains `contracts`, `local_entry`, `runtime_manifest`,
   `bundle_status: "local-only"` and `registered: false`. No public `sea://`
   entry is supplied. Load only that run's local bundle and verify its hash.

The runtime manifest retains schema `toolbox-runtime/1` and carries:

```json
{
  "noindex": true,
  "x-toolbox-mode": "personal-test",
  "x-toolbox-network": "mainnet",
  "x-toolbox-local-only": true,
  "x-toolbox-personal-policy": {
    "schema": "eastsea.personal-test/1",
    "owner": "0xUSER_ACCOUNT",
    "authority": "0xUSER_PERSONAL_DEPLOYER",
    "native_cap": "10000000000000000",
    "token_cap": "5000000000000000000",
    "initial_allowlist": ["0xUSER_ACCOUNT"],
    "protocol_fee_bps": 0
  },
  "x-toolbox-read-only-contracts": []
}
```

The address strings above are explanatory placeholders, not valid manifests.
Contract lists, actual addresses and chain/currency extensions are written
by the publisher. The names example declares its canonical names service
in the read-only list. That dependency is not a personal financial instance.
Personal deployments never change that service's state.

Explorers, search, recommendations and app discovery must skip any instance
whose on-chain `instanceMode()` is `personal-test`, and skip local manifests
with this mode or `noindex: true`. Keep it visible only in the owner's
private instance view. A self-reported marker is not proof of code safety;
check the user's factory registration and source-verified runtime too.
This repository supplies the marker and exclusion contract; the separate
aether-node lane must implement discovery filtering and the button flow.

## Native contracts

Four native products are executable: claims, streams, escrow and swap-pool.
TokenProbe is an additional guarded token diagnostic. The same atomic
factory supports their existing creation bytecode. The 17-app publisher
does not automatically select native tokens, arbiters or spec hashes.

| Native target | Existing constructor arguments |
|---|---|
| ClaimCampaigns | `(address token, bytes32 brakeDocSha256)` |
| GrantLedger | `(address token, bytes32 brakeDocSha256)` |
| EscrowBook | `(address asset, address arbiter, uint64 rulingDuration, bytes32 specHash, bytes32 brakeDocSha256)` |
| SwapPool | `(address tokenA, address tokenB, uint256 feeBps, bytes32 brakeDocSha256)` |
| TokenProbe | `(address owner)` |

Build/test locally with `cd native && forge test`. ABI-encode the unchanged
constructor with local `cast abi-encode`, append it to creation bytecode,
then ABI-encode `deploy(bytes,bytes32)` for the user's factory. Send the
result using the user's provider:

```js
await provider.request({ method: 'eth_sendTransaction', params: [{
  from: userAccount, to: personalDeployer,
  data: encodedDeployCall, value: '0x0'
}] });
```

Predict the address with `predict(bytes,bytes32)`, verify the finalized
receipt/code/policy and approve/fund only that own instance through the
wallet. Personal mode fixes swap fees to zero. Do not use `cast send` with
a company key or a shared service. Lending and yield-vault are still
design-only; their READMEs explicitly require this policy for future code.

Personal TokenProbe caps the probe and its guarded sink together. Recovery
returns only recorded admitted inventory and leaves unrelated deposits;
unmeasurable balances fail closed. Token rebases or issuer manipulation can
invalidate provenance assumptions; positive rebase surplus does not grant
the probe new withdrawal authority.

## Originals and clones

`originals/` source pins and fidelity fixtures remain byte-for-byte
unchanged. `clones/` currently contains planned designs, not executable
publisher examples. The personal deployer rejects unguarded original
creation bytecode atomically, without leaving a public instance. It never
patches originals to claim fidelity.

A future wrapper must preserve upstream code while guarding the complete
call graph, correct constructor/immutable state, assets, fees and children.
A relay around a publicly callable original is insufficient: the original
can be called directly. WETH9, Multicall3, Uniswap V2 and Permit2 remain
fidelity controls until a reviewed guarded adapter meets those conditions.
The existing BUSL mainnet exclusion remains in force. No bare original or
unfinished design is silently treated as a protected personal example.

Stable English keys live in `docs/i18n/personal-test.en.json`. This branch
has not integrated `codex/redesign-i18n`; translations can use those keys
when its five-language pack lands.
