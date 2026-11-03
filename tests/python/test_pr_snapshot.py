import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'ai/marketplace/plugins/my/skills/pr-closeout/scripts/pr_snapshot.sh'
GOLDEN = Path(__file__).with_name('pr_snapshot_stable.json')

FAKE_GH = '''#!{python}
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
log = Path(os.environ['FIXTURE_CALLS'])
previous = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
with log.open('a') as stream:
    stream.write(json.dumps(args) + '\\n')
data = json.loads(Path(os.environ['FIXTURE_DATA']).read_text())
mode = os.environ.get('FIXTURE_MODE', 'stable')
if args[:2] == ['pr', 'view']:
    pr = data['pr'].copy()
    final = any(call[:2] == ['pr', 'view'] for call in previous)
    if final:
        if mode == 'final-error':
            print('fixture final lookup failed', file=sys.stderr)
            sys.exit(1)
        if mode == 'final-malformed':
            print('not JSON')
            sys.exit(0)
        if mode == 'final-array':
            print('[]')
            sys.exit(0)
        changes = {
            'head': {'headRefOid': 'b' * 40},
            'base': {'baseRefName': 'release'},
            'closed': {'state': 'CLOSED'},
            'draft': {'isDraft': True},
            'review': {'reviewDecision': 'CHANGES_REQUESTED'},
            'merge': {'mergeStateStatus': 'UNKNOWN'},
            'final-empty-head': {'headRefOid': ''},
            'final-wrong-draft': {'isDraft': 'false'},
            'final-wrong-number': {'number': 124},
            'final-wrong-url': {'url': 'https://github.com/example/project/pull/124'},
        }
        pr.update(changes.get(mode, {}))
        if mode == 'final-missing':
            del pr['headRefOid']
    print(json.dumps(pr))
elif args[:2] == ['pr', 'checks']:
    if mode == 'check-error':
        print('fixture check lookup failed', file=sys.stderr)
        sys.exit(2)
    checks = data['checks']
    if mode == 'check-failure':
        checks = [dict(checks[0], bucket='fail', state='FAILURE')]
    print(json.dumps(checks))
    sys.exit(1 if mode == 'check-failure' else 0)
elif args[:2] == ['api', 'graphql'] and any('commits(last:1)' in value for value in args):
    print(data['pr']['headRefOid'])
elif args[:2] == ['api', 'graphql']:
    second = any(value.startswith('after=') for value in args)
    node = {'id': 'thread-1', 'isResolved': False, 'isOutdated': False,
            'comments': {'nodes': [{'author': {'login': 'reviewer'}, 'path': 'file.py',
                                    'line': 1, 'url': 'https://example.invalid/thread',
                                    'createdAt': '2020-01-01T00:00:00Z'}]}}
    nodes = [node] if mode == 'threads' or (mode == 'pagination' and second) else []
    page = {'nodes': nodes, 'pageInfo': {'hasNextPage': mode == 'pagination' and not second,
                                        'endCursor': 'cursor' if not second else None}}
    print(json.dumps({'data': {'repository': {'pullRequest': {'reviewThreads': page}}}}))
else:
    print('unexpected gh call: ' + repr(args), file=sys.stderr)
    sys.exit(91)
'''


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        gh = bin_dir / 'gh'
        gh.write_text(FAKE_GH.replace('{python}', sys.executable))
        gh.chmod(0o755)
        self.calls_file = self.root / 'calls.jsonl'
        self.data_file = self.root / 'data.json'
        self.env = {
            'PATH': f'{bin_dir}:{Path(shutil.which("git")).parent}:/usr/bin:/bin',
            'HOME': str(self.root), 'XDG_CONFIG_HOME': str(self.root / 'config'),
            'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
            'GIT_AUTHOR_NAME': 'Fixture', 'GIT_COMMITTER_NAME': 'Fixture',
            'GIT_AUTHOR_EMAIL': 'fixture@example.invalid', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
            'GIT_AUTHOR_DATE': '2000-01-01T00:00:00+0000', 'GIT_COMMITTER_DATE': '2000-01-01T00:00:00+0000',
            'FIXTURE_CALLS': str(self.calls_file), 'FIXTURE_DATA': str(self.data_file),
        }
        self.git('init', '-q', '--object-format=sha1', '-b', 'feature')
        tree = self.git('mktree', input='')
        self.head = self.git('commit-tree', tree, input='snapshot fixture\n')
        self.git('update-ref', 'HEAD', self.head)
        self.pr = {
            'number': 123, 'url': 'https://github.com/example/project/pull/123', 'title': 'Fixture PR',
            'state': 'OPEN', 'isDraft': False, 'baseRefName': 'main', 'headRefName': 'feature',
            'headRefOid': self.head, 'mergeStateStatus': 'CLEAN', 'reviewDecision': 'APPROVED',
            'updatedAt': '2020-01-01T00:00:00Z', 'author': {'login': 'fixture'},
            'headRepositoryOwner': {'login': 'example'},
        }
        checks = [{'name': 'test', 'state': 'SUCCESS', 'bucket': 'pass',
                   'link': 'https://example.invalid/check', 'workflow': 'CI',
                   'startedAt': '2020-01-01T00:00:00Z', 'completedAt': '2020-01-01T00:01:00Z'}]
        self.data_file.write_text(json.dumps({'pr': self.pr, 'checks': checks}))

    def git(self, *args, input=None):
        return subprocess.check_output(['git', '-C', str(self.repo), *args],
                                       input=input, text=True, env=self.env).strip()

    def run_snapshot(self, mode='stable', output=None):
        self.calls_file.unlink(missing_ok=True)
        args = ['bash', str(HELPER), '--repo', str(self.repo), '--github-repo', 'example/project', '--pr', '123']
        if output:
            args.append(output)
        result = subprocess.run(args, env=dict(self.env, FIXTURE_MODE=mode), text=True,
                                capture_output=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        if output != '--summary':
            self.assertIn('observation', json.loads(result.stdout), 'snapshot must expose collection consistency')
        calls = [json.loads(line) for line in self.calls_file.read_text().splitlines()]
        self.assertTrue(all(call[:2] in (['pr', 'view'], ['pr', 'checks'], ['api', 'graphql']) for call in calls))
        return result.stdout, calls

    @staticmethod
    def legacy_projection(snapshot):
        projected = copy.deepcopy(snapshot)
        projected.pop('observation', None)
        projected['blockers'].pop('prObservationChanged', None)
        projected['blockers'].pop('prObservationLookupFailed', None)
        projected['generatedAt'] = '<timestamp>'
        projected['local']['prUpdatedAgeSeconds'] = '<age>'
        return projected

    def test_stable_snapshot_adds_consistency_without_changing_legacy_fields(self):
        for output in (None, '--compact'):
            with self.subTest(output=output):
                text, calls = self.run_snapshot(output=output)
                snapshot = json.loads(text)
                self.assertTrue(snapshot['observation']['consistent'])
                self.assertFalse(snapshot['blockers']['prObservationChanged'])
                self.assertFalse(snapshot['blockers']['prObservationLookupFailed'])
                self.assertEqual(self.legacy_projection(snapshot), json.loads(GOLDEN.read_text()))
                self.assertEqual(len([call for call in calls if call[:2] == ['pr', 'view']]), 2)
                self.assertEqual(calls[-1][:3], ['pr', 'view', '123'])
                self.assertIn('example/project', calls[-1])

    def test_changed_metadata_blocks_mixed_evidence(self):
        for mode in ('head', 'base', 'closed', 'draft', 'review', 'merge', 'final-wrong-number', 'final-wrong-url'):
            with self.subTest(mode=mode):
                text, _ = self.run_snapshot(mode)
                snapshot = json.loads(text)
                self.assertFalse(snapshot['observation']['consistent'])
                self.assertTrue(snapshot['blockers']['prObservationChanged'])
                self.assertFalse(snapshot['blockers']['prObservationLookupFailed'])
                self.assertEqual(snapshot['pr']['headRefOid'], self.head)
                self.assertEqual(snapshot['checks']['items'][0]['bucket'], 'pass')
                self.assertEqual(snapshot['observation']['start']['headRefOid'], self.head)

    def test_unreadable_final_metadata_preserves_evidence_with_unknown_blocker(self):
        for mode in ('final-error', 'final-malformed', 'final-array', 'final-empty-head', 'final-wrong-draft', 'final-missing'):
            with self.subTest(mode=mode):
                text, _ = self.run_snapshot(mode)
                snapshot = json.loads(text)
                self.assertFalse(snapshot['observation']['consistent'])
                self.assertTrue(snapshot['blockers']['prObservationLookupFailed'])
                self.assertIsNone(snapshot['observation']['end'])
                self.assertEqual(snapshot['pr']['number'], 123)
                self.assertEqual(snapshot['checks']['items'][0]['bucket'], 'pass')

    def test_check_and_thread_blockers_survive_consistency_check(self):
        for mode, blocker in (('check-error', 'checksLookupFailed'), ('check-failure', 'failingChecks'),
                              ('threads', 'unresolvedReviewThreads'), ('pagination', 'unresolvedReviewThreads')):
            with self.subTest(mode=mode):
                text, calls = self.run_snapshot(mode)
                snapshot = json.loads(text)
                self.assertTrue(snapshot['observation']['consistent'])
                self.assertTrue(snapshot['blockers'][blocker])
                if mode == 'pagination':
                    self.assertEqual(len([c for c in calls if c[:2] == ['api', 'graphql']
                                         and not any('commits(last:1)' in v for v in c)]), 2)

    def test_summary_identifies_consistent_changed_and_unknown_observations(self):
        for mode, label in (('stable', 'consistent'), ('head', 'changed'), ('final-error', 'unknown')):
            with self.subTest(mode=mode):
                text, _ = self.run_snapshot(mode, '--summary')
                self.assertIn(f'Observation: {label}', text)
                self.assertIn(self.head, text)
                self.assertIn('PR #123: Fixture PR', text)


if __name__ == '__main__':
    unittest.main()
