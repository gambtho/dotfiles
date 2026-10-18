"""Lifecycle behavior against real local Git histories, not source-text checks."""
import importlib.util
import json
import os
import sys
from unittest.mock import patch
from agent_knowledge_fixture import CONTROLLER, KnowledgeFixture


class KnowledgeLifecycleTests(KnowledgeFixture):
    def test_unconfigured_does_not_contact_network_or_create_config(self):
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "skipped")
        self.assertFalse(self.config.exists())
        self.assertFalse(self.log.exists())

    def test_ensure_twice_preserves_head_and_regular_private_root(self):
        self.setup_store()
        before = self.head()
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.head(), before)
        self.assertFalse(self.root.is_symlink())
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertNotEqual(self.git("-C", str(self.root), "rev-parse", "--git-dir"), self.git("-C", str(self.root), "rev-parse", "--git-common-dir"))

    def test_existing_raw_root_requires_explicit_adoption(self):
        self.root.mkdir()
        (self.root / "local.md").write_text("keep\n")
        result = self.cli(configure=True)
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertIn("adopt", result.stdout)
        self.assertEqual((self.root / "local.md").read_text(), "keep\n")
        self.assertFalse((self.root / ".git").exists())

    def test_primary_checkout_notice_requests_manual_migration_not_adopt_loop(self):
        self.setup_store()
        self.git("--git-dir=" + str(self.bare), "worktree", "move", str(self.root), str(self.base / "retained-worktree"))
        self.git("clone", "--no-hardlinks", str(self.remote), str(self.root))
        self.git("-C", str(self.root), "remote", "set-url", "origin", "https://github.com/fixture/knowledge.git")
        before = self.head()
        for action in ("ensure", "check", "adopt"):
            with self.subTest(action=action):
                result = self.cli(action)
                self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
                self.assertIn("primary checkout", result.stdout)
                self.assertNotIn("run make agent-knowledge-adopt", result.stdout)
                self.assertEqual(self.head(), before)

    def test_missing_registered_worktree_requests_manual_repair_without_pruning(self):
        self.setup_store()
        retained = self.base / "temporarily-offline"
        self.root.rename(retained)
        before = self.git("--git-dir=" + str(self.bare), "worktree", "list", "--porcelain")
        for action in ("ensure", "adopt"):
            with self.subTest(action=action):
                result = self.cli(action)
                self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
                self.assertIn("registration", result.stdout)
                self.assertNotIn("run make agent-knowledge-adopt", result.stdout)
                self.assertFalse(self.root.exists())
                self.assertEqual(self.git("--git-dir=" + str(self.bare), "worktree", "list", "--porcelain"), before)
                self.assertEqual((retained / "owner/repo/review.md").read_text(), "old\n")
        result = self.cli("check")
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertIn("make agent-knowledge", result.stdout)
        self.assertNotIn("agent-knowledge-adopt", result.stdout)

    def test_remote_ahead_ensure_notifies_without_checkout(self):
        self.setup_store()
        old = self.head()
        self.advance()
        result = self.cli()
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertIn("sync", result.stdout)
        self.assertEqual(self.head(), old)
        self.assertFalse((self.root / "other").exists())

    def test_explicit_sync_fast_forwards_clean_root(self):
        self.setup_store()
        self.advance()
        result = self.cli("sync")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((self.root / "other/repo/review.md").read_text(), "remote change\n")

    def test_check_is_read_only_and_does_not_create_a_lock(self):
        result = self.cli("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.config.exists())
        self.setup_store()
        files = {str(p.relative_to(self.home)): (p.stat().st_size, p.stat().st_mtime_ns) for p in self.home.rglob("*") if p.is_file()}
        result = self.cli("check")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        after = {str(p.relative_to(self.home)): (p.stat().st_size, p.stat().st_mtime_ns) for p in self.home.rglob("*") if p.is_file()}
        self.assertEqual(after, files)

    def test_public_repository_and_config_retarget_are_refused(self):
        data = json.loads(self.meta.read_text())
        data["private"] = False
        self.meta.write_text(json.dumps(data))
        result = self.cli(configure=True)
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertFalse(self.root.exists())
        data["private"] = True
        self.meta.write_text(json.dumps(data))
        self.setup_store()
        before = self.config.read_bytes()
        self.env["DOTFILES_AGENT_KNOWLEDGE_REPO"] = "elsewhere/knowledge"
        result = self.cli()
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertEqual(self.config.read_bytes(), before)

    def legacy(self, text="old\n"):
        (self.root / "owner/repo").mkdir(parents=True)
        (self.root / "owner/repo/review.md").write_text(text)
        result = self.cli(configure=True)
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)

    def module(self):
        spec = importlib.util.spec_from_file_location("knowledge_lifecycle_test", CONTROLLER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_adoption_archives_legacy_and_reuses_single_occupied_worktree(self):
        self.legacy()
        cache = self.bare.parent / "agent-knowledge"
        self.git("--git-dir=" + str(self.bare), "worktree", "add", str(cache), "main")
        (self.root / "notes.local").write_text("keep locally\n")
        result = self.cli("adopt")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        from pathlib import Path
        archive = Path(json.loads(result.stdout)["archive"])
        self.assertEqual((archive / "notes.local").read_text(), "keep locally\n")
        self.assertEqual(archive.stat().st_mode & 0o777, 0o700)
        self.assertFalse(cache.exists())
        registration = self.git("--git-dir=" + str(self.bare), "worktree", "list", "--porcelain")
        self.assertEqual(registration.count("branch refs/heads/main"), 1)
        self.assertIn(str(self.root), registration)
        self.assertEqual(self.cli("adopt").returncode, 0)

    def test_existing_staging_worktree_reuses_trusted_data_parent_alias(self):
        self.bare.parent.mkdir(parents=True)
        alias = self.base / "data-alias"
        alias.symlink_to(self.bare.parent, target_is_directory=True)
        self.env["XDG_DATA_HOME"] = str(alias)
        self.legacy()
        self.assertEqual(self.cli(configure=True).returncode, 5)
        cache = self.bare.parent / "agent-knowledge"
        self.git("--git-dir=" + str(self.bare), "worktree", "add", str(cache), "main")
        result = self.cli("adopt")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((self.root / "owner/repo/review.md").read_text(), "old\n")
        self.assertFalse(cache.exists())

    def test_adoption_compares_raw_utf8_crlf_bytes_without_normalizing(self):
        self.advance("owner/repo/review.md", "caf\u00e9\r\n")
        self.legacy("caf\u00e9\r\n")
        result = self.cli("adopt")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((self.root / "owner/repo/review.md").read_bytes(), "caf\u00e9\r\n".encode())

    def test_adoption_reports_pending_if_cached_branch_is_behind_remote(self):
        self.legacy()
        self.advance()
        result = self.cli("adopt")
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "pending")
        self.assertIn("agent-knowledge-sync", report["advice"])
        self.assertTrue((self.root / ".git").is_file())
        self.assertEqual((self.root / "owner/repo/review.md").read_text(), "old\n")
        self.assertEqual(self.cli("sync").returncode, 0)

    def test_conflicting_and_local_only_curated_records_prevent_adoption(self):
        self.legacy("local changed\n")
        result = self.cli("adopt")
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual((self.root / "owner/repo/review.md").read_text(), "local changed\n")
        (self.root / "owner/repo/review.md").write_text("old\n")
        (self.root / "owner/repo/config.md").write_text("local preferences\n")
        result = self.cli("adopt")
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertFalse((self.root / ".git").exists())
        self.assertEqual(list(self.root.parent.glob("pr-reviews.pre-git-*")), [])

    def test_failure_after_move_restores_legacy_and_worktree_registration(self):
        self.legacy()
        cache = self.bare.parent / "agent-knowledge"
        self.git("--git-dir=" + str(self.bare), "worktree", "add", str(cache), "main")
        module = self.module()
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, "validate_managed", side_effect=RuntimeError("after move")):
            with self.assertRaisesRegex(RuntimeError, "after move"):
                module.run("adopt")
        self.assertEqual((self.root / "owner/repo/review.md").read_text(), "old\n")
        self.assertFalse((self.root / ".git").exists())
        self.assertTrue((cache / ".git").is_file())
        registration = self.git("--git-dir=" + str(self.bare), "worktree", "list", "--porcelain")
        self.assertIn(str(cache), registration)
        self.assertNotIn("worktree " + str(self.root) + "\n", registration)
        self.assertEqual(list(self.root.parent.glob("pr-reviews.pre-git-*")), [])

    def test_effective_url_rewrite_is_rejected_before_first_fetch(self):
        self.git("config", "--global", "url.https://elsewhere.invalid/.insteadOf", "https://github.com/")
        result = self.cli(configure=True)
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertNotIn("fetch", self.log.read_text())
        self.assertFalse(self.root.exists())

    def test_unsafe_config_file_and_command_timeout_refuse_safely(self):
        self.setup_store()
        self.config.chmod(0o644)
        self.assertEqual(self.cli().returncode, 2)
        self.config.chmod(0o600)
        outside = self.base / "config-copy"
        self.config.rename(outside)
        self.config.symlink_to(outside)
        self.assertEqual(self.cli().returncode, 2)
        module = self.module()
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, "TIMEOUT", 0.01):
            with self.assertRaises(module.KnowledgeError) as caught:
                module.command([sys.executable, "-c", "import time;time.sleep(10)"])
        self.assertEqual(caught.exception.code, 5)

    def test_dirty_or_divergent_state_is_preserved(self):
        self.setup_store()
        target = self.root / "owner/repo/review.md"
        target.write_text("manual\n")
        self.advance()
        result = self.cli("sync")
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual(target.read_text(), "manual\n")
        self.git("-C", str(self.root), "add", "--", "owner/repo/review.md")
        self.git("-C", str(self.root), "commit", "-m", "manual")
        head = self.head()
        result = self.cli("sync")
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual(self.head(), head)
