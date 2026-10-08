"""Personal mainnet safety and offline publisher regressions (no deployments)."""

import contextlib
import hashlib
import importlib.util
import io
import json
import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("publish_mainnet", ROOT / "scripts/publish.py")
publish = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publish)
SENDER = "0x" + "11" * 20
TARGET = "0x" + "22" * 20
FACTORY = "0x" + "44" * 20
CHAIN = "0x30a"


def abi_word(value):
    return "0x" + f"{int(value, 16) if isinstance(value, str) else value:064x}"


def abi_text(value):
    raw = value.encode()
    return "0x" + f"{32:064x}{len(raw):064x}" + raw.hex().ljust(((len(raw) + 31) // 32) * 64, "0")


class OfflineRpc:
    def __init__(self, chain=CHAIN):
        self.chain, self.calls = chain, []

    def request(self, method, params=None):
        self.calls.append((method, params))
        if method == "eth_chainId":
            return self.chain
        raise AssertionError("Unexpected network operation " + method)


class OfflineWallet:
    def __init__(self):
        self.calls, self.sends = [], 0

    def request(self, method, params=None):
        self.calls.append((method, params))
        if method == "eth_accounts":
            return [SENDER]
        if method == "eth_chainId":
            return CHAIN
        if method == "eth_sendTransaction":
            self.sends += 1
            return "0x" + f"{self.sends:064x}"
        raise AssertionError("Unexpected wallet operation " + method)


class OfflineAbi:
    """Opaque deterministic ABI stand-in: never compiles, signs, or uses cast."""
    def __init__(self):
        self.calls = []

    def encode(self, signature, *args):
        self.calls.append((signature, args))
        return "0x" + publish.canonical([signature, *args]).hex()

    call = encode

    def keccak(self, data):
        return "0x" + hashlib.sha256(data).hexdigest()


class MainnetGuardTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "tmp", prefix="mainnet-publisher-")
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / "must-not-exist"

    def legacy_args(self, **changes):
        # Inject the new policy fields so this catches the old publisher's
        # permissive dry-run path, rather than only its missing CLI arguments.
        args = publish.parser().parse_args(["--dry-run", "--from", SENDER,
                                            "--output", str(self.output)])
        args.network = "mainnet"
        args.personal_test = True
        args.chain_id = 778
        args.personal_native_cap = 10**16
        args.personal_token_cap = 5 * 10**18
        for key, value in changes.items():
            setattr(args, key, value)
        return args

    def refused_offline(self, **changes):
        args = self.legacy_args(**changes)
        parser = publish.parser()
        with patch.object(parser, "parse_args", return_value=args), \
             patch.object(publish, "parser", return_value=parser), \
             patch.object(publish, "Publisher", side_effect=AssertionError("touched wallet/RPC")), \
             contextlib.redirect_stdout(io.StringIO()), \
             contextlib.redirect_stderr(io.StringIO()) as errors:
            result = publish.main([])
        self.assertFalse(self.output.exists())
        return result, errors.getvalue()

    def test_mainnet_refuses_without_personal_test_before_dry_run(self):
        result, error = self.refused_offline(personal_test=False)
        self.assertEqual(result, 1)
        self.assertIn("personal-test", error)

    def test_mainnet_refuses_implicit_chain_before_dry_run(self):
        result, error = self.refused_offline(chain_id=None)
        self.assertEqual(result, 1)
        self.assertIn("chain-id", error)

    def test_mainnet_refuses_wallet_command_before_dry_run(self):
        result, error = self.refused_offline(wallet_command="external-signer")
        self.assertEqual(result, 1)
        self.assertIn("wallet-command", error)

    def invoke(self, *extra):
        with patch.object(publish, "Publisher", side_effect=AssertionError("dry-run touched wallet/RPC")), \
             contextlib.redirect_stdout(io.StringIO()) as out, \
             contextlib.redirect_stderr(io.StringIO()) as errors:
            result = publish.main(["--network", "mainnet", "--personal-test", "--chain-id", "778",
                                   "--dry-run", "--from", SENDER, "--output", str(self.output), *extra])
        self.assertFalse(self.output.exists())
        return result, out.getvalue(), errors.getvalue()

    def test_mainnet_personal_dry_run_is_offline_and_local_only(self):
        result, output, error = self.invoke()
        self.assertEqual((result, error), (0, ""))
        self.assertEqual(output.count("local-only (planned)"), 17)
        self.assertIn('"native_cap":"10000000000000000"', output)
        self.assertIn('"token_cap":"5000000000000000000"', output)
        self.assertIn('"initial_allowlist":["' + SENDER + '"]', output)
        self.assertNotIn("sea://", output)

    def test_personal_rejects_uploads_invalid_caps_and_shared_wallet_rpc_offline(self):
        for arguments in (("--bundle-mode", "rpc"), ("--bundle-mode", "stub"),
                          ("--personal-native-cap", "0"), ("--personal-token-cap", "-1"),
                          ("--personal-token-cap", str(2**256)), ("--chain-id", "0"),
                          ("--wallet-rpc", "https://wallet.invalid"),
                          ("--native-decimals", "78"), ("--native-symbol", "INVALID SYMBOL")):
            with self.subTest(arguments=arguments):
                result, _, error = self.invoke(*arguments)
                self.assertEqual(result, 1)
                self.assertTrue(error)

    def test_personal_accepts_users_loopback_node_wallet_offline(self):
        result, _, error = self.invoke("--wallet-rpc", "http://127.0.0.1:8545", "--apps", "token")
        self.assertEqual((result, error), (0, ""))

    def test_launchpad_minimum_cap_is_distinct_from_amm_and_checked_offline(self):
        result, _, error = self.invoke("--apps", "launchpad", "--personal-token-cap", "4000")
        self.assertEqual(result, 1)
        self.assertIn("10000", error)
        result, _, error = self.invoke("--apps", "launchpad", "--personal-token-cap", "10000")
        self.assertEqual((result, error), (0, ""))
        result, _, error = self.invoke("--apps", "amm", "--personal-token-cap", "4000")
        self.assertEqual((result, error), (0, ""))


class PersonalDeploymentTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "tmp", prefix="personal-deployment-")
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / "instance"
        self.args = publish.parser().parse_args(["--network", "mainnet", "--personal-test", "--chain-id", "778",
                                                "--from", SENDER, "--rpc", "http://127.0.0.1:8545", "--apps", "token",
                                                "--output", str(self.output)])
        self.rpc, self.wallet, self.abi = OfflineRpc(), OfflineWallet(), OfflineAbi()
        self.p = publish.Publisher(self.args, self.rpc, self.wallet, self.abi)
        self.overrides = {}
        self.p.read = self.policy_read
        self.p.code = lambda _target: "0x6000"
        self.p.artifact = lambda _contract: "0x6000"
        self.p.receipt = lambda _hash: {"success": True, "contractAddress": FACTORY}

    def policy_read(self, target, signature, *args):
        if signature in self.overrides:
            return self.overrides[signature]
        result = {"instanceMode()": abi_text("personal-test"), "personalTestOwner()": abi_word(SENDER),
                  "personalTestNativeCap()": abi_word(self.args.personal_native_cap),
                  "personalTestTokenCap()": abi_word(self.args.personal_token_cap),
                  "personalTestAllowed(address)": abi_word(1), "personalTestAuthority()": abi_word(FACTORY),
                  "isPersonalTestInstance(address)": abi_word(1), "predict(bytes,bytes32)": abi_word(TARGET)}
        return result[signature]

    def sentinel(self):
        directory = Path(self.temp.name) / "external-sentinel"
        directory.mkdir()
        for name in ("index.html", "manifest.json", "icon.png", "README.txt", "GAS.txt", "SECURITY.txt"):
            (directory / name).write_bytes(("original sentinel " + name).encode())
        return directory

    def snapshot(self, directory):
        return {file.relative_to(directory).as_posix(): file.read_bytes() for file in directory.rglob("*") if file.is_file()}

    def test_output_directory_symlink_is_rejected_without_following_it(self):
        sentinel = self.sentinel()
        before = self.snapshot(sentinel)
        linked = Path(self.temp.name) / "linked-output"
        linked.symlink_to(sentinel, target_is_directory=True)
        self.args.output = str(linked)
        with self.assertRaisesRegex(publish.PublishError, "symlink"):
            publish.Publisher(self.args, self.rpc, self.wallet, self.abi)
        self.assertEqual(self.snapshot(sentinel), before)
        self.assertEqual(self.wallet.calls, [])

    def test_bundle_directory_symlink_cannot_overwrite_external_files(self):
        sentinel = self.sentinel()
        before = self.snapshot(sentinel)
        bundles = self.output / "bundles"
        bundles.mkdir()
        (bundles / "token").symlink_to(sentinel, target_is_directory=True)
        with self.assertRaisesRegex(publish.PublishError, "symlink"):
            self.p.build_bundle("token", {"IslandCoin token": TARGET})
        self.assertEqual(self.snapshot(sentinel), before)
        self.assertFalse((self.output / "examples").exists())
        self.assertEqual(self.wallet.calls, [])

    def test_bundle_parent_symlink_is_rejected_before_any_wallet_transaction(self):
        sentinel = self.sentinel()
        before = self.snapshot(sentinel)
        (self.output / "bundles").symlink_to(sentinel, target_is_directory=True)
        with self.assertRaisesRegex(publish.PublishError, "symlink"):
            self.p.run()
        self.assertEqual(self.snapshot(sentinel), before)
        self.assertFalse((self.output / ".publisher.lock").exists())
        self.assertEqual(self.wallet.calls, [])

    def test_manifest_pending_symlink_is_rejected_before_bundle_writes(self):
        sentinel = self.sentinel()
        before = self.snapshot(sentinel)
        example = self.output / "examples/token"
        example.mkdir(parents=True)
        (example / "manifest.json.pending").symlink_to(sentinel / "manifest.json")
        with self.assertRaisesRegex(publish.PublishError, "symlink"):
            self.p.build_bundle("token", {"IslandCoin token": TARGET})
        self.assertEqual(self.snapshot(sentinel), before)
        self.assertFalse((self.output / "bundles").exists())
        self.assertFalse((example / "manifest.json").exists())

    def test_state_symlink_is_rejected_before_reading_external_json(self):
        sentinel = self.sentinel()
        before = self.snapshot(sentinel)
        self.p.state_file.symlink_to(sentinel / "manifest.json")  # Deliberately not valid JSON.
        with self.assertRaisesRegex(publish.PublishError, "symlink"):
            publish.Publisher(self.args, self.rpc, self.wallet, self.abi)
        self.assertEqual(self.snapshot(sentinel), before)
        self.assertEqual(self.wallet.calls, [])

    def test_state_pending_symlink_and_namespace_escape_never_write(self):
        sentinel = self.sentinel()
        before = self.snapshot(sentinel)
        self.p.state_file.with_suffix(".json.pending").symlink_to(sentinel / "manifest.json")
        with self.assertRaisesRegex(publish.PublishError, "symlink"):
            self.p.save()
        with self.assertRaisesRegex(publish.PublishError, "escapes"):
            publish.atomic_json(sentinel / "manifest.json", {"unsafe": True}, self.output)
        self.assertEqual(self.snapshot(sentinel), before)
        self.assertFalse(self.p.state_file.exists())

    def test_testnet_upload_and_register_helpers_reject_output_symlinks(self):
        sentinel = self.sentinel()
        before = self.snapshot(sentinel)
        self.args.personal_test, self.args.network = False, "testnet"
        uploads = self.output / "uploads"
        uploads.mkdir()
        (uploads / "token.json.pending").symlink_to(sentinel / "manifest.json")
        with self.assertRaisesRegex(publish.PublishError, "symlink"):
            self.p.upload("token", {}, b"", self.output, b"")
        with self.assertRaisesRegex(publish.PublishError, "symlink"):
            self.p.register("token", {}, b"")
        self.assertEqual(self.snapshot(sentinel), before)
        self.assertFalse((uploads / "token.json").exists())
        self.assertEqual(self.wallet.calls, [])

    def test_wrong_live_chain_is_rejected_before_output_or_wallet(self):
        output = Path(self.temp.name) / "wrong-chain"
        self.args.output = str(output)
        with self.assertRaisesRegex(publish.PublishError, "differs"):
            publish.Publisher(self.args, OfflineRpc("0x999"), self.wallet, self.abi)
        self.assertFalse(output.exists())
        self.assertEqual(self.wallet.calls, [])

    def test_resume_refuses_changed_caps_owner_mode_network_and_currency(self):
        self.p.save()
        original = json.loads(self.p.state_file.read_text())
        for key, value in (("policy", {**original["policy"], "native_cap": "1"}),
                           ("from", TARGET), ("mode", "testnet-demo"), ("network", "testnet"),
                           ("native_currency", {"symbol": "OTHER", "decimals": 6})):
            with self.subTest(key=key):
                self.p.state_file.write_text(json.dumps({**original, key: value}))
                with self.assertRaisesRegex(publish.PublishError, "different"):
                    publish.Publisher(self.args, self.rpc, self.wallet, self.abi)
        self.assertEqual(self.wallet.calls, [])

    def test_every_personal_getter_and_registry_is_verified(self):
        for signature, response in (("instanceMode()", abi_text("testnet")),
                                    ("personalTestOwner()", abi_word(TARGET)),
                                    ("personalTestNativeCap()", abi_word(1)),
                                    ("personalTestTokenCap()", abi_word(1)),
                                    ("personalTestAllowed(address)", abi_word(0)),
                                    ("personalTestAuthority()", abi_word(TARGET)),
                                    ("isPersonalTestInstance(address)", abi_word(0))):
            with self.subTest(signature=signature):
                self.overrides = {signature: response}
                with self.assertRaises(publish.PublishError):
                    self.p.verify_personal(TARGET, FACTORY)
        self.overrides = {}
        self.p.verify_personal(TARGET, FACTORY)

    def test_create2_factory_call_uses_prediction_and_resumes_without_resending(self):
        with contextlib.redirect_stderr(io.StringIO()):
            deployed = self.p.contracts("token")
        self.assertEqual(deployed, {"IslandCoin token": TARGET})
        sends = [params[0] for method, params in self.wallet.calls if method == "eth_sendTransaction"]
        self.assertEqual(len(sends), 2)
        self.assertNotIn("to", sends[0])  # Only the owned policy deployer uses raw CREATE.
        self.assertEqual(sends[1]["to"], FACTORY)
        self.assertTrue(any(signature == "deploy(bytes,bytes32)" for signature, _ in self.abi.calls))
        self.assertEqual(self.p.state["contracts"]["token.FixedSupplyToken"]["authority"], FACTORY)
        self.assertEqual(self.p.state["contracts"]["token.FixedSupplyToken"]["address"], TARGET)
        self.p.contracts("token")
        self.assertEqual(self.wallet.sends, 2)
        self.overrides = {"personalTestOwner()": abi_word(TARGET)}
        with self.assertRaises(publish.PublishError):
            self.p.contracts("token")
        self.assertEqual(self.wallet.sends, 2)

    def test_unguarded_creation_and_over_cap_transaction_never_reach_wallet(self):
        for key, value in (("deploy:unguarded", 0), ("deploy:personal.deployer", self.args.personal_native_cap + 1)):
            with self.subTest(key=key):
                with self.assertRaises(publish.PublishError):
                    self.p.transact(key, "0x6000", value=value)
        self.assertEqual(self.wallet.calls, [])
        self.assertFalse(self.p.state_file.exists())

    def test_personal_run_keeps_every_bundle_local_and_never_registers_or_uploads(self):
        self.p.preflight = lambda: None
        self.p.contracts = lambda _slug: {"IslandCoin token": TARGET}
        self.p.state["contracts"]["personal.deployer"] = {"address": FACTORY}
        self.p.upload = lambda *_args: self.fail("mainnet uploaded a bundle")
        self.p.register = lambda *_args: self.fail("mainnet published an app/name")
        with contextlib.redirect_stdout(io.StringIO()):
            self.p.run()
        app = self.p.state["apps"]["token"]
        self.assertEqual(app["bundle_status"], "local-only")
        self.assertFalse(app["registered"])
        self.assertNotIn("sea_url", app)
        manifest = json.loads((self.output / "examples/token/manifest.json").read_text())
        runtime = json.loads((self.output / "bundles/token/manifest.json").read_text())
        self.assertTrue(manifest["noindex"])
        self.assertNotIn("name_binding", manifest)
        self.assertEqual(runtime["x-toolbox-personal-policy"]["owner"], SENDER)
        self.assertEqual(runtime["x-toolbox-personal-policy"]["authority"], FACTORY)
        self.assertEqual(runtime["x-toolbox-native-currency"], {"symbol": "DBLN", "decimals": 18})
        self.assertEqual(runtime["x-toolbox-mode"], "personal-test")
        self.assertTrue(runtime["x-toolbox-local-only"])
        self.assertFalse((self.output / "uploads").exists())
        self.assertEqual(self.wallet.calls, [])

    def test_publication_helpers_refuse_personal_instances(self):
        with self.assertRaises(publish.PublishError):
            self.p.upload("token", {}, b"", self.output, b"")
        with self.assertRaises(publish.PublishError):
            self.p.register("token", {}, b"")
        self.assertEqual(self.rpc.calls, [("eth_chainId", None)])

    def test_personal_recipes_use_bounded_values_and_zero_fees(self):
        calls = []
        def deploy(key, contract, signature, *args):
            calls.append((key, contract, signature, args))
            return TARGET
        self.p.deploy = deploy
        for slug in ("token", "nft", "launchpad", "crowdfund", "subscription", "vending", "raffle", "airdrop", "names"):
            self.p.contracts(slug)
        supply = next(args[2] for _, contract, _, args in calls if contract == "FixedSupplyToken")
        self.assertGreater(supply, 0)
        self.assertLessEqual(supply, self.args.personal_token_cap)
        nft = next(args for _, contract, _, args in calls if contract == "OnchainNFT")
        self.assertEqual(nft[3], 0)
        launch = next(args[-1] for _, contract, _, args in calls if contract == "BondingLaunchpad")
        config = launch.strip("()").split(",")
        self.assertLessEqual(int(config[2]), self.args.personal_token_cap)
        self.assertEqual(config[6:10], ["0", "0", "0", "0"])
        for _, contract, _, args in calls:
            if contract in {"AllOrNothingCrowdfund", "SubscriptionManager", "AgentVending", "CommitRevealRaffle", "NameGatedDrop"}:
                self.assertLessEqual(args[2], self.args.personal_native_cap)
        self.assertLessEqual(int(self.p.state["airdrop_test_claim"]["amount"]), self.args.personal_native_cap)

    def test_personal_vesting_allowlist_and_approval_use_exact_create2_target(self):
        deployments, transactions = [], []
        self.p.deploy = lambda key, contract, signature, *args: (deployments.append((key, contract, signature, args)) or TARGET)
        self.p.personal_prediction = lambda key, data: (FACTORY, "0x" + "99" * 32, TARGET)
        self.p.transact = lambda key, data, target=None, value=0: transactions.append((key, data, target))
        result = self.p.contracts("lock")
        self.assertEqual(result["LinearVesting"], TARGET)
        self.assertEqual([key for key, _, _ in transactions], ["lock.allow:" + TARGET, "lock.approve:" + TARGET])
        requests = [json.loads(bytes.fromhex(data[2:])) for _, data, _ in transactions]
        self.assertEqual(requests[0], ["setPersonalTestAccount(address,bool)", TARGET, "true"])
        self.assertEqual(requests[1][0:2], ["approve(address,uint256)", TARGET])
        self.assertGreater(requests[1][2], 0)
        self.assertLessEqual(requests[1][2], self.args.personal_token_cap)
        self.assertEqual([target for _, _, target in transactions], [TARGET, TARGET])

    def test_smallest_launchpad_recipe_can_graduate_within_token_cap(self):
        self.args.personal_token_cap = 10000
        calls = []
        self.p.deploy = lambda key, contract, signature, *args: (calls.append((contract, args)) or TARGET)
        self.p.contracts("launchpad")
        config = next(args[-1] for contract, args in calls if contract == "BondingLaunchpad").strip("()").split(",")
        supply, quote_floor, token_floor, target = map(int, config[2:6])
        quote_supply = next(args[2] for contract, args in calls if contract == "FixedSupplyToken")
        # One zero-fee purchase at the graduation target follows the curve's
        # constant-product quote. AMM mint requires sqrt(seed0*seed1)>1000.
        purchased = (supply + token_floor) * target // (quote_floor + target)
        token_seed = supply - purchased
        self.assertGreater(math.isqrt(token_seed * target), 1000)
        self.assertLessEqual(target, quote_supply)
        self.assertLessEqual(token_seed + target, self.args.personal_token_cap)
        self.assertLessEqual(supply, self.args.personal_token_cap)
        self.assertLessEqual(quote_supply, self.args.personal_token_cap)

    def test_unit_caps_remain_viable_for_non_liquidity_recipes(self):
        self.args.personal_native_cap = self.args.personal_token_cap = 1
        calls = []
        self.p.deploy = lambda key, contract, signature, *args: (calls.append((contract, args)) or TARGET)
        for slug in ("token", "dao", "crowdfund", "subscription", "vending", "raffle", "names", "airdrop"):
            self.p.contracts(slug)
        for contract, args in calls:
            if contract == "FixedSupplyToken":
                self.assertEqual(args[2], 1)
            if contract in {"SimpleDAO", "AllOrNothingCrowdfund", "SubscriptionManager", "AgentVending", "CommitRevealRaffle", "NameGatedDrop"}:
                self.assertEqual(args[2], 1)
        self.assertEqual(self.p.state["airdrop_test_claim"]["amount"], "1")


if __name__ == "__main__":
    unittest.main()
