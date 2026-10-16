"""Template project (eastsea-template/1) packaging and validator regressions.

Runs the real validator against the committed templates/projects tree, then
against tampered copies: each tamper must be refused. Compilation uses the
shared compile gate and caches under ./tmp/.
"""

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("validate_templates", ROOT / "scripts/validate-templates.py")
validate = importlib.util.module_from_spec(SPEC)
sys.modules["validate_templates"] = validate
SPEC.loader.exec_module(validate)
import template_lib  # noqa: E402

PROJECTS = ROOT / "templates" / "projects"
SLUGS = sorted(p.parent.name for p in (ROOT / "examples").glob("*/manifest.json"))


class TemplateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / "tmp").mkdir(exist_ok=True)
        cls.report = validate.validate(PROJECTS, compile_contracts=True)

    def copy(self):
        temp = tempfile.TemporaryDirectory(dir=ROOT / "tmp", prefix="templates-unit-")
        self.addCleanup(temp.cleanup)
        target = Path(temp.name) / "projects"
        shutil.copytree(PROJECTS, target)
        return target

    def refused(self, projects, needle, compile_contracts=False):
        report = validate.validate(projects, compile_contracts=compile_contracts)
        joined = "\n".join(report.errors)
        self.assertTrue(report.errors, "tampered templates were accepted")
        self.assertIn(needle, joined)

    def test_every_example_is_a_valid_template(self):
        self.assertEqual(self.report.errors, [])
        self.assertEqual(sorted(self.report.checked), SLUGS)
        self.assertEqual(len(SLUGS), 17)

    def test_index_lists_templates_neutrally(self):
        index = json.loads((PROJECTS / "index.json").read_text())
        self.assertEqual(index["format"], "eastsea-template-index/1")
        self.assertEqual([t["slug"] for t in index["templates"]], SLUGS)  # alphabetical, no ranking
        for entry in index["templates"]:
            self.assertEqual(set(entry), {"slug", "name", "summary", "category", "tree_sha256"})
            self.assertFalse(template_lib.BANNED_WORDS.search(entry["summary"]), entry["summary"])

    def test_bundle_hash_is_reproducible(self):
        for slug in SLUGS:
            first = template_lib.resolved_bundle_index(PROJECTS / slug, template_lib.TEST_VALUES)
            second = template_lib.resolved_bundle_index(PROJECTS / slug, template_lib.TEST_VALUES)
            self.assertEqual(first, second)

    def test_generated_tree_matches_sources(self):
        result = subprocess.run([sys.executable, str(ROOT / "scripts/gen-templates.py"), "--check"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_hardcoded_web_address_is_refused(self):
        projects = self.copy()
        page = projects / "vending" / "web" / "index.html"
        page.write_text(page.read_text() + "<!-- 0x1234567890123456789012345678901234567890 -->")
        self.refused(projects, "address literal")

    def test_undeclared_placeholder_is_refused(self):
        projects = self.copy()
        runtime = projects / "invoice" / "web" / "manifest.json"
        data = json.loads(runtime.read_text())
        data["contracts"][0]["address"] = "{{address:Elsewhere}}"
        runtime.write_text(json.dumps(data))
        self.refused(projects, "undeclared placeholder")

    def test_changed_web_without_hash_is_refused(self):
        projects = self.copy()
        (projects / "escrow" / "web" / "README.txt").write_text("changed")
        self.refused(projects, "web_sha256")

    def test_tree_hash_mismatch_is_refused(self):
        projects = self.copy()
        source = projects / "token" / "contracts" / "FixedSupplyToken.sol"
        source.write_text(source.read_text() + "\n// edit\n")
        self.refused(projects, "tree_sha256")

    def test_ranking_or_yield_words_are_refused(self):
        projects = self.copy()
        path = projects / "rewards" / "eastsea.json"
        data = json.loads(path.read_text())
        data["x-eastsea-template"]["summary"] = "Stake to earn the best yield"
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        self.refused(projects, "summary")

    def test_missing_interface_entry_is_refused(self):
        projects = self.copy()
        path = projects / "vending" / "eastsea.json"
        data = json.loads(path.read_text())
        data["x-eastsea-template"]["interface"] = [e for e in data["x-eastsea-template"]["interface"] if e["function"] != "refund(uint256)"]
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        self.refused(projects, "refund(uint256)", compile_contracts=True)

    def test_schema_violation_is_refused(self):
        projects = self.copy()
        path = projects / "dao" / "eastsea.json"
        data = json.loads(path.read_text())
        data["x-eastsea-template"]["interface"][0]["moves_funds"] = "maybe"
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        self.refused(projects, "schema")


if __name__ == "__main__":
    unittest.main()
