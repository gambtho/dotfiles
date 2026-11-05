"""Optional local observations: real collectors against controlled tool boundaries."""
import json
import os
import pathlib
import unittest
from unittest.mock import patch

import test_lane_morning as fixtures

TOOLS = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = [name, *sys.argv[1:]]
with open(os.environ['LOCAL_LOG'], 'a') as f:
    f.write(json.dumps({'args':args,'locks':os.environ.get('GIT_OPTIONAL_LOCKS')})+'\\n')
r = json.loads(pathlib.Path(os.environ['LOCAL_RESPONSES']).read_text()).get(json.dumps(args))
if r is None:
    sys.stderr.write('unexpected tool invocation')
    sys.exit(9)
sys.stdout.write(r['out'])
sys.exit(r.get('exit',0))
'''
SHA = 'a' * 40


class LocalObservationsTests(unittest.TestCase):
    def setUp(self):
        self.case = fixtures.MorningTests()
        self.case.setUp()
        self.addCleanup(self.case.doCleanups)
        self.m, self.root = self.case.m, self.case.root
        self.responses, self.log = self.root / 'local-responses.json', self.root / 'local-log.jsonl'
        self.rows = {}
        self.responses.write_text('{}')
        for name in ('git', 'df', 'du', 'make'):
            path = self.case.bin / name
            path.write_text(TOOLS)
            path.chmod(0o755)
        self.env = patch.dict(os.environ, LOCAL_LOG=str(self.log), LOCAL_RESPONSES=str(self.responses))
        self.env.start()
        self.addCleanup(self.env.stop)
        self.checkout = self.root / 'checkout with spaces'
        self.checkout.mkdir()
        self.tool(['git', '-C', str(self.root), 'rev-parse', 'HEAD'], SHA+'\n')

    def tool(self, args, out='', code=0):
        self.rows[json.dumps(args)] = {'out': out, 'exit': code}
        self.responses.write_text(json.dumps(self.rows))

    def settings(self, **settings):
        self.case.save(sidecar=settings)
        self.m.configure(self.root)

    def git(self, records=None, status=None):
        if records is None:
            records = f'worktree {self.checkout}\0HEAD {SHA}\0branch refs/heads/topic\0\0'
        if status is None:
            status = f'# branch.oid {SHA}\0# branch.head topic\0# branch.upstream origin/main\0# branch.ab +2 -1\0'
        self.tool(['git','-C',str(self.checkout),'status','--porcelain=v2','--branch','-z'], status)
        self.tool(['git','-C',str(self.checkout),'worktree','list','--porcelain','-z'], records)

    def inventory(self, opened=(), closed=(), partial=False):
        def connection(nodes):
            return {'nodes': list(nodes), 'pageInfo': {'hasNextPage': partial}}
        return {'body': {'data': {'repository': {'open': connection(opened), 'closed': connection(closed)}}}}

    def pr(self, state='OPEN', repo='example/project', number=7):
        return {'number': number, 'state': state, 'headRefName': 'topic', 'headRefOid': SHA,
                'headRepository': {'nameWithOwner': repo}, 'url': f'https://github.com/{repo}/pull/{number}'}

    def collect(self, name):
        function = getattr(self.m, name, None)
        assert callable(function), name+' collector missing'
        client = self.m.GitHub()
        return function(client), client

    def calls(self):
        return [json.loads(row) for row in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_primary_cleanliness_tracking_and_same_repo_mapping(self):
        self.settings(checkouts=[{'repo':'example/project','path':str(self.checkout)}])
        self.git()
        self.case.reply(self.inventory([self.pr()]))
        text, client = self.collect('checkout_observations')
        for expected in ('clean', 'topic', '+2 -1', 'local', '#7', 'OPEN', 'checkout with spaces'):
            self.assertIn(expected, text)
        self.assertEqual(client.budget.request_count, 1)
        self.assertFalse(client.activity_failures)
        self.assertTrue(all(call['locks']=='0' for call in self.calls()))
        self.assertFalse(any('fetch' in call['args'] or 'prune' in call['args'] for call in self.calls()))

    def test_mapping_fork_ambiguity_partial_and_closed_states(self):
        self.settings(checkouts=[{'repo':'example/project','path':str(self.checkout)}])
        self.git()
        for opened, closed, partial, want in (
            ([self.pr(repo='other/project')], [], False, 'no open/recent'),
            ([self.pr(), self.pr(number=8)], [], False, 'ambiguous'),
            ([self.pr()], [], True, 'partial'),
            ([], [self.pr('MERGED')], False, 'MERGED'),
            ([], [self.pr('CLOSED')], False, 'CLOSED')):
            with self.subTest(want=want):
                self.case.reply(self.inventory(opened, closed, partial))
                text, client = self.collect('checkout_observations')
                self.assertIn(want, text)
                self.assertFalse(client.activity_failures)
                self.assertNotIn('safe to delete', text)

    def test_complete_open_inventory_survives_partial_closed_history_and_is_cached(self):
        self.settings(checkouts=[{'repo':'example/project','path':str(self.checkout)}] * 2)
        self.git()
        response = self.inventory([self.pr()])
        response['body']['data']['repository']['closed']['pageInfo']['hasNextPage'] = True
        self.case.reply(response)
        text, client = self.collect('checkout_observations')
        self.assertIn('OPEN [#7]', text)
        self.assertNotIn('partial PR inventory', text)
        self.assertEqual(client.budget.request_count, 1)

    def test_unresolvable_configured_paths_are_supplemental_unknowns(self):
        for name, settings in (
            ('checkout_observations', {'checkouts':[{'repo':'example/project','path':'unresolvable'}]}),
            ('disk_observations', {'disk':{'filesystem':'unresolvable'}})):
            with self.subTest(collector=name):
                self.settings(**settings)
                with patch.object(pathlib.Path, 'resolve', side_effect=RuntimeError('path unavailable')):
                    try:
                        text, client = self.collect(name)
                    except RuntimeError:
                        self.fail('configured path resolution escaped supplemental unknown handling')
                self.assertIn('unknown', text.lower())
                self.assertFalse(client.activity_failures)

    def test_disk_subdeadline_cannot_use_more_than_120_seconds(self):
        cache = self.root/'cache'
        cache.mkdir()
        self.settings(disk={'filesystem':str(self.root),'caches':{'go':str(cache)}})
        self.tool(['df','-Pk',str(self.root)], 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/test 100 1 99 1% /\n')
        now, remaining = [0], []
        client = self.m.GitHub(self.m.Budget(clock=lambda: now[0]))
        original = self.m.run_read
        def advance(*args, **kwargs):
            remaining.append(kwargs['budget'].remaining())
            result = original(*args, **kwargs)
            now[0] += 121
            return result
        function = getattr(self.m, 'disk_observations', None)
        assert callable(function)
        with patch.object(self.m, 'run_read', side_effect=advance):
            text = function(client)
        self.assertLessEqual(max(remaining),120)
        self.assertIn('unknown',text.lower())
        self.assertFalse(client.activity_failures)
        self.assertEqual([call['args'][0] for call in self.calls()],['df'])

    def test_folder_and_worktree_enumeration_caps_are_explicit(self):
        outputs = self.root/'outputs'
        outputs.mkdir()
        for n in range(102):
            (outputs/f'out{n}').mkdir()
        self.settings(disk={'output_roots':[str(outputs)]})
        with patch.object(self.m, 'run_read', return_value='1\tmeasured\n') as read:
            text, _ = self.collect('disk_observations')
        self.assertIn('partial', text.lower())
        self.assertEqual(read.call_count,100)
        records = (f'worktree {self.checkout}\0HEAD {SHA}\0detached\0\0') * 101
        self.settings(checkouts=[{'repo':'example/project','path':str(self.checkout)}])
        self.git(records)
        text, _ = self.collect('checkout_observations')
        self.assertIn('unknown', text.lower())
        self.assertIn('100', text)

    def test_detached_missing_prunable_and_dirty_entries_are_explicit(self):
        missing = self.root / 'removed worktree'
        records = (f'worktree {self.checkout}\0HEAD {SHA}\0detached\0\0'
                   f'worktree {missing}\0HEAD {SHA}\0branch refs/heads/topic\0prunable missing metadata\0\0')
        self.settings(checkouts=[{'repo':'example/project','path':str(self.checkout)}])
        self.git(records, f'# branch.oid {SHA}\0# branch.head (detached)\0? file with spaces\0')
        text, client = self.collect('checkout_observations')
        for value in ('dirty', 'detached', 'missing', 'prunable'):
            self.assertIn(value, text.lower())
        self.assertEqual(client.budget.request_count, 0)

    def test_nul_rename_path_cannot_replace_branch_headers(self):
        self.settings(checkouts=[{'repo':'example/project','path':str(self.checkout)}])
        self.git(status=f'# branch.oid {SHA}\0# branch.head topic\0' +
                        '2 R. N... 100644 100644 100644 old new R100 new name\0# branch.head forged\0')
        self.case.reply(self.inventory([self.pr()]))
        text, _ = self.collect('checkout_observations')
        self.assertIn('dirty',text)
        self.assertNotIn('forged',text)

    def test_malformed_git_and_exhausted_inventory_are_unknown(self):
        self.settings(checkouts=[{'repo':'example/project','path':str(self.checkout)}], limits={'queries':1})
        self.git(records='truncated output')
        text, client = self.collect('checkout_observations')
        self.assertIn('unknown', text.lower())
        self.assertFalse(client.activity_failures)
        self.git()
        client.budget.request_count = 1
        text = self.m.checkout_observations(client)
        self.assertIn('unknown', text.lower())
        self.assertFalse(client.activity_failures)

    def test_disk_floor_uses_available_kib_not_total_or_used(self):
        self.settings(disk={'filesystem':str(self.root),'minimum_free_gib':50})
        for available, low in ((50*1024*1024,False),(50*1024*1024-1,True)):
            self.tool(['df','-Pk',str(self.root)], f'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/test 999999999 1 {available} 10% /\n')
            text, client = self.collect('disk_observations')
            self.assertEqual('Needs the human' in text, low)
            self.assertFalse(client.activity_failures)

    def test_top_five_excludes_files_symlinks_and_overlapping_candidates(self):
        outputs = self.root / 'outputs'
        outputs.mkdir()
        (outputs/'prompt.md').write_text('not a folder')
        candidates = [outputs / f'out{n}' for n in range(7)]
        for n, folder in enumerate(candidates):
            folder.mkdir()
            self.tool(['du','-sk',str(folder)], f'{(n+1)*1024}\t{folder}\n')
        nested = candidates[-1] / 'nested'
        nested.mkdir()
        (outputs/'linked').symlink_to(self.checkout, target_is_directory=True)
        self.settings(disk={'output_roots':[str(outputs),str(candidates[-1]),str(outputs)]})
        text, _ = self.collect('disk_observations')
        self.assertIn('out6', text)
        self.assertNotIn('out0', text)
        self.assertNotIn('out1', text)
        measured = [call['args'][-1] for call in self.calls() if call['args'][0]=='du']
        self.assertEqual(len(measured),7)
        self.assertNotIn(str(nested), measured)
        self.assertNotIn(str(outputs/'linked'), measured)

    def test_partial_ranking_and_missing_cache_are_not_zero_or_clean(self):
        outputs = self.root / 'outputs'
        outputs.mkdir()
        (outputs/'failed').mkdir()
        self.settings(disk={'output_roots':[str(outputs)],'caches':{'go':'missing-cache'}})
        text, client = self.collect('disk_observations')
        self.assertIn('partial', text.lower())
        self.assertIn('absent', text.lower())
        self.assertIn('unknown', text.lower())
        self.assertFalse(client.activity_failures)

    @unittest.skipIf(os.geteuid()==0, 'root can traverse a mode-000 directory')
    def test_inaccessible_cache_is_unknown_not_absent(self):
        parent = self.root/'blocked'
        parent.mkdir()
        (parent/'cache').mkdir()
        self.settings(disk={'caches':{'go':str(parent/'cache')}})
        parent.chmod(0)
        try:
            text, client = self.collect('disk_observations')
        finally:
            parent.chmod(0o700)
        self.assertIn('unknown',text.lower())
        self.assertNotIn('absent',text.lower())
        self.assertFalse(client.activity_failures)

    def test_cache_exit_zero_is_not_health_and_fixed_make_argv(self):
        self.settings(disk={'cache_check_checkout':str(self.checkout)})
        argv = ['make','-s','--no-print-directory','-C',str(self.checkout),'cache-maintenance-check']
        for output, want in (
            ('cache-maintenance: not installed; opt in with make cache-maintenance\n','not installed'),
            ('timer table\ncache-maintenance: service has never run\nLogs: journalctl\n','never run'),
            ('timer table\nResult=exit-code\nExecMainStatus=1\nExecMainStartTimestamp=Wed\n','failed'),
            ('timer table\nResult=success\nExecMainStatus=0\nExecMainStartTimestamp=Wed\n','successful'),
            ('unexpected format\n','unknown')):
            with self.subTest(want=want):
                self.tool(argv, output)
                text, client = self.collect('disk_observations')
                self.assertIn(want, text.lower())
                self.assertFalse(client.activity_failures)
        self.assertTrue(all(call['args']==argv for call in self.calls()))

    def test_local_failures_do_not_freeze_complete_activity_stamp(self):
        self.settings(disk={'filesystem':str(self.root),'cache_check_checkout':str(self.checkout)})
        code, out, _ = self.case.main()
        self.assertEqual(code,0)
        self.assertIn('unknown', out.lower())
        self.assertTrue((self.root/'.morning-last-run').exists())

    def test_check_mapping_precedes_state_queries_and_keeps_stamp(self):
        self.settings(checkouts=[{'repo':'example/project','path':str(self.checkout)}])
        self.git()
        self.case.reply(self.inventory([self.pr()]), {'body':{'total_count':0,'items':[],'incomplete_results':False}})
        stamp = self.root/'.morning-last-run'
        stamp.write_text('old boundary')
        code, out, _ = self.case.main('--check','--no-save')
        self.assertEqual(code,0)
        self.assertIn('OPEN',out)
        self.assertIn('pullRequests', str(self.case.calls()[0]))
        self.assertEqual(stamp.read_text(),'old boundary')
        self.assertIn('Checkout/worktrees',(self.root/'STATE-DRIFT.md').read_text())


if __name__ == '__main__':
    unittest.main()
