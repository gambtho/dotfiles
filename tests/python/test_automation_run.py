"""Publication policy and sandbox boundary for the weekly automations."""
import dataclasses
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'libexec/automation_run.py'
spec = importlib.util.spec_from_file_location('automation_run', SCRIPT)
assert spec is not None and spec.loader is not None
automation = importlib.util.module_from_spec(spec)
sys.modules['automation_run'] = automation
spec.loader.exec_module(automation)

HEALTH = automation.PROFILES['dotfiles-health']
LANE = automation.PROFILES['lane-review']


def git(repo, *args):
    subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True)


class DowngradeTests(unittest.TestCase):
    def test_small_safe_fix_is_kept(self):
        self.assertIsNone(automation.downgrade_reason(HEALTH, ['README.md'], 10, False))

    def test_report_only_profile_never_keeps_fixes(self):
        self.assertIn('reports only', automation.downgrade_reason(LANE, ['README.md'], 1, False))

    def test_protected_paths_drop_fixes(self):
        for path in ('.github/workflows/check.yml', 'bin/gh', 'tools/automations/guard.ts',
                     'Makefile', 'ai/pi/config/permission-system.json', 'libexec/automation_run.py'):
            self.assertIn('protected', automation.downgrade_reason(HEALTH, [path], 1, False), path)

    def test_symlink_and_size_limits_drop_fixes(self):
        self.assertIn('symlink', automation.downgrade_reason(HEALTH, ['README.md'], 1, True))
        many = [f'docs/guides/f{index}.md' for index in range(automation.MAX_FIX_FILES + 1)]
        self.assertIn('limit', automation.downgrade_reason(HEALTH, many, 1, False))
        self.assertIn('lines', automation.downgrade_reason(HEALTH, ['README.md'], automation.MAX_FIX_LINES + 1, False))

    def test_fixes_outside_the_profile_scope_are_dropped(self):
        for path in ('ai/pi/AGENTS.md', 'ai/marketplace/plugins/my/skills/x/SKILL.md',
                     'core/shell/zshrc.symlink', 'tests/x.bats', '.gitignore'):
            self.assertIn('allowed files', automation.downgrade_reason(HEALTH, [path], 1, False), path)

    def test_radar_reads_untrusted_text_so_cannot_edit_agent_guidance(self):
        radar = automation.PROFILES['tooling-radar']
        self.assertIsNone(automation.downgrade_reason(radar, ['tools/herdr/config.toml.template'], 1, False))
        for path in ('AGENTS.md', 'README.md', 'docs/guides/x.md'):
            self.assertIn('allowed files', automation.downgrade_reason(radar, [path], 1, False), path)

    def test_protected_paths_win_over_the_scope_check(self):
        protected_and_listed = dataclasses.replace(HEALTH, fix_globs=('*',))
        self.assertIn('protected', automation.downgrade_reason(protected_and_listed, ['Makefile'], 1, False))


class SecretScanTests(unittest.TestCase):
    def test_token_shapes_are_blocked_without_echoing_them(self):
        token = 'gho_' + 'a' * 36
        hit = automation.secret_hit(f'leaked {token}', set())
        self.assertIsNotNone(hit)
        self.assertNotIn(token, hit)

    def test_auth_file_values_are_blocked(self):
        literals = automation.collect_secret_literals({'copilot': {'refresh': 'x' * 20, 'type': 'oauth'}, 'n': 1})
        self.assertEqual(literals, {'x' * 20})
        self.assertIsNotNone(automation.secret_hit('value ' + 'x' * 20, literals))

    def test_missing_auth_file_means_no_literals(self):
        with tempfile.TemporaryDirectory() as temp:
            self.assertEqual(automation.load_secret_literals(Path(temp) / 'auth.json'), set())

    def test_existing_auth_file_is_scanned(self):
        with tempfile.TemporaryDirectory() as temp:
            auth = Path(temp) / 'auth.json'
            auth.write_text('{"copilot": {"refresh": "%s"}}' % ('x' * 20))
            self.assertEqual(automation.load_secret_literals(auth), {'x' * 20})

    def test_malformed_auth_file_fails_rather_than_scanning_nothing(self):
        with tempfile.TemporaryDirectory() as temp:
            auth = Path(temp) / 'auth.json'
            auth.write_text('not json')
            with self.assertRaises(ValueError):
                automation.load_secret_literals(auth)

    def test_clean_text_passes(self):
        self.assertIsNone(automation.secret_hit('see docs/readme.md:12', {'x' * 20}))


