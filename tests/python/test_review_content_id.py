"""Review fingerprints must follow content across commits, not just HEAD."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "ai/marketplace/plugins/my/skills/pr-closeout/scripts/review_content_id.py"


class ReviewContentIdTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.paths = self.root / "scope.json"
        self.git("init", "-q")
        (self.repo / "tracked.txt").write_text("original\n")
        self.git("add", "tracked.txt")
        self.commit()
        self.base = self.git("rev-parse", "HEAD").strip()

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.repo), *args], text=True, capture_output=True, check=True)
        return result.stdout

    def commit(self):
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")

    def identity(self, scope, check=True):
        self.paths.write_text(json.dumps(scope))
        result = subprocess.run([sys.executable, str(SCRIPT), "--base", self.base, "--paths", str(self.paths)], cwd=self.repo, text=True, capture_output=True, check=False)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)["content_sha256"]
        return result

    def test_content_changes_without_head_change_invalidate_review(self):
        target = self.repo / "tracked.txt"
        target.write_text("first\n")
        first = self.identity(["tracked.txt"])
        target.write_text("second\n")
        self.assertNotEqual(self.identity(["tracked.txt"]), first)
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.base)

    def test_commit_with_same_reviewed_content_preserves_identity(self):
        (self.repo / "tracked.txt").write_text("changed\n")
        (self.repo / "new.txt").write_text("reviewed new file\n")
        first = self.identity(["tracked.txt", "new.txt"])
        self.git("add", "tracked.txt", "new.txt")
        self.commit()
        self.assertEqual(self.identity(["new.txt", "tracked.txt"]), first)

    def test_unreviewed_new_change_refuses_before_hashing_its_contents(self):
        (self.repo / "tracked.txt").write_text("changed\n")
        (self.repo / "unreviewed.txt").write_text("not authorized as review input")
        result = self.identity(["tracked.txt"], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scope does not match", result.stderr)

    def test_deletions_executable_mode_and_symlink_text_are_distinguished(self):
        target = self.repo / "tracked.txt"
        target.write_text("changed\n")
        ordinary = self.identity(["tracked.txt"])
        target.chmod(0o755)
        self.assertNotEqual(self.identity(["tracked.txt"]), ordinary)
        target.unlink()
        deleted = self.identity(["tracked.txt"])
        outside = self.root / "outside"
        outside.write_text("never read link target")
        target.symlink_to(outside)
        linked = self.identity(["tracked.txt"])
        self.assertNotEqual(linked, deleted)
        outside.write_text("target contents do not affect reviewed link")
        self.assertEqual(self.identity(["tracked.txt"]), linked)

    def test_symlinked_parent_cannot_make_helper_read_external_file(self):
        directory = self.repo / "directory"
        directory.mkdir()
        (directory / "file").write_text("original\n")
        self.git("add", "directory/file")
        self.commit()
        self.base = self.git("rev-parse", "HEAD").strip()
        (directory / "file").unlink()
        directory.rmdir()
        directory.symlink_to(self.root, target_is_directory=True)
        (self.root / "file").write_text("external\n")
        result = self.identity(["directory", "directory/file"], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe symlinked review parent", result.stderr)

    def test_unsafe_scope_is_rejected(self):
        result = self.identity(["../outside"], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe review path", result.stderr)


if __name__ == "__main__":
    unittest.main()
