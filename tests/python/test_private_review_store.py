"""Exercise private profile publication with real files, locks and processes."""
import fcntl
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "ai/marketplace/plugins/my/skills/pr-closeout/scripts/private_review_store.py"


class PrivateReviewStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "store"
        self.root.mkdir(mode=0o700)
        self.scratch = self.base / "scratch"
        self.scratch.mkdir()
        self.directory = self.root / "owner/repo"
        self.target = self.directory / "review.md"

    def args(self, command, *extra, store="owner/repo", file="review.md"):
        return [command, "--root", str(self.root), "--store", store, "--file", file, *extra]

    def run_cli(self, args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], text=True, capture_output=True, check=False)

    def candidate(self, content="new\n", name="candidate.md"):
        path = self.scratch / name
        path.write_text(content)
        return path

    def publish_args(self, candidate, expected="absent", **kwargs):
        return self.args("publish", "--expected", expected, "--candidate-root", str(self.scratch), "--candidate", str(candidate), **kwargs)

    def seed(self, content="old\n"):
        self.directory.mkdir(parents=True)
        self.target.write_text(content)
        return hashlib.sha256(content.encode()).hexdigest()

    def test_absent_snapshot_then_create_private_target(self):
        result = self.run_cli(self.args("snapshot"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)["sha256"])
        result = self.run_cli(self.publish_args(self.candidate()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.target.read_text(), "new\n")
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertNotIn("new\\n", result.stdout)

    def test_missing_final_root_is_created_privately(self):
        self.root.rmdir()
        result = self.run_cli(self.args("snapshot"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertIsNone(json.loads(result.stdout)["sha256"])

    def test_symlinked_or_nondirectory_root_is_refused(self):
        self.root.rmdir()
        outside = self.base / "outside-root"
        outside.mkdir()
        self.root.symlink_to(outside, target_is_directory=True)
        result = self.run_cli(self.args("snapshot"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("unsafe store root", result.stderr)
        self.assertEqual(list(outside.iterdir()), [])
        self.root.unlink()
        self.root.write_text("not a directory")
        result = self.run_cli(self.args("snapshot"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.root.read_text(), "not a directory")

    def test_stale_expected_hash_preserves_latest_file(self):
        digest = self.seed()
        self.target.write_text("another session\n")
        result = self.run_cli(self.publish_args(self.candidate(), digest))
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("stale", result.stderr)
        self.assertEqual(self.target.read_text(), "another session\n")
        self.assertEqual(list(self.directory.glob("*.backup.*")), [])

    def test_publication_preserves_private_backup_and_reports_digests(self):
        digest = self.seed()
        result = self.run_cli(self.publish_args(self.candidate(), digest))
        self.assertEqual(result.returncode, 0, result.stderr)
        details = json.loads(result.stdout)
        self.assertEqual(details["old_sha256"], digest)
        self.assertEqual(details["new_sha256"], hashlib.sha256(b"new\n").hexdigest())
        backups = list(self.directory.glob("*.backup.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "old\n")
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.directory.glob("*.candidate.*")), [])

    def test_matching_candidate_is_noop_without_backup(self):
        digest = self.seed()
        original = self.target.stat()
        result = self.run_cli(self.publish_args(self.candidate("old\n"), digest))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "unchanged")
        self.assertEqual(self.target.stat().st_ino, original.st_ino)
        self.assertEqual(list(self.directory.glob("*.backup.*")), [])

    def test_two_real_writers_cannot_both_replace_same_snapshot(self):
        candidates = [self.candidate("first\n", "first.md"), self.candidate("second\n", "second.md")]
        writers = [subprocess.Popen([sys.executable, str(SCRIPT), *self.publish_args(p)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for p in candidates]
        results = [(p.returncode, out, err) for p in writers for out, err in [p.communicate(timeout=10)]]
        self.assertEqual(sum(code == 0 for code, _, _ in results), 1, results)
        self.assertTrue(all(code in (0, 3, 4) for code, _, _ in results), results)
        self.assertIn(self.target.read_text(), ("first\n", "second\n"))

    def test_busy_lock_refuses_and_release_allows_publication(self):
        self.directory.mkdir(parents=True)
        with (self.directory / ".review-store.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_cli(self.publish_args(self.candidate()))
            self.assertEqual(result.returncode, 3, result.stderr)
            self.assertFalse(self.target.exists())
        result = self.run_cli(self.publish_args(self.candidate()))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_process_exit_releases_lock_without_deleting_lockfile(self):
        self.directory.mkdir(parents=True)
        lock = self.directory / ".review-store.lock"
        child = subprocess.Popen([sys.executable, "-c", "import fcntl,sys; f=open(sys.argv[1], 'w'); fcntl.flock(f, fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.read()", str(lock)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), "ready")
        finally:
            child.communicate(timeout=10)
        self.assertTrue(lock.exists())
        result = self.run_cli(self.publish_args(self.candidate()))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_unsafe_store_and_file_names(self):
        for store in ("../escape", "owner/../escape", "owner", "/absolute/repo", "owner/repo/extra", "./repo"):
            result = self.run_cli(self.args("snapshot", store=store))
            self.assertEqual(result.returncode, 2, (store, result.stderr))
            self.assertIn("unsafe store", result.stderr)
        result = self.run_cli(self.args("snapshot", file="config.md"))
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_rejects_symlinked_store_target_and_lock(self):
        outside = self.base / "outside"
        outside.mkdir()
        (self.root / "owner").symlink_to(outside, target_is_directory=True)
        refused = self.run_cli(self.args("snapshot"))
        self.assertEqual(refused.returncode, 2)
        self.assertIn("unsafe store", refused.stderr)
        (self.root / "owner").unlink()
        self.directory.mkdir(parents=True)
        other = outside / "file"
        other.write_text("untouched")
        for target in (self.target, self.directory / ".review-store.lock"):
            target.unlink(missing_ok=True)
            target.symlink_to(other)
            result = self.run_cli(self.publish_args(self.candidate()))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("unsafe", result.stderr)
            target.unlink()
        self.assertEqual(other.read_text(), "untouched")

    def test_rejects_outside_symlink_and_nonregular_candidates(self):
        outside = self.base / "outside.md"
        outside.write_text("secret")
        link = self.scratch / "linked.md"
        link.symlink_to(outside)
        for path in (outside, link, self.scratch):
            result = self.run_cli(self.publish_args(path))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("candidate", result.stderr)
        self.assertFalse(self.target.exists())

    def test_trusted_scratch_root_can_have_a_symlinked_ancestor(self):
        # macOS commonly spells its temp root through /var -> /private/var.
        candidate = self.candidate()
        alias = self.base / "temp-alias"
        alias.symlink_to(self.base, target_is_directory=True)
        through_alias = alias / "scratch" / candidate.name
        result = self.run_cli(self.publish_args(through_alias))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.target.read_text(), "new\n")

    def test_rejects_malformed_expected_hash(self):
        result = self.run_cli(self.publish_args(self.candidate(), "bogus"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("expected digest", result.stderr)
        self.assertFalse(self.target.exists())

    def test_files_are_independent_and_promotion_keeps_learning(self):
        result = self.run_cli(self.publish_args(self.candidate("observation\n"), file="learnings.md"))
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_cli(self.publish_args(self.candidate("verified rule\n")))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.directory / "learnings.md").read_text(), "observation\n")

    def test_replace_failure_preserves_target_and_cleans_candidate(self):
        self.assertTrue(SCRIPT.is_file(), "private store helper not implemented")
        spec = importlib.util.spec_from_file_location("private_review_store", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        digest = self.seed()
        with patch.object(module.os, "replace", side_effect=OSError("replacement refused")):
            with self.assertRaises(OSError):
                module.main(self.publish_args(self.candidate(), digest))
        self.assertEqual(self.target.read_text(), "old\n")
        self.assertEqual(list(self.directory.glob("*.candidate.*")), [])


if __name__ == "__main__":
    unittest.main()