class SandboxTests(unittest.TestCase):
    def setUp(self):
        self.home = Path('/home/person')
        self.args = automation.sandbox_args(
            home=self.home,
            repo=Path('/state/repo'),
            evidence=Path('/state/evidence'),
            agent_dir=Path('/state/agent'),
            guard=Path('/guard.ts'),
            node_root=self.home / '.local/share/mise/installs/node/1',
            resolv=Path('/mnt/wsl/resolv.conf'),
            pi_agent=self.home / '.pi/agent',
        )

    def binds(self, flag):
        return [self.args[i + 1] for i, value in enumerate(self.args) if value == flag]

    def test_home_is_empty_and_only_runtime_is_mounted(self):
        self.assertIn(str(self.home), self.binds('--tmpfs'))
        mounted = self.binds('--ro-bind') + self.binds('--bind')
        under_home = sorted(path for path in mounted if path.startswith(str(self.home)))
        self.assertEqual(under_home, [
            str(self.home / '.local/share/mise/installs/node/1'),
            str(self.home / '.pi/agent/bin'),
            str(self.home / '.pi/agent/install'),
        ])

    def test_environment_is_cleared(self):
        self.assertEqual(self.args[1], '--clearenv')

    def test_git_metadata_and_evidence_are_read_only(self):
        self.assertIn('/state/repo/.git', self.binds('--ro-bind'))
        self.assertIn('/state/evidence', self.binds('--ro-bind'))
        self.assertEqual(sorted(self.binds('--bind')), ['/state/agent', '/state/repo'])


