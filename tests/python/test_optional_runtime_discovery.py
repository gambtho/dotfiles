"""Optional Node exercises skip unless explicitly selected, then fail closed."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CASES = [
    ("pi_lsp_readiness.test.mjs", "PI_TEST_LSP_FIXTURE"),
    ("pi_recap_runtime.test.mjs", "PI_TEST_RECAP_ROOT"),
]


class OptionalRuntimeDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.node = shutil.which("node")
        self.assertIsNotNone(self.node, "Node is required by the runtime fixtures")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.env = {"HOME": self.temp.name, "PATH": os.path.dirname(self.node) + os.pathsep + os.defpath,
                    "NODE_DISABLE_COMPILE_CACHE": "1"}

    def run_node(self, filename, **extra):
        return subprocess.run([self.node, "--test", "--test-reporter=tap", str(ROOT / "tests" / filename)],
                              cwd=self.temp.name, env={**self.env, **extra}, text=True, capture_output=True, check=False)

    def test_no_selected_fixture_is_explicitly_skipped(self):
        for filename, _selector in CASES:
            with self.subTest(filename=filename):
                result = self.run_node(filename)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("# SKIP", result.stdout)

    def test_selected_fixture_with_missing_roots_still_fails(self):
        for filename, selector in CASES:
            with self.subTest(filename=filename):
                result = self.run_node(filename, **{selector: self.temp.name})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Select", result.stdout + result.stderr)
                self.assertNotIn("# SKIP", result.stdout)


if __name__ == "__main__":
    unittest.main()
