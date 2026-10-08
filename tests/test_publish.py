"""Publisher safety, recovery and deterministic output regressions (no network)."""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("publish", ROOT / "scripts/publish.py")
publish = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publish)
SENDER = "0x" + "11" * 20
TARGET = "0x" + "22" * 20
HASH = "0x" + "33" * 32


class Wallet:
    def __init__(self, replies):
        self.replies = iter(replies)
        self.calls = []

    def request(self, method, params=None):
        self.calls.append((method, params))
        result = next(self.replies)
        if isinstance(result, Exception):
            raise result
        return result


class PublisherTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "tmp", prefix="publisher-unit-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def publisher(self, wallet=None):
        p = object.__new__(publish.Publisher)
        p.args = publish.parser().parse_args([])
        p.sender, p.names, p.registry = SENDER, TARGET, TARGET
        p.name, p.chain = "alice", "0x1e61"
        p.output, p.state_file = self.directory, self.directory / "state.json"
        p.state = {"schema": "toolbox-publish-state/1", "chain_id": p.chain, "from": p.sender,
                   "name": p.name, "registry": p.registry, "names": p.names,
                   "transactions": {}, "contracts": {}, "apps": {}}
        p.wallet = wallet or Wallet([HASH])
        p.receipt = lambda _: {"success": True, "contractAddress": TARGET}
        p.app_id = lambda _: HASH
        return p

    def test_dry_run_is_offline_all_seventeen_without_outputs(self):
        with patch.object(publish, "Publisher", side_effect=AssertionError("dry run touched RPC/wallet")), contextlib.redirect_stdout(io.StringIO()) as out:
            result = publish.main(["--dry-run", "--from", SENDER, "--name", "alice", "--output", str(self.directory / "never-written")])
        self.assertEqual(result, 0)
        self.assertEqual(sum(".alice.sea/ (planned)" in line for line in out.getvalue().splitlines()), 17)
        self.assertFalse((self.directory / "never-written").exists())

    def test_invalid_selection_and_zero_sender_are_rejected(self):
        for value in ("token,token", "unknown", "", "all,token"):
            with self.assertRaises(publish.PublishError):
                publish.selected(value)
        with self.assertRaises(publish.PublishError):
            publish.address(publish.ZERO)

    def test_native_pending_and_dropped_are_not_ethereum_statuses(self):
        self.assertIsNone(publish.normalize_receipt({"status": "pending", "pending": True, "waiting": {"kind": "state_price_above_cap"}}))
        with self.assertRaises(publish.TransactionFailed):
            publish.normalize_receipt({"status": "dropped", "reason": {"kind": "state_price_above_cap"}})
        self.assertFalse(publish.normalize_receipt({"receipt": {"success": False}})["success"])
        self.assertTrue(publish.normalize_receipt({"status": "0x1", "contractAddress": TARGET})["success"])

    def test_successful_rerun_checks_receipt_without_resending(self):
        p = self.publisher()
        p.transact("invoice", "0x1234", TARGET)
        p.transact("invoice", "0x1234", TARGET)
        self.assertEqual(len(p.wallet.calls), 1)
        tx = p.wallet.calls[0][1][0]
        self.assertEqual(tx["from"], SENDER)
        self.assertEqual(set(tx), {"from", "to", "data", "value"})
        self.assertEqual(p.state["transactions"]["invoice"]["status"], "finalized")
        with self.assertRaises(publish.PublishError):
            p.transact("invoice", "0x5678", TARGET)

    def test_crash_after_hash_is_recoverable_without_duplicate_send(self):
        p = self.publisher()
        p.receipt = lambda _: (_ for _ in ()).throw(publish.PublishError("pending timeout"))
        with self.assertRaises(publish.PublishError):
            p.transact("deployment", "0x1234")
        saved = json.loads(p.state_file.read_text())
        self.assertEqual(saved["transactions"]["deployment"]["hash"], HASH)
        p.state = saved
        p.receipt = lambda _: {"success": True, "contractAddress": TARGET}
        p.transact("deployment", "0x1234")
        self.assertEqual(len(p.wallet.calls), 1)
        self.assertEqual(p.state["transactions"]["deployment"]["status"], "finalized")

    def test_unknown_wallet_outcome_never_rebroadcasts_automatically(self):
        p = self.publisher(Wallet([publish.PublishError("wallet transport disconnected")]))
        with self.assertRaises(publish.PublishError):
            p.transact("deployment", "0x1234")
        with self.assertRaisesRegex(publish.PublishError, "outcome unknown"):
            p.transact("deployment", "0x1234")
        self.assertEqual(len(p.wallet.calls), 1)

    def test_explicit_wallet_rejection_can_be_retried(self):
        p = self.publisher(Wallet([publish.RpcError({"code": 4001, "message": "Rejected"}), HASH]))
        with self.assertRaises(publish.RpcError):
            p.transact("deployment", "0x1234")
        self.assertNotIn("deployment", p.state["transactions"])
        p.transact("deployment", "0x1234")
        self.assertEqual(len(p.wallet.calls), 2)

    def run_publisher(self, p):
        p.args.apps, p.args.bundle_mode = "token", "stub"
        p.preflight = lambda: None
        p.contracts = lambda _: (p.transact("call:test", "0x1234", TARGET) and {"IslandCoin token": TARGET})
        manifest = {"app_id": HASH, "bundle": {"sha256": HASH}}
        p.build_bundle = lambda *_: (manifest, b"manifest\n", self.directory, b"index")
        p.upload = lambda *_: "stub-content-pending"
        p.register = lambda *_: None
        with contextlib.redirect_stdout(io.StringIO()):
            p.run()

    def test_run_explicit_retry_only_resends_confirmed_failed_transaction(self):
        p = self.publisher()
        p.transact("call:test", "0x1234", TARGET)
        old = p.state["transactions"]["call:test"].copy()
        new_hash = "0x" + "44" * 32
        p.wallet = Wallet([new_hash])
        p.receipt = lambda h: (_ for _ in ()).throw(publish.TransactionFailed("reverted")) if h == HASH else {"success": True}
        p.args.retry_tx = ["call:test"]
        self.run_publisher(p)
        self.assertEqual(p.state["transactions"]["call:test"]["hash"], new_hash)
        self.assertEqual(p.state["failed_transactions"], [{"key": "call:test", **old}])
        self.assertEqual(len(p.wallet.calls), 1)

    def test_run_refuses_to_retry_successful_or_pending_transactions(self):
        for outcome in ({"success": True}, publish.PublishError("receipt pending")):
            p = self.publisher()
            p.transact("call:test", "0x1234", TARGET)
            p.wallet = Wallet([])
            p.args.retry_tx = ["call:test"]
            p.receipt = lambda _, result=outcome: (_ for _ in ()).throw(result) if isinstance(result, Exception) else result
            with self.assertRaises(publish.PublishError):
                self.run_publisher(p)
            self.assertEqual(len(p.wallet.calls), 0)
            self.assertEqual(p.state["transactions"]["call:test"]["hash"], HASH)

    def test_run_recovery_requires_exact_transaction_intent(self):
        for sender, accepted in ((TARGET, False), (SENDER, True)):
            p = self.publisher(Wallet([publish.PublishError("transport disconnected")]))
            with self.assertRaises(publish.PublishError):
                p.transact("call:test", "0x1234", TARGET)
            p.wallet = Wallet([])
            p.args.recover_tx = ["call:test=" + HASH]
            lookup = {"hash": HASH, "from": sender, "to": TARGET, "input": "0x1234", "value": "0x0"}
            p.rpc = type("Lookup", (), {"request": lambda _, *args: lookup})()
            if accepted:
                self.run_publisher(p)
                self.assertEqual(p.state["transactions"]["call:test"]["status"], "finalized")
            else:
                with self.assertRaisesRegex(publish.PublishError, "do not match"):
                    self.run_publisher(p)
                self.assertNotIn("hash", p.state["transactions"]["call:test"])
            self.assertEqual(len(p.wallet.calls), 0)

    def test_missing_publish_api_fails_preflight_before_any_transaction(self):
        p = self.publisher(Wallet([[SENDER], "0x1e61"]))
        p.args.apps, p.args.bundle_mode = "token", "stub"
        p.code = lambda _: "0x6000"
        p.artifact = lambda _: "0x6000"
        child = "0x" + "55" * 32
        empty_string = "0x" + f"{32:064x}" + "0" * 64
        def read(_target, signature, *args):
            if signature == "nodeFor(string)":
                return HASH if args[0] == "alice.sea" else child
            if signature == "ownerOf(bytes32)":
                return "0x" + SENDER[2:].rjust(64, "0") if args[0] == HASH else "0x" + "0" * 64
            if signature == "textOf(bytes32,string)":
                return empty_string
            if signature == "appIdOf(address,string)":
                return HASH
            if signature == "appOf(bytes32)":
                return "0x" + "0" * (64 * 14)
            if signature.startswith("publish("):
                raise publish.RpcError({"code": -32601, "message": "not implemented"})
            return "0x"
        p.read = read
        with self.assertRaisesRegex(publish.PublishError, "API is unavailable"):
            p.preflight()
        self.assertEqual([method for method, _ in p.wallet.calls], ["eth_accounts", "eth_chainId"])
        self.assertFalse(p.state_file.exists())

    def test_canonical_index_orders_paths_and_hashes_exact_bytes(self):
        directory = self.directory / "bundle"
        directory.mkdir()
        (directory / "b.js").write_bytes(b"const b=2;\n")
        (directory / "a.html").write_bytes(b"<p>a</p>\n")
        index = publish.bundle_index(directory)
        expected = {"format": "eastsea-bundle/1", "files": [
            {"path": "a.html", "sha256": hashlib.sha256(b"<p>a</p>\n").hexdigest(), "size": 9},
            {"path": "b.js", "sha256": hashlib.sha256(b"const b=2;\n").hexdigest(), "size": 11}]}
        self.assertEqual(index, json.dumps(expected, separators=(",", ":")).encode())
        first = publish.sha256(index)
        (directory / "a.html").touch()
        self.assertEqual(publish.sha256(publish.bundle_index(directory)), first)
        (directory / "a.html").write_bytes(b"<p>different</p>\n")
        self.assertNotEqual(publish.sha256(publish.bundle_index(directory)), first)

    def test_bundle_rejects_symlinks_and_unsupported_files(self):
        directory = self.directory / "bundle"
        directory.mkdir()
        (directory / "external.js").symlink_to(ROOT / "scripts/publish.py")
        with self.assertRaises(publish.PublishError):
            publish.bundle_index(directory)
        (directory / "external.js").unlink()
        (directory / "unsafe.exe").write_bytes(b"example")
        with self.assertRaises(publish.PublishError):
            publish.bundle_index(directory)

    def test_every_resolved_manifest_is_schema_valid_and_rebuilds_identically(self):
        import jsonschema
        schema = json.loads((ROOT / "templates/publish/schema/eastsea-app-1.json").read_text())
        p = self.publisher()
        for slug in publish.SLUGS:
            template = json.loads((ROOT / "examples" / slug / "manifest.json").read_text())
            deployed = {c["label"]: "0x" + f"{i + 1:040x}" for i, c in enumerate(template["contracts"])}
            manifest, encoded, bundle, index = p.build_bundle(slug, deployed)
            jsonschema.Draft202012Validator(schema).validate(manifest)
            self.assertTrue(manifest["noindex"])
            self.assertEqual(manifest["name_binding"], f"{slug}.alice.sea")
            self.assertEqual(manifest["bundle"]["sha256"], publish.sha256(index))
            runtime = json.loads((bundle / "manifest.json").read_text())
            self.assertEqual(runtime["contracts"], manifest["contracts"])
            self.assertNotIn("../../examples/", (bundle / "index.html").read_text())
            self.assertEqual((bundle / "README.txt").read_bytes(), (ROOT / "examples" / slug / "README.md").read_bytes())
            self.assertEqual(p.build_bundle(slug, deployed)[1], encoded)
            self.assertEqual(p.build_bundle(slug, deployed)[3], index)
            if slug == "amm":
                self.assertEqual(manifest["contracts"][1]["brake"], deployed["AmmFactory"])


if __name__ == "__main__":
    unittest.main()