class TargetTests(unittest.TestCase):
    def test_repo_slug_accepts_both_remote_forms(self):
        self.assertEqual(automation.repo_slug('git@github.com:o/r.git'), 'o/r')
        self.assertEqual(automation.repo_slug('https://github.com/o/r.git\n'), 'o/r')
        with self.assertRaises(automation.AutomationError):
            automation.repo_slug('https://example.com/o/r')

    def test_private_profile_refuses_a_public_repository(self):
        public = '{"visibility":"PUBLIC","defaultBranchRef":{"name":"main"}}'
        with mock.patch.object(automation, 'run', return_value=public):
            with self.assertRaisesRegex(automation.AutomationError, 'refusing'):
                automation.check_target(LANE, 'o/r')
            self.assertEqual(automation.check_target(HEALTH, 'o/r'), 'main')

    def test_private_target_requires_a_valid_repository_setting(self):
        for content in ('[]', '{}', '{"repository": 7}', '{"repository": "not a slug"}', '{"repository": "../x/y"}'):
            with tempfile.TemporaryDirectory() as temp:
                config = Path(temp) / 'config.json'
                config.write_text(content)
                with mock.patch.object(automation, 'KNOWLEDGE_CONFIG', config):
                    with self.assertRaisesRegex(automation.AutomationError, 'no valid repository', msg=content):
                        automation.resolve_slug(LANE)

    def test_private_target_reads_a_valid_repository_setting(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / 'config.json'
            config.write_text('{"repository": "o/r.x"}')
            with mock.patch.object(automation, 'KNOWLEDGE_CONFIG', config):
                self.assertEqual(automation.resolve_slug(LANE), 'o/r.x')

    def test_missing_default_branch_is_reported(self):
        for details in ('[]', '{"visibility":"PUBLIC"}', '{"visibility":"PUBLIC","defaultBranchRef":null}',
                        '{"visibility":"PUBLIC","defaultBranchRef":{"name":""}}'):
            with mock.patch.object(automation, 'run', return_value=details):
                with self.assertRaises(automation.AutomationError, msg=details):
                    automation.check_target(HEALTH, 'o/r')

    def test_fork_prs_are_ignored(self):
        prs = [{'headRefName': 'automation/lane-review/1', 'isCrossRepository': True}]
        self.assertEqual(automation.filter_automation_prs(prs, 'lane-review'), [])

    def test_only_trusted_comments_reach_the_next_review(self):
        comments = [{'authorAssociation': value, 'body': value}
                    for value in ('OWNER', 'MEMBER', 'COLLABORATOR', 'CONTRIBUTOR', 'NONE')]
        comments.append({'body': 'no association'})
        self.assertEqual([item['body'] for item in automation.trusted_comments(comments)],
                         ['OWNER', 'MEMBER', 'COLLABORATOR'])

    def test_sibling_prs_are_other_automations_from_this_repository(self):
        prs = [{'headRefName': 'automation/tooling-radar/1', 'url': 'r'},
               {'headRefName': 'automation/dotfiles-health/1', 'url': 'own'},
               {'headRefName': 'automation/tooling-radar/2', 'isCrossRepository': True},
               {'headRefName': 'feature'}]
        self.assertEqual([pr['url'] for pr in automation.sibling_automation_prs(prs, 'dotfiles-health')], ['r'])

    def test_locked_paths_name_the_pr_that_holds_them(self):
        prs = [{'url': 'u1', 'files': [{'path': 'ai/README.md'}]}, {'url': 'u2', 'files': None}]
        self.assertEqual(automation.locked_paths(prs), {'ai/README.md': 'u1'})

    def test_open_pr_filter_is_per_automation(self):
        prs = [{'headRefName': 'automation/lane-review/2026-11-02'}, {'headRefName': 'automation/lane-review-x/1'},
               {'headRefName': 'feature'}]
        self.assertEqual(len(automation.filter_automation_prs(prs, 'lane-review')), 1)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.repo = Path(temp.name)
        git(self.repo, 'init', '-q')
        git(self.repo, 'config', 'user.email', 'test@example.com')
        git(self.repo, 'config', 'user.name', 'Test')
        (self.repo / 'README.md').write_text('old\n')
        (self.repo / 'Makefile').write_text('old\n')
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-qm', 'initial')

    def write_report(self, profile, text='# Report\n'):
        path = self.repo / profile.report_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def staged(self):
        return automation.git(self.repo, 'diff', '--cached', '--name-only').split()

    def test_no_changes_means_nothing_to_publish(self):
        self.assertEqual(automation.enforce_policy(HEALTH, self.repo), ([], None))

    def test_changes_without_a_report_fail(self):
        (self.repo / 'README.md').write_text('new\n')
        with self.assertRaisesRegex(automation.AutomationError, 'without writing its report'):
            automation.enforce_policy(HEALTH, self.repo)

    def test_safe_fix_ships_with_report(self):
        self.write_report(HEALTH)
        (self.repo / 'README.md').write_text('new\n')
        fixes, note = automation.enforce_policy(HEALTH, self.repo)
        self.assertEqual((fixes, note), (['README.md'], None))
        self.assertEqual(sorted(self.staged()), sorted(['README.md', HEALTH.report_path]))

    def test_report_is_published_even_when_the_target_ignores_it(self):
        (self.repo / '.gitignore').write_text('docs/*\nautomation-reports/\n')
        git(self.repo, 'add', '.gitignore')
        git(self.repo, 'commit', '-qm', 'ignore')
        self.write_report(HEALTH)
        self.assertEqual(automation.enforce_policy(HEALTH, self.repo), ([], None))
        self.assertEqual(self.staged(), [HEALTH.report_path])

    def test_protected_fix_downgrades_to_the_report_alone(self):
        self.write_report(HEALTH)
        (self.repo / 'README.md').write_text('new\n')
        (self.repo / 'Makefile').write_text('evil\n')
        (self.repo / 'stray.txt').write_text('stray\n')
        fixes, note = automation.enforce_policy(HEALTH, self.repo)
        self.assertEqual(fixes, [])
        self.assertIn('Makefile', note)
        self.assertEqual(self.staged(), [HEALTH.report_path])
        self.assertEqual((self.repo / 'Makefile').read_text(), 'old\n')
        self.assertFalse((self.repo / 'stray.txt').exists())

    def test_locked_fix_is_dropped_alone(self):
        (self.repo / 'docs/guides').mkdir(parents=True)
        self.write_report(HEALTH)
        (self.repo / 'README.md').write_text('new\n')
        (self.repo / 'docs/guides/x.md').write_text('new\n')
        (self.repo / 'docs/guides/held.md').write_text('new\n')
        locked = {'README.md': 'https://example.com/pr/1', 'docs/guides/held.md': 'https://example.com/pr/1'}
        fixes, note = automation.enforce_policy(HEALTH, self.repo, locked)
        self.assertEqual(fixes, ['docs/guides/x.md'])
        self.assertIn('README.md (https://example.com/pr/1)', note)
        self.assertEqual(sorted(self.staged()), sorted(['docs/guides/x.md', HEALTH.report_path]))
        self.assertEqual((self.repo / 'README.md').read_text(), 'old\n')
        self.assertFalse((self.repo / 'docs/guides/held.md').exists())

    def test_lock_note_survives_a_later_downgrade(self):
        self.write_report(HEALTH)
        (self.repo / 'README.md').write_text('new\n')
        (self.repo / 'Makefile').write_text('evil\n')
        fixes, note = automation.enforce_policy(HEALTH, self.repo, {'README.md': 'u'})
        self.assertEqual(fixes, [])
        self.assertIn('README.md (u)', note)
        self.assertIn('protected', note)
        self.assertEqual(self.staged(), [HEALTH.report_path])

    def test_locked_file_outside_the_allowed_list_still_drops_all_fixes(self):
        (self.repo / 'tools/herdr').mkdir(parents=True)
        (self.repo / 'tools/herdr/config.toml.template').write_text('old\n')
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-qm', 'template')
        self.write_report(HEALTH)
        (self.repo / 'README.md').write_text('new\n')
        (self.repo / 'tools/herdr/config.toml.template').write_text('new\n')
        fixes, note = automation.enforce_policy(HEALTH, self.repo, {'tools/herdr/config.toml.template': 'u'})
        self.assertEqual(fixes, [])
        self.assertIn('allowed files', note)
        self.assertEqual(self.staged(), [HEALTH.report_path])
        self.assertEqual((self.repo / 'README.md').read_text(), 'old\n')

    def test_moving_a_protected_file_counts_as_touching_it(self):
        (self.repo / 'docs/guides').mkdir(parents=True)
        self.write_report(HEALTH)
        automation.git(self.repo, 'mv', 'Makefile', 'docs/guides/x.md')
        fixes, note = automation.enforce_policy(HEALTH, self.repo)
        self.assertEqual(fixes, [])
        self.assertIn('Makefile', note)
        self.assertEqual((self.repo / 'Makefile').read_text(), 'old\n')

    def test_ignored_report_survives_dropping_a_protected_fix(self):
        (self.repo / '.gitignore').write_text('docs/*\n')
        git(self.repo, 'add', '.gitignore')
        git(self.repo, 'commit', '-qm', 'ignore')
        self.write_report(HEALTH)
        (self.repo / 'Makefile').write_text('evil\n')
        fixes, note = automation.enforce_policy(HEALTH, self.repo)
        self.assertEqual(fixes, [])
        self.assertIn('Makefile', note)
        self.assertEqual(self.staged(), [HEALTH.report_path])

    def test_binary_fix_is_dropped_because_the_secret_scan_cannot_read_it(self):
        self.write_report(HEALTH)
        (self.repo / 'README.md').write_bytes(b'\0binary\n')
        fixes, note = automation.enforce_policy(HEALTH, self.repo)
        self.assertEqual(fixes, [])
        self.assertIn('lines', note)
        self.assertEqual(self.staged(), [HEALTH.report_path])
        self.assertEqual((self.repo / 'README.md').read_text(), 'old\n')

    def test_text_fix_line_counts_are_unchanged(self):
        self.write_report(HEALTH)
        (self.repo / 'README.md').write_text('new\n')
        automation.git(self.repo, 'add', '-A')
        _, changed, _ = automation.stage_all(self.repo)
        self.assertEqual(changed, 3)

    def test_binary_report_fails(self):
        self.write_report(HEALTH)
        (self.repo / HEALTH.report_path).write_bytes(b'# Report\0\n')
        with self.assertRaisesRegex(automation.AutomationError, 'binary report'):
            automation.enforce_policy(HEALTH, self.repo)

    def test_lane_review_only_ever_publishes_its_report(self):
        self.write_report(LANE)
        (self.repo / 'README.md').write_text('new\n')
        fixes, note = automation.enforce_policy(LANE, self.repo)
        self.assertEqual(fixes, [])
        self.assertIn('reports only', note)
        self.assertEqual(self.staged(), [LANE.report_path])

    def test_empty_and_oversized_reports_fail(self):
        self.write_report(HEALTH, '  \n')
        with self.assertRaisesRegex(automation.AutomationError, 'empty'):
            automation.enforce_policy(HEALTH, self.repo)
        self.write_report(HEALTH, 'x' * (automation.MAX_REPORT_BYTES + 1))
        with self.assertRaisesRegex(automation.AutomationError, 'limit'):
            automation.enforce_policy(HEALTH, self.repo)

    def test_agent_written_git_hook_does_not_run(self):
        hook = self.repo / '.git/hooks/pre-commit'
        marker = self.repo.parent / f'{self.repo.name}-hook-ran'
        hook.write_text(f'#!/bin/sh\ntouch {marker}\n')
        hook.chmod(0o755)
        self.write_report(HEALTH)
        automation.enforce_policy(HEALTH, self.repo)
        automation.git(self.repo, '-c', 'user.name=T', '-c', 'user.email=t@example.com', 'commit', '-qm', 'x')
        self.assertFalse(marker.exists())


class PublishTests(unittest.TestCase):
    def test_retry_on_the_same_day_publishes_to_a_new_recognized_branch(self):
        real_run = automation.run
        created = []

        def fake_run(cmd, **kwargs):
            if cmd[0] == 'gh':
                created.append(cmd[cmd.index('--head') + 1])
                return 'https://example.com/pr\n'
            if cmd[-2:] == ['config', 'user.name'] or cmd[-2:] == ['config', 'user.email']:
                return 'test@example.com\n'
            return real_run(cmd, **kwargs)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            origin = root / 'origin.git'
            subprocess.run(['git', 'init', '-q', '--bare', str(origin)], check=True)
            seed = root / 'seed'
            subprocess.run(['git', 'init', '-q', str(seed)], check=True)
            git(seed, 'config', 'user.email', 'test@example.com')
            git(seed, 'config', 'user.name', 'Test')
            (seed / 'README.md').write_text('old\n')
            git(seed, 'add', '.')
            git(seed, 'commit', '-qm', 'initial')
            git(seed, 'push', '-q', str(origin), 'HEAD:refs/heads/main')
            with mock.patch.object(automation, 'run', side_effect=fake_run):
                for attempt in ('first', 'second'):
                    work = root / attempt / 'repo'
                    subprocess.run(['git', 'clone', '-q', '--branch', 'main', str(origin), str(work)], check=True)
                    report = work / HEALTH.report_path
                    report.parent.mkdir(parents=True)
                    report.write_text(f'# {attempt}\n')
                    automation.git(work, 'add', '-f', '--', HEALTH.report_path)
                    automation.publish(HEALTH, work, 'o/r', 'main', '2026-11-02', [], None)
        self.assertEqual(len(set(created)), 2)
        for branch in created:
            self.assertRegex(branch, r'^automation/dotfiles-health/2026-11-02-[0-9a-f]{12}$')
        self.assertEqual(len(automation.filter_automation_prs([{'headRefName': b} for b in created], HEALTH.name)), 2)


class PrBodyTests(unittest.TestCase):
    def test_partial_drop_reports_both_dropped_and_applied_fixes(self):
        body = automation.pr_body('# R', 'another automation\'s open PR edits README.md (u)', ['docs/guides/x.md'])
        self.assertIn('Fixes were dropped:', body)
        self.assertIn('Applied fixes: `docs/guides/x.md`.', body)


class LaneEvidenceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)

    def gather(self):
        evidence = self.home / 'evidence'
        with mock.patch.object(automation, 'HOME', self.home), \
             mock.patch.object(automation, 'lane_folders', return_value=automation.lane_folders(self.home)), \
             mock.patch.object(automation, 'survey_lane_folder', return_value='survey'):
            automation.gather_lane_review(evidence, ROOT)
        return evidence

    def project(self, name='alpha-local', state='state'):
        folder = self.home / name
        folder.mkdir()
        (folder / 'STATE.md').write_text(state)
        return folder

    def test_old_friction_survives_more_than_fifteen_newer_reports(self):
        import os
        folder = self.project()
        reports = folder / 'reports'
        reports.mkdir()
        friction = reports / 'SKILL-FRICTION.md'
        friction.write_text('old correction\n' * 100)
        os.utime(friction, (1, 1))
        for index in range(20):
            (reports / f'new-{index}.md').write_text('recent report')
        evidence = self.gather()
        self.assertTrue((evidence / 'projects/alpha-local/reports/SKILL-FRICTION.md').is_file())
        self.assertEqual((evidence / 'projects/alpha-local/reports/SKILL-FRICTION.md').read_text(),
                         'old correction\n' * 100)
        self.assertEqual(len(list((evidence / 'projects/alpha-local/recent-activity/reports').glob('*.md'))), 15)

    def test_memory_is_bounded_and_transcripts_and_people_stay_out(self):
        folder = self.project()
        self.project('empty-local')
        encoded = str(folder).replace('/', '-').replace('_', '-')
        claude_project = self.home / '.claude/projects' / encoded
        memory = claude_project / 'memory'
        memory.mkdir(parents=True)
        (memory / 'correction.md').write_text('lesson\n' * 700)
        (memory / 'PEOPLE.md').write_text('private people')
        (claude_project / 'session.jsonl').write_text('private transcript')
        (memory / 'auth.json').write_text('credential')
        (memory / 'link.md').symlink_to(claude_project / 'session.jsonl')
        evidence = self.gather()
        copied = evidence / 'projects/alpha-local/memory/alpha-local/correction.md'
        self.assertTrue(copied.is_file())
        self.assertEqual(copied.read_text(), 'lesson\n' * 600)
        self.assertEqual(sorted(p.name for p in (evidence / 'projects').rglob('*') if p.is_file()),
                         ['STATE.md', 'STATE.md', 'correction.md'])

    def test_aliases_share_evidence_and_archives_name_their_owner(self):
        owner = self.project('beta-local')
        alias = self.home / 'alias-local'
        alias.symlink_to(owner, target_is_directory=True)
        self.project('archive-local', f'Frozen 2026-01-01: coordinated from {owner}; see handoff.\n')
        self.project('unrelated-local', f'Uses {owner} as a reference, not an owner.\n')
        encoded = str(alias).replace('/', '-').replace('_', '-')
        memory = self.home / '.claude/projects' / encoded / 'memory'
        memory.mkdir(parents=True)
        (memory / 'old-lesson.md').write_text('alias lesson')
        evidence = self.gather()
        self.assertTrue((evidence / 'project-groups.md').is_file())
        index = (evidence / 'project-groups.md').read_text()
        self.assertIn('alias-local | beta-local | beta-local | symlink', index)
        self.assertIn('archive-local | archive-local | beta-local | frozen declaration', index)
        self.assertIn('unrelated-local | unrelated-local | unrelated-local | independent', index)
        self.assertFalse((evidence / 'projects/alias-local').exists())
        self.assertTrue((evidence / 'projects/archive-local/STATE.md').is_file())
        self.assertEqual((evidence / 'projects/beta-local/memory/alias-local/old-lesson.md').read_text(),
                         'alias lesson')

    def test_memory_directory_cannot_escape_claude_projects(self):
        folder = self.project()
        project = self.home / '.claude/projects' / str(folder).replace('/', '-').replace('_', '-')
        project.mkdir(parents=True)
        outside = self.home / 'outside'
        outside.mkdir()
        (outside / 'secret.md').write_text('not a memory note')
        (project / 'memory').symlink_to(outside, target_is_directory=True)
        evidence = self.gather()
        self.assertFalse((evidence / 'projects/alpha-local/memory').exists())

    def test_shared_memory_is_copied_once_and_each_alias_can_find_it(self):
        owner = self.project('beta-local')
        alias = self.home / 'alias-local'
        alias.symlink_to(owner, target_is_directory=True)
        projects = self.home / '.claude/projects'
        memory = projects / str(owner).replace('/', '-').replace('_', '-') / 'memory'
        memory.mkdir(parents=True)
        (memory / 'lesson.md').write_text('one lesson')
        alias_memory = projects / str(alias).replace('/', '-').replace('_', '-') / 'memory'
        alias_memory.parent.mkdir()
        alias_memory.symlink_to(memory, target_is_directory=True)
        evidence = self.gather()
        self.assertEqual(len(list((evidence / 'projects').rglob('lesson.md'))), 1)
        index = (evidence / 'project-groups.md').read_text()
        self.assertEqual(index.count('projects/beta-local/memory/alias-local'), 2)

    def test_symlinked_home_does_not_make_an_alias_the_canonical_project(self):
        actual = self.home / 'actual-home'
        actual.mkdir()
        linked = self.home / 'linked-home'
        linked.symlink_to(actual, target_is_directory=True)
        self.home = linked
        owner = self.project('beta-local')
        (self.home / 'alias-local').symlink_to(owner, target_is_directory=True)
        evidence = self.gather()
        index = (evidence / 'project-groups.md').read_text()
        self.assertIn('alias-local | beta-local | beta-local | symlink', index)
        self.assertIn('beta-local | beta-local | beta-local | independent', index)

    def test_archive_ownership_requires_a_complete_path_and_unambiguous_direct_owner(self):
        owner = self.project('owner-local')
        other = self.project('other-local')
        fixtures = {
            'prefix-local': f'Frozen: coordinated from {owner}-archive/data',
            'active-local': f'Frozen lanes: W3 coordinated from {owner}',
            'ambiguous-local': f'Frozen: coordinated from {owner}\nFrozen: coordinated from {other}',
            'chain-local': f'Frozen: coordinated from {self.home}/archive-local',
            'archive-local': f'Frozen: coordinated from {owner}',
            'cycle-a-local': f'Frozen: coordinated from {self.home}/cycle-b-local',
            'cycle-b-local': f'Frozen: coordinated from {self.home}/cycle-a-local',
        }
        for name, state in fixtures.items():
            self.project(name, state)
        evidence = self.gather()
        index = (evidence / 'project-groups.md').read_text()
        for name in fixtures:
            if name != 'archive-local':
                self.assertIn(f'{name} | {name} | {name} | independent', index)
        self.assertIn('archive-local | archive-local | owner-local | frozen declaration', index)

    def test_only_coordination_folders_are_selected(self):
        (self.home / 'alpha-local').mkdir()
        (self.home / 'alpha-local/STATE.md').write_text('state')
        (self.home / 'other-local').mkdir()
        (self.home / 'alpha').mkdir()
        self.assertEqual([path.name for path in automation.lane_folders(self.home)], ['alpha-local'])

    def test_people_notes_are_never_copied(self):
        self.assertNotIn('PEOPLE.md', automation.LANE_FILES)
        lanes = self.home / 'lanes'
        lanes.mkdir()
        for name in ('PEOPLE.md', 'people.md', 'People.md', 'W1.md'):
            (lanes / name).write_text('x')
        now = (lanes / 'W1.md').stat().st_mtime
        self.assertEqual([path.name for path in automation.recent_activity(self.home, now)], ['W1.md'])

    def test_recent_activity_skips_old_files_and_symlinks(self):
        lanes = self.home / 'lanes'
        lanes.mkdir()
        (lanes / 'new.md').write_text('x')
        old = lanes / 'old.md'
        old.write_text('x')
        import os
        os.utime(old, (1, 1))
        (lanes / 'link.md').symlink_to(self.home / 'lanes/new.md')
        (lanes / 'skip.txt').write_text('x')
        now = (lanes / 'new.md').stat().st_mtime
        self.assertEqual([path.name for path in automation.recent_activity(self.home, now)], ['new.md'])


