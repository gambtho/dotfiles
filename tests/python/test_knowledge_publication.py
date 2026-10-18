"""Authorized publication exercises actual commits, refs, hooks and filesystem locks."""
import fcntl
import hashlib
import importlib.util
import json
import os
import sys
from unittest.mock import patch
from agent_knowledge_fixture import CONTROLLER, PUBLISHER, ROOT, KnowledgeFixture


class KnowledgePublicationTests(KnowledgeFixture):
    def setUp(self):
        super().setUp()
        self.setup_store()

    def module(self):
        spec = importlib.util.spec_from_file_location("knowledge_publication_test", CONTROLLER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_verified_publish_pushes_exact_target_without_untracked_reports(self):
        (self.root / "report.local").write_text("never push this\n")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(json.loads(result.stdout)["sync"]["status"], "pushed")
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "show", "main:owner/repo/review.md"), "new")
        self.assertNotIn("report.local", self.git("--git-dir=" + str(self.remote), "ls-tree", "-r", "--name-only", "main"))
        self.assertFalse(self.git("-C", str(self.root), "diff", "--name-only"))

    def test_unmanaged_configured_root_saves_locally_without_git_authorization(self):
        cache = self.bare.parent / "agent-knowledge"
        self.git("--git-dir=" + str(self.bare), "worktree", "move", str(self.root), str(cache))
        (self.root / "owner/repo").mkdir(parents=True, mode=0o700)
        self.root.chmod(0o700)
        (self.root / "owner/repo/review.md").write_text("old\n")
        before_network = self.log.read_bytes()
        result = self.publish()
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertTrue(json.loads(result.stdout)["sync"]["local_saved"])
        self.assertEqual((self.root / "owner/repo/review.md").read_text(), "new\n")
        self.assertFalse((self.state / "pending.json").exists())
        self.assertEqual(self.log.read_bytes(), before_network)

    def test_snapshot_has_no_network_and_noop_has_no_empty_commit(self):
        self.log.unlink()
        import subprocess
        result = subprocess.run([sys.executable, str(PUBLISHER), "snapshot", "--root", str(self.root), "--store", "owner/repo", "--file", "review.md"], env=self.env, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())
        old = self.head()
        result = self.publish("old\n")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.head(), old)

    def test_offline_data_remains_uncommitted_and_recovers_on_sync(self):
        old = self.head()
        self.offline()
        result = self.publish()
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertTrue(json.loads(result.stdout)["sync"]["local_saved"])
        self.assertEqual((self.root / "owner/repo/review.md").read_text(), "new\n")
        self.assertEqual(self.head(), old)
        self.meta.with_suffix(".offline").unlink()
        result = self.cli("sync")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "show", "main:owner/repo/review.md"), "new")

    def test_remote_ahead_waits_without_checkout_then_syncs_unrelated_pending(self):
        old = self.head()
        self.advance()
        result = self.publish()
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual(self.head(), old)
        self.assertFalse((self.root / "other").exists())
        result = self.cli("sync")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue((self.root / "other/repo/review.md").exists())
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "show", "main:owner/repo/review.md"), "new")

    def test_pending_same_file_collision_does_not_overwrite_either_side(self):
        self.advance("owner/repo/review.md", "remote\n")
        result = self.publish("local\n")
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        old = self.head()
        self.assertEqual(self.cli("sync").returncode, 5)
        self.assertEqual(self.head(), old)
        self.assertEqual((self.root / "owner/repo/review.md").read_text(), "local\n")
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "show", "main:owner/repo/review.md"), "remote")

    def test_unrelated_staged_changes_and_manual_commits_are_not_published(self):
        (self.root / "manual.md").write_text("manual\n")
        self.git("-C", str(self.root), "add", "manual.md")
        old_remote = self.git("--git-dir=" + str(self.remote), "rev-parse", "main")
        result = self.publish()
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "main"), old_remote)
        self.git("-C", str(self.root), "commit", "-m", "manual")
        result = self.publish("new\n")
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "main"), old_remote)

    def test_changed_pending_bytes_are_not_swept_into_sync(self):
        self.offline()
        self.assertEqual(self.publish().returncode, 5)
        (self.root / "owner/repo/review.md").write_text("unverified manual content\n")
        self.meta.with_suffix(".offline").unlink()
        old_remote = self.git("--git-dir=" + str(self.remote), "rev-parse", "main")
        self.assertEqual(self.cli("sync").returncode, 5)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "main"), old_remote)
        self.assertEqual((self.root / "owner/repo/review.md").read_text(), "unverified manual content\n")

    def test_push_failure_retries_only_recorded_commit_without_empty_commit(self):
        self.meta.with_suffix(".push-fail").touch()
        result = self.publish()
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        committed = self.head()
        self.assertNotEqual(committed, self.git("--git-dir=" + str(self.remote), "rev-parse", "main"))
        self.meta.with_suffix(".push-fail").unlink()
        result = self.publish("new\n")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.head(), committed)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "main"), committed)

    def test_effective_pushurl_multiple_urls_and_rewrite_refuse_push(self):
        for setting, values in (("remote.origin.pushurl", ["https://github.com/unconfigured/public.git"]), ("remote.origin.pushurl", ["https://github.com/fixture/knowledge.git", "https://github.com/elsewhere/secret.git"]), ("url.https://elsewhere.invalid/.insteadOf", ["https://github.com/"]), ("url.https://elsewhere.invalid/.pushInsteadOf", ["https://github.com/"])):
            with self.subTest(setting=setting, values=values):
                for value in values:
                    self.git("-C", str(self.root), "config", "--add", setting, value)
                old_remote = self.git("--git-dir=" + str(self.remote), "rev-parse", "main")
                result = self.publish("new\n")
                self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
                self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "main"), old_remote)
                self.git("-C", str(self.root), "config", "--unset-all", setting)

    def test_push_refspec_mirror_and_follow_tags_cannot_publish_extra_refs(self):
        self.git("-C", str(self.root), "config", "remote.origin.mirror", "true")
        self.git("-C", str(self.root), "config", "remote.origin.push", "HEAD:refs/heads/unapproved")
        self.git("-C", str(self.root), "config", "push.followTags", "true")
        self.git("-C", str(self.root), "tag", "-a", "private-local-tag", "-m", "local only")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "for-each-ref", "--format=%(refname)"), "refs/heads/main")
        args = json.loads(self.log.with_suffix(".push-argv").read_text())
        self.assertIn(("-c", "remote.origin.mirror=false"), zip(args, args[1:]))
        self.assertIn(("-c", "push.followTags=false"), zip(args, args[1:]))
        self.assertEqual(args[args.index("push") + 1:], ["--no-follow-tags", "--recurse-submodules=no", "origin", self.head() + ":refs/heads/main"])

    def test_custom_remote_helper_is_not_an_authorized_transport(self):
        self.git("-C", str(self.root), "config", "remote.origin.vcs", "unconfigured")
        old = self.git("--git-dir=" + str(self.remote), "rev-parse", "main")
        result = self.publish()
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "main"), old)

    def test_credential_pattern_remains_local_and_auto_publish_can_be_disabled(self):
        old = self.head()
        result = self.publish("ghp_" + "a" * 36 + "\n")
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual(self.head(), old)
        cfg = json.loads(self.config.read_text())
        cfg["auto_publish"] = False
        self.config.write_text(json.dumps(cfg))
        self.log.unlink()
        result = self.publish("ordinary local notes\n")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertNotIn("sync", json.loads(result.stdout))
        self.assertFalse(self.log.exists())
        self.assertEqual(self.head(), old)

    def test_hook_cannot_add_unrelated_content_to_an_authorized_commit(self):
        hook = self.bare / "hooks/pre-commit"
        hook.write_text("#!/bin/sh\nprintf 'not authorized\\n' > unrelated.md\ngit add unrelated.md\n")
        hook.chmod(0o700)
        old_remote = self.git("--git-dir=" + str(self.remote), "rev-parse", "main")
        result = self.publish()
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "main"), old_remote)
        self.assertFalse(json.loads((self.state / "pending.json").read_text())["authorized_commit"])

    def test_ensure_reports_pending_even_when_git_ignores_the_saved_profile(self):
        with (self.bare / "info/exclude").open("a") as stream:
            stream.write("\nowner/repo/learnings.md\n")
        result = self.publish(file="learnings.md")
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual(self.cli().returncode, 5)
        self.assertEqual(self.cli("check").returncode, 5)
        self.assertEqual((self.root / "owner/repo/learnings.md").read_text(), "new\n")

    def test_github_identity_is_selected_from_knowledge_not_product_worktree(self):
        self.meta.with_suffix(".cwd").write_text(str(self.root))
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.cli("check").returncode, 0)

    def test_publication_refuses_world_readable_git_storage_before_local_change(self):
        self.bare.chmod(0o755)
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((self.root / "owner/repo/review.md").read_text(), "old\n")

    def test_product_git_context_cannot_redirect_knowledge_index_or_objects(self):
        before_index = (self.seed / ".git/index").read_bytes()
        before_objects = {str(p.relative_to(self.seed)) for p in (self.seed / ".git/objects").rglob("*") if p.is_file()}
        original = dict(self.env)
        self.env.update(GIT_DIR=str(self.seed / ".git"), GIT_WORK_TREE=str(self.seed), GIT_INDEX_FILE=str(self.seed / ".git/index"), GIT_OBJECT_DIRECTORY=str(self.seed / ".git/objects"))
        result = self.publish()
        self.env = original
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual((self.seed / ".git/index").read_bytes(), before_index)
        self.assertEqual({str(p.relative_to(self.seed)) for p in (self.seed / ".git/objects").rglob("*") if p.is_file()}, before_objects)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "show", "main:owner/repo/review.md"), "new")

    def test_literal_tilde_root_keeps_the_existing_expanduser_contract(self):
        import subprocess
        scratch = self.base / "tilde-scratch"
        scratch.mkdir()
        candidate = scratch / "candidate.md"
        candidate.write_text("tilde publication\n")
        result = subprocess.run([sys.executable, str(PUBLISHER), "publish", "--root", "~/.pi/pr-reviews", "--store", "owner/repo", "--file", "review.md", "--expected", hashlib.sha256(b"old\n").hexdigest(), "--candidate-root", str(scratch), "--candidate", str(candidate)], env=self.env, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(json.loads(result.stdout).get("sync", {}).get("status"), "pushed")
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "show", "main:owner/repo/review.md"), "tilde publication")

    def test_trusted_parent_alias_is_the_same_configured_worktree(self):
        alias = self.base / "home-alias"
        alias.symlink_to(self.home, target_is_directory=True)
        result = self.publish("alias publication\n", root=alias / ".pi/pr-reviews")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(json.loads(result.stdout)["sync"]["status"], "pushed")
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "show", "main:owner/repo/review.md"), "alias publication")

    def test_documented_make_sync_action_runs_the_real_controller(self):
        import subprocess
        self.offline()
        self.assertEqual(self.publish().returncode, 5)
        self.meta.with_suffix(".offline").unlink()
        result = subprocess.run(["make", "--no-print-directory", "-C", str(ROOT), "agent-knowledge-sync"], env=self.env, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "show", "main:owner/repo/review.md"), "new")

    def test_public_destination_keeps_local_data_without_committing(self):
        data = json.loads(self.meta.read_text())
        data["private"] = False
        self.meta.write_text(json.dumps(data))
        old = self.head()
        result = self.publish()
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual(self.head(), old)
        self.assertEqual((self.root / "owner/repo/review.md").read_text(), "new\n")

    def test_hook_failure_is_pending_and_hook_is_not_bypassed(self):
        hook = self.bare / "hooks/pre-commit"
        hook.write_text("#!/bin/sh\nexit 23\n")
        hook.chmod(0o700)
        old = self.head()
        result = self.publish()
        self.assertEqual(result.returncode, 5, result.stderr + result.stdout)
        self.assertEqual(self.head(), old)
        hook.unlink()
        result = self.cli("sync")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertNotEqual(self.head(), old)

    def test_repo_lock_precedes_all_store_writes(self):
        lock = self.state / "repository.lock"
        with lock.open("r+") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.publish(store="another/repo", file="learnings.md")
        self.assertEqual(result.returncode, 3, result.stderr + result.stdout)
        self.assertFalse((self.root / "another/repo/learnings.md").exists())

    def test_stale_file_has_no_commit_or_pending_intent(self):
        old = self.head()
        result = self.publish(expected=hashlib.sha256(b"not current\n").hexdigest())
        self.assertEqual(result.returncode, 4, result.stderr + result.stdout)
        self.assertEqual(self.head(), old)
        self.assertFalse((self.state / "pending.json").exists())

    def test_interrupted_intent_write_preserves_bytes_without_push(self):
        module = self.module()
        target = self.root / "owner/repo/review.md"
        target.write_text("saved before interruption\n")
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, "write_json", side_effect=OSError("interrupted")):
            with module.publication(self.root) as actor:
                result = actor.record("owner/repo/review.md", hashlib.sha256(target.read_bytes()).hexdigest())
        self.assertEqual(result["status"], "pending")
        self.assertEqual(target.read_text(), "saved before interruption\n")
        self.assertEqual(self.cli("sync").returncode, 5)

    def test_commit_without_authorization_receipt_is_never_retried_as_owned(self):
        module = self.module()
        target = self.root / "owner/repo/review.md"
        target.write_text("saved\n")
        original = module.write_json
        def fail_receipt(path, value):
            if value.get("authorized_commit"):
                raise OSError("interrupted after commit")
            original(path, value)
        old_remote = self.git("--git-dir=" + str(self.remote), "rev-parse", "main")
        with patch.dict(os.environ, self.env, clear=True), patch.object(module, "write_json", side_effect=fail_receipt):
            with module.publication(self.root) as actor:
                result = actor.record("owner/repo/review.md", hashlib.sha256(target.read_bytes()).hexdigest())
        self.assertEqual(result["status"], "pending")
        self.assertNotEqual(self.head(), old_remote)
        self.assertEqual(self.cli("sync").returncode, 5)
        self.assertEqual(self.git("--git-dir=" + str(self.remote), "rev-parse", "main"), old_remote)
        self.assertEqual(target.read_text(), "saved\n")
