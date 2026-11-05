"""Offline CLI/transport contracts for the shared morning checker."""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / 'ai/marketplace/plugins/my/skills/lane-coordinator/scripts/morning.py'

FAKE_GH = '''#!/usr/bin/env python3
import json, os, pathlib, sys, time
args = sys.argv[1:]
p = pathlib.Path(os.environ['FAKE_LOG'])
prior = p.read_text().splitlines() if p.exists() else []
with p.open('a') as f:
    f.write(json.dumps({'args':args, 'notifier':os.environ.get('GH_NO_UPDATE_NOTIFIER')})+'\\n')
responses = json.loads(pathlib.Path(os.environ['FAKE_RESPONSES']).read_text())
r = responses[min(len(prior), len(responses)-1)]
if r.get('sleep'): time.sleep(r['sleep'])
if r.get('stderr'): sys.stderr.write(r['stderr'])
if r.get('raw') is not None: sys.stdout.write(r['raw'])
else:
    if '--include' in args:
        print('HTTP/2.0 200 OK\\r')
        for k,v in r.get('headers',{}).items(): print(k+': '+v+'\\r')
        print('\\r')
    print(json.dumps(r.get('body')))
sys.exit(r.get('exit',0))
'''


class MorningTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), 'shared morning checker missing')
        spec = importlib.util.spec_from_file_location('lane_morning', SCRIPT)
        assert spec is not None and spec.loader is not None
        self.m = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.m
        spec.loader.exec_module(self.m)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        gh = self.bin / 'gh'
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.log = self.root / 'calls.jsonl'
        self.responses = self.root / 'responses.json'
        self.responses.write_text(json.dumps([{'body': {'total_count': 0, 'items': [], 'incomplete_results': False}}]))
        self.env = patch.dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
                              FAKE_LOG=str(self.log), FAKE_RESPONSES=str(self.responses))
        self.env.start()
        self.addCleanup(self.env.stop)
        self.config = {'repos': ['example/project'], 'me': 'example-user'}
        self.save()
        for name in ('STATE', 'AGENTS', 'PEOPLE', 'COORDINATION', 'CLOSED-2026-11'):
            (self.root / (name+'.md')).write_text('')

    def save(self, base=None, sidecar=None):
        (self.root / 'coordination.json').write_text(json.dumps(self.config if base is None else base))
        if sidecar is not None:
            (self.root / 'coordination-checks.json').write_text(json.dumps(sidecar))

    def reply(self, *rows):
        self.responses.write_text(json.dumps(list(rows)))

    def calls(self):
        return [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []

    def main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = self.m.main(['--root', str(self.root), *args])
        return code, out.getvalue(), err.getvalue()

    def test_missing_config_never_uses_home_defaults(self):
        (self.root / 'coordination.json').unlink()
        with self.assertRaises(SystemExit) as caught, contextlib.redirect_stderr(io.StringIO()):
            self.main()
        self.assertEqual(caught.exception.code, 2)
        self.assertFalse(self.calls())
        self.assertFalse((self.root / '.morning-last-run').exists())

    def test_configured_cwd_and_explicit_root(self):
        with patch.object(pathlib.Path, 'cwd', return_value=self.root):
            self.assertEqual(self.m.workspace_root(None), self.root)
            self.assertEqual(self.m.workspace_root(self.root), self.root)

    def test_base_and_sidecar_do_not_share_allowlists(self):
        self.save(sidecar={'limits': {'seconds': 300, 'queries': 10}, 'checkouts': [], 'disk': {}})
        self.m.configure(self.root)
        self.assertEqual(self.m.REPOS, ('example/project',))
        self.save(base={**self.config, 'limits': {'queries': 10}})
        with self.assertRaises(ValueError):
            self.m.configure(self.root)

    def test_sidecar_validation_precedes_network(self):
        for side in ({'typo': 1}, {'limits': {'queries': True}}, {'limits': {'seconds': 0}}, {'limits': {'queries': 601}}):
            with self.subTest(side=side):
                self.save(sidecar=side)
                with self.assertRaises(ValueError):
                    self.m.configure(self.root)
        self.assertFalse(self.calls())

    def test_no_default_login_or_allocation_helper(self):
        self.assertIsNone(self.m.ME)
        self.assertEqual(self.m.REPOS, ())
        self.assertFalse(hasattr(self.m, 'reserve_lane'))

    def test_alias_first_configured(self):
        self.save(base={**self.config, 'aliases': {'first': 'example/project', 'short': 'example/project'}})
        self.m.configure(self.root)
        self.assertEqual(self.m.repo_alias('example/project'), 'first')
        self.assertEqual(self.m.repo_alias('other/repository'), 'repository')

    def test_me_precedence_and_no_default_login(self):
        self.reply({'body': {'total_count': 0, 'items': [], 'incomplete_results': False}})
        self.assertEqual(self.main('--me', 'override-user', '--no-save')[0], 0)
        self.assertTrue(any('override-user' in str(c['args']) for c in self.calls()))
        self.assertFalse(any(c['args'][-1:] == ['user'] for c in self.calls()))

    def test_identity_discovery_and_failure(self):
        self.save(base={'repos': ['example/project']})
        self.reply({'body': {'login': 'discovered-user'}}, {'body': {'total_count': 0, 'items': [], 'incomplete_results': False}})
        self.assertEqual(self.main('--no-save')[0], 0)
        self.assertTrue(any('discovered-user' in str(c['args']) for c in self.calls()))
        self.log.unlink()
        self.reply({'body': {}})
        code, out, _ = self.main()
        self.assertEqual(code, 0)
        self.assertIn('unknown', out.lower())
        self.assertEqual(len(self.calls()), 1)
        self.assertFalse((self.root / '.morning-last-run').exists())

    def test_complete_sweep_advances_stamp(self):
        self.assertEqual(self.main()[0], 0)
        self.assertTrue((self.root / '.morning-last-run').read_text().endswith('Z'))
        self.assertTrue(all(c['notifier'] == '1' for c in self.calls()))

    def test_unknown_activity_retains_stamp(self):
        stamp = self.root / '.morning-last-run'
        stamp.write_text('2026-01-01T00:00Z')
        self.reply({'body': {'errors': [{'message': 'offline'}]}})
        code, out, _ = self.main()
        self.assertEqual(code, 0)
        self.assertIn('unknown', out.lower())
        self.assertEqual(stamp.read_text(), '2026-01-01T00:00Z')

    def test_check_no_save_writes_receipts_not_stamp(self):
        self.assertEqual(self.main('--check', '--no-save')[0], 0)
        self.assertTrue((self.root / 'STATE-DRIFT.md').exists())
        self.assertTrue((self.root / 'STATE-DRIFT-folders.txt').exists())
        self.assertFalse((self.root / '.morning-last-run').exists())

    def test_missing_state_keeps_old_receipt(self):
        path = self.root / 'STATE-DRIFT.md'
        path.write_text('previous')
        (self.root / 'STATE.md').unlink()
        self.assertEqual(self.main('--check')[0], 1)
        self.assertEqual(path.read_text(), 'previous')

    def test_absent_or_reserved_collectors_are_not_checked(self):
        self.save(sidecar={'checkouts': [{'repo': 'example/project', 'path': 'missing'}], 'disk': {'filesystem': '~'}})
        code, out, _ = self.main()
        self.assertEqual(code, 0)
        self.assertIn('not checked', out.lower())
        self.assertTrue((self.root / '.morning-last-run').exists())

    def test_atomic_failure_preserves_previous_file(self):
        path = self.root / 'previous'
        path.write_text('old')
        with patch.object(self.m.os, 'replace', side_effect=OSError('failure')):
            with self.assertRaises(OSError):
                self.m.atomic_write(path, 'new')
        self.assertEqual(path.read_text(), 'old')
        self.assertEqual(sorted(p.name for p in self.root.iterdir() if 'previous' in p.name), ['previous'])

    def test_short_page_next_link_is_not_final(self):
        url = 'https://api.github.com/notifications?page=2&per_page=100'
        self.reply({'body': [{'n': 1}], 'headers': {'Link': '<'+url+'>; rel="next"'}}, {'body': [{'n': 2}]})
        client = self.m.GitHub()
        self.assertEqual(client.pages('notifications', since='2026-01-01'), [{'n': 1}, {'n': 2}])
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        self.assertIn(url, calls[1]['args'])
        self.assertNotIn('-f', calls[1]['args'])
        self.assertNotIn('--paginate', str(calls))

    def test_untrusted_next_url_is_unknown(self):
        self.reply({'body': [], 'headers': {'Link': '<https://other.invalid/private>; rel="next"'}})
        client = self.m.GitHub()
        self.assertIsNone(client.pages('notifications'))
        self.assertTrue(client.activity_failures)
        self.assertEqual(len(self.calls()), 1)

    def test_late_page_error_discards_partial_coverage(self):
        self.reply({'body': [1], 'headers': {'Link': '<https://api.github.com/items?page=2>; rel="next"'}}, {'raw': '{bad'})
        client = self.m.GitHub()
        self.assertIsNone(client.pages('items'))
        self.assertTrue(client.activity_failures)

    def test_count_bound_stops_all_requests(self):
        self.reply({'body': {'total_count': 0, 'items': [], 'incomplete_results': False}})
        self.save(sidecar={'limits': {'queries': 1}})
        code, out, _ = self.main()
        self.assertEqual(code, 0)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn('budget', out.lower())
        self.assertFalse((self.root / '.morning-last-run').exists())

    def test_monotonic_deadline_stops_requests(self):
        now = [0.0]
        budget = self.m.Budget(clock=lambda: now[0])
        self.assertTrue(budget.request())
        now[0] = 296
        self.assertFalse(budget.request())

    def test_timeout_and_capture_overflow_are_unknown(self):
        for reply in ({'sleep': 2}, {'raw': 'x' * (16 * 1024 * 1024 + 1)}):
            with self.subTest(reply=list(reply)):
                self.reply(reply)
                with self.assertRaises(self.m.ObservationError):
                    self.m.run_read(['gh', 'api', 'user'], timeout=.1 if 'sleep' in reply else 5,
                                    budget=self.m.Budget())

    def test_large_valid_page_above_two_mib(self):
        body = [{'body': 'x' * (3 * 1024 * 1024)}]
        self.reply({'body': body})
        self.assertEqual(self.m.GitHub().pages('items'), body)

    def test_unknown_check_states_are_not_green(self):
        self.assertEqual(self.m.checks_summary([{'state': 'STALE'}]), 'unknown')
        self.assertEqual(self.m.checks_summary([{'conclusion': 'SUCCESS'}]), 'green')
        self.assertEqual(self.m.checks_summary([]), 'none')

    def test_hostile_text_has_no_terminal_controls_or_markdown_injection(self):
        value = self.m.safe_text('title\x1b[2J\n## forged | <tag>')
        self.assertNotIn('\x1b', value)
        self.assertNotIn('\n', value)
        self.assertNotIn('<tag>', value)

    def pr_reply(self, checks=(), *, truncated=False, head=None):
        oid = 'a' * 40
        return {'body': {'data': {'repository': {'pullRequest': {
            'state': 'OPEN', 'isDraft': False, 'headRefOid': head or oid,
            'reviewDecision': None, 'mergeStateStatus': 'CLEAN',
            'url': 'https://github.com/example/project/pull/1',
            'commits': {'nodes': [{'commit': {'oid': oid, 'statusCheckRollup': {
                'contexts': {'nodes': list(checks), 'pageInfo': {'hasNextPage': truncated}}}}}]}}}}}}

    def test_pr_metadata_shape_parity_and_context_truncation(self):
        checks = [dict(__typename='CheckRun', conclusion='FAILURE', status='COMPLETED',
                       completedAt='2026-01-01T00:00:00Z', createdAt='2026-01-01T00:00:00Z',
                       checkSuite={'commit': {'oid': 'a' * 40}})]
        self.reply(self.pr_reply(checks))
        data = self.m.GitHub().pr('example/project', 1)
        self.assertEqual(self.m.checks_summary(data['statusCheckRollup']), 'red')
        self.assertEqual(self.m.red_age(data['statusCheckRollup'], self.m.dt.datetime(2026, 1, 2, tzinfo=self.m.dt.timezone.utc)), '24h')
        for response in (self.pr_reply(checks, truncated=True), self.pr_reply(checks, head='b' * 40), self.pr_reply([{'__typename': 'StatusContext', 'state': 'STALE', 'commit': {'oid': 'a' * 40}}])):
            self.reply(response)
            client = self.m.GitHub()
            self.assertIsNone(client.pr('example/project', 1))
            self.assertTrue(client.activity_failures)

    def test_receipt_publication_failure_is_nonzero(self):
        with patch.object(self.m, 'atomic_write', side_effect=OSError('failure')):
            self.assertEqual(self.main('--check')[0], 1)

    def test_http_and_graphql_errors_are_unknown_without_stderr_leak(self):
        for response in ({'exit': 1, 'stderr': 'sensitive-response'}, {'body': {'errors': [{'message': 'sensitive-response'}]}}, {'raw': '{bad'}, {'body': None}):
            self.reply(response)
            client = self.m.GitHub()
            data = client.gh('api', 'user')
            self.assertIsNone(data)
            self.assertTrue(client.activity_failures)
            self.assertNotIn('sensitive-response', str(client.failures))

    def test_nonfinal_notification_url_has_no_duplicate_query_fields(self):
        self.reply({'body': [], 'headers': {'Link': '<https://api.github.com/notifications?page=2>; rel="next"'}}, {'body': []})
        self.m.GitHub().pages('notifications', all='true', since='2026-01-01')
        self.assertEqual(self.calls()[-1]['args'], ['api', '-X', 'GET', 'https://api.github.com/notifications?page=2', '--include'])

    def test_timeout_kills_descendant_holding_pipe(self):
        if not hasattr(os, 'fork'):
            self.skipTest('POSIX process groups')
        pid_file = self.root / 'pid'
        code = ('import os,time,pathlib; p=os.fork(); '
                f'pathlib.Path({str(pid_file)!r}).write_text(str(p)) if p else None; '
                'time.sleep(10) if not p else None')
        with self.assertRaises(self.m.ObservationError):
            self.m.run_read([sys.executable, '-c', code], timeout=.2, budget=self.m.Budget())
        child = int(pid_file.read_text())
        proc = pathlib.Path(f'/proc/{child}/stat')
        deadline = time.monotonic() + 1
        while proc.exists() and proc.read_text().split()[2] not in ('Z', 'X') and time.monotonic() < deadline:
            time.sleep(.005)
        if proc.exists():
            self.assertIn(proc.read_text().split()[2], ('Z', 'X'))

    def test_original_base_key_vocabulary_is_unchanged(self):
        self.assertEqual(self.m.BASE_KEYS, {'repos', 'ours', 'own_only', 'watch', 'aliases', 'notifications',
            'internal_tracker', 'me', 'record_files', 'shared_root', 'decision_prefix', 'lane_prefix', 'tracked_series'})

    def test_activity_window_and_no_save_are_compatible(self):
        stamp = self.root / '.morning-last-run'
        stamp.write_text('2026-01-01T00:00Z')
        self.assertEqual(self.main('--since', '2026-02-01T00:00Z', '--no-save')[0], 0)
        self.assertEqual(stamp.read_text(), '2026-01-01T00:00Z')
        self.assertIn('2026-02-01T00:00:00Z', str(self.calls()))

    def issue_item(self, number, repo='example/project'):
        return dict(repository_url=f'https://api.github.com/repos/{repo}', number=number,
                    html_url=f'https://github.com/{repo}/issues/{number}', title='Example',
                    user={'login': 'other-user'}, created_at='2026-01-02T00:00:00Z')

    def test_updated_issue_comments_count_toward_global_budget(self):
        self.save(base={**self.config, 'ours': ['example/project']})
        self.m.configure(self.root)
        client = self.m.GitHub(self.m.Budget(queries=1))
        client.search = lambda query, host=None: [self.issue_item(1), self.issue_item(2)] if 'is:issue updated:' in query else []
        self.reply({'body': []})
        report = self.m.sweep(client, '2026-01-01T00:00:00Z', 'example-user')
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(client.budget.request_count, 1)
        self.assertTrue(client.activity_failures)
        section = report.split('## New human comments on existing issues in our repos')[1].split('\n## ')[0]
        self.assertIn('unknown', section)

    def test_enterprise_tracker_comments_count_toward_global_budget(self):
        self.save(base={**self.config, 'internal_tracker': True}, sidecar={
            'internal_tracker_source': {'host': 'git.example.test', 'repo': 'example/tracker'}})
        self.m.configure(self.root)
        client = self.m.GitHub(self.m.Budget(queries=2))
        client.search = lambda query, host=None: [self.issue_item(1, 'example/tracker'), self.issue_item(2, 'example/tracker')] if host else []
        self.reply({'body': {'login': 'internal-user'}}, {'body': []})
        report = self.m.sweep(client, '2026-01-01T00:00:00Z', 'example-user')
        self.assertEqual(len(self.calls()), 2)
        self.assertTrue(client.activity_failures)
        self.assertIn('comments unknown', report)

    def test_old_folder_walk_failure_is_unknown(self):
        self.m.configure(self.root)
        folder = self.root / 'w1-output'
        folder.mkdir()
        old = time.time() - 15 * 86400
        os.utime(folder, (old, old))
        with patch.object(self.m.os, 'walk', return_value=iter([(str(folder), [], ['missing'])])):
            with self.assertRaises(self.m.ObservationError):
                self.m.old_folders('', self.m.dt.datetime.now(self.m.dt.timezone.utc), self.m.Budget())

    def empty_search(self):
        return {'body': {'total_count': 0, 'items': [], 'incomplete_results': False}}

    def test_partially_malformed_link_does_not_advance_stamp(self):
        self.save(base={**self.config, 'notifications': True})
        stamp = self.root / '.morning-last-run'
        stamp.write_text('2026-01-01T00:00Z')
        self.reply(*([self.empty_search()] * 6),
            {'body': [], 'headers': {'Link': '<https://api.github.com/notifications?page=2>; rel="next"'}},
            {'body': [], 'headers': {'Link': '<https://api.github.com/notifications?page=1>; rel="prev", <https://api.github.com/notifications?page=3>; rel="nex'}})
        code, out, _ = self.main()
        self.assertEqual(code, 0)
        self.assertIn('unknown', out.lower())
        self.assertEqual(stamp.read_text(), '2026-01-01T00:00Z')
        self.assertEqual(len(self.calls()), 8)

    def test_null_context_connection_does_not_advance_stamp(self):
        stamp = self.root / '.morning-last-run'
        stamp.write_text('2026-01-01T00:00Z')
        item = self.issue_item(1)
        item['pull_request'] = {}
        pr = self.pr_reply()
        pr['body']['data']['repository']['pullRequest']['commits']['nodes'][0]['commit']['statusCheckRollup']['contexts'] = None
        threads = {'body': {'data': {'repository': {'pullRequest': {'reviewThreads': {
            'nodes': [], 'pageInfo': {'hasNextPage': False, 'endCursor': None}}}}}}}
        self.reply(*([self.empty_search()] * 5),
            {'body': {'total_count': 1, 'items': [item], 'incomplete_results': False}}, pr, threads, {'body': []})
        code, out, _ = self.main()
        self.assertEqual(code, 0)
        self.assertIn('unknown', out.lower())
        self.assertEqual(stamp.read_text(), '2026-01-01T00:00Z')
        self.assertNotIn('none, clean', out)

    def test_missing_internal_identity_does_not_advance_stamp(self):
        self.save(base={**self.config, 'internal_tracker': True}, sidecar={
            'internal_tracker_source': {'host': 'git.example.test', 'repo': 'example/tracker'}})
        stamp = self.root / '.morning-last-run'
        stamp.write_text('2026-01-01T00:00Z')
        item = self.issue_item(1, 'example/tracker')
        self.reply(*([self.empty_search()] * 6),
            {'body': {'total_count': 1, 'items': [item], 'incomplete_results': False}}, {'body': {}}, {'body': []})
        code, out, _ = self.main()
        self.assertEqual(code, 0)
        self.assertIn('unknown', out.lower())
        self.assertEqual(stamp.read_text(), '2026-01-01T00:00Z')

    def test_check_identity_failure_publishes_unknown_receipt(self):
        self.save(base={'repos': ['example/project']})
        self.reply({'body': {}})
        code, out, _ = self.main('--check')
        self.assertEqual(code, 0)
        path = self.root / 'STATE-DRIFT.md'
        self.assertTrue(path.exists())
        self.assertIn('unknown', path.read_text().lower())
        self.assertEqual(len(self.calls()), 1)
        self.assertNotIn('author:None', str(self.calls()))

    def test_check_malformed_data_is_nonzero_and_preserves_receipt(self):
        path = self.root / 'STATE-DRIFT.md'
        path.write_text('previous receipt')
        self.reply({'body': {'total_count': 1, 'items': [{}], 'incomplete_results': False}})
        code, out, _ = self.main('--check')
        self.assertEqual(code, 1)
        self.assertIn('unknown', out.lower())
        self.assertEqual(path.read_text(), 'previous receipt')

    def test_space_separated_since_is_canonical_not_search_free_text(self):
        code, out, _ = self.main('--since', '2026-01-01 09:00', '--no-save')
        self.assertEqual(code, 0)
        query_args = [arg for call in self.calls() for arg in call['args'] if arg.startswith('q=') and 'updated:>=' in arg]
        self.assertTrue(query_args)
        self.assertTrue(all('2026-01-01T09:00:00Z' in arg for arg in query_args))
        self.assertFalse(any('09:00 ' in arg or '01-01 09:' in arg for arg in query_args))

    def test_null_api_user_is_reported_without_traceback(self):
        item = self.issue_item(1)
        item['user'] = None
        item['pull_request'] = {}
        self.save(base={**self.config, 'own_only': ['example/project']})
        self.reply(*([self.empty_search()] * 4), {'body': {'total_count': 1, 'items': [item], 'incomplete_results': False}})
        try:
            code, out, _ = self.main()
        except AttributeError:
            self.fail('malformed external user escaped the normal unknown path')
        self.assertEqual(code, 0)
        self.assertIn('unknown', out.lower())
        self.assertFalse((self.root / '.morning-last-run').exists())

    def test_summary_url_and_notification_fields_are_sanitized(self):
        activity = self.m.Activity(self.m.GitHub(), '2026-01-01', 'example-user')
        item = self.issue_item(1)
        item['html_url'] = 'https://github.com/example/project/issues/1\x1b[2J'
        activity.record(item, {'login': 'other-user'}, 'opened', '2026-01-02T00:00:00Z', 1)
        self.assertNotIn('\x1b', activity.summary([]))
        self.save(base={**self.config, 'notifications': True})
        self.reply(*([self.empty_search()] * 6), {'body': [{'repository': {'full_name': 'other\x1b[2J/project'},
            'reason': 'subscribed\n##forged', 'subject': {'title': 'Title', 'url': 'javascript:example'}}]})
        code, out, _ = self.main('--no-save')
        self.assertEqual(code, 0)
        self.assertNotIn('\x1b', out)
        self.assertNotIn('\n##forged', out)
        self.assertNotIn('javascript:', out)

    def test_tracked_series_input_failure_keeps_stamp(self):
        self.save(base={**self.config, 'tracked_series': [{'repo': 'example/project', 'title': 'Review', 'tracker': 'missing.csv'}]})
        self.assertEqual(self.main()[0], 0)
        self.assertFalse((self.root / '.morning-last-run').exists())


if __name__ == '__main__':
    unittest.main()