class RepositoryTests(unittest.TestCase):
    def test_public_reports_are_not_gitignored(self):
        for profile in (HEALTH, automation.PROFILES['tooling-radar']):
            result = subprocess.run(['git', '-C', str(ROOT), 'check-ignore', '-q', profile.report_path], check=False)
            self.assertEqual(result.returncode, 1, profile.report_path)


class PromptTests(unittest.TestCase):
    def test_every_profile_has_a_prompt_and_timer(self):
        for name in automation.PROFILES:
            prompt = (ROOT / f'tools/automations/prompts/{name}.md').read_text()
            for placeholder in ('{{REPORT}}', '{{EVIDENCE}}', '{{REPO}}', '{{DATE}}'):
                self.assertIn(placeholder, prompt, f'{name} missing {placeholder}')
            self.assertTrue((ROOT / f'tools/automations/systemd/dotfiles-automation@{name}.timer').is_file())

    def test_fixing_prompts_explain_locked_files(self):
        for name in ('dotfiles-health', 'tooling-radar'):
            prompt = (ROOT / f'tools/automations/prompts/{name}.md').read_text()
            self.assertIn('`open-automation-prs.md`', prompt, name)

    def test_prompts_name_the_same_paths_as_the_policy(self):
        for name in ('dotfiles-health', 'tooling-radar'):
            prompt = (ROOT / f'tools/automations/prompts/{name}.md').read_text()
            for glob in automation.PROFILES[name].fix_globs:
                self.assertIn(f'`{glob}`', prompt, f'{name} missing {glob}')
                self.assertFalse(automation.is_protected(glob), f'{glob} can never be applied')
            for path in (*automation.PROTECTED_PREFIXES, 'Makefile', 'config/versions.env',
                         'ai/pi/install.sh', 'ai/pi/settings.json', 'ai/pi/config/permission-system.json'):
                self.assertIn(f'`{path}`', prompt, f'{name} missing {path}')


if __name__ == '__main__':
    unittest.main()
