#!/usr/bin/env python3
"""Explicit, inherited-session-only Pi launch. No delivery retries or UI keys."""
import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


class LaunchError(ValueError):
    pass


def lane_name(project, lane, override=None):
    if not re.fullmatch(r'[a-z][a-z0-9-]*', project):
        raise LaunchError('Use the established lowercase project slug')
    if not re.fullmatch(r'W[1-9][0-9]*', lane):
        raise LaunchError('Lane must be W followed by a positive number')
    name = f'{project}-{lane[1:]}' if override is None else override
    if not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', name):
        raise LaunchError('Name must match [a-z][a-z0-9_-]{0,31}; never truncate')
    return name


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic_write(path, text):
    """Flush checkpoints before side effects, including the containing directory."""
    fd, temporary = tempfile.mkstemp(prefix=f'.{path.name}.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def call(*argv, kind, timeout=10):
    try:
        completed = subprocess.run(['herdr', *argv], capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        raise LaunchError(f'{argv[0:2]} timed out; effects may be uncertain') from exc
    if completed.returncode:
        # Do not copy terminal output or arbitrary stderr into durable state.
        raise LaunchError(f'{argv[0:2]} failed (exit {completed.returncode}); inspect recorded target')
    try:
        envelope = mapping(json.loads(completed.stdout), 'envelope')
        result = mapping(envelope.get('result'), 'result')
        if result['type'] != kind:
            raise ValueError('Unexpected response type')
        return result
    except (ValueError, KeyError, TypeError) as exc:
        raise LaunchError(f'{argv[0:2]} returned malformed JSON; effects may be uncertain') from exc


def mapping(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        raise LaunchError(f'Invalid response object: {label}')
    return value


def object_list(value: object, label: str) -> list[dict]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise LaunchError(f'Invalid response collection: {label}')
    return value


def string(obj, key):
    value = obj.get(key)
    if not isinstance(value, str) or not value or any(ord(c) < 32 for c in value):
        raise LaunchError(f'Invalid response field: {key}')
    return value


def git(*argv, cwd):
    try:
        done = subprocess.run(['git', '-C', str(cwd), *argv], capture_output=True, text=True, timeout=30, check=False)
    except subprocess.TimeoutExpired as exc:
        raise LaunchError(f'git {argv[0]} timed out; inspect, do not retry') from exc
    if done.returncode:
        raise LaunchError(f'git {argv[0]} failed (exit {done.returncode}); inspect, do not retry')
    return done.stdout.splitlines()


def inherited_context(session):
    required = ('HERDR_SOCKET_PATH', 'HERDR_PANE_ID', 'HERDR_WORKSPACE_ID')
    if os.environ.get('HERDR_ENV') != '1' or any(not os.environ.get(k) for k in required):
        raise LaunchError('Manual handoff: missing inherited Herdr context')
    inherited = os.environ.get('HERDR_SESSION')
    if inherited is not None and (not inherited or inherited != session):
        raise LaunchError('Manual handoff: intended and inherited sessions differ')
    socket = Path(os.environ['HERDR_SOCKET_PATH'])
    if not socket.is_absolute() or not stat.S_ISSOCK(socket.stat().st_mode):
        raise LaunchError('Manual handoff: inherited socket is not an absolute local socket')
    if inherited is None:
        # Default-session panes can omit HERDR_SESSION. Verify inventory identity
        # without guessing a session name, changing env, or selecting a socket.
        try:
            listed = subprocess.run(['herdr', 'session', 'list', '--json'],
                                    capture_output=True, text=True, timeout=10, check=True)
            sessions = object_list(mapping(json.loads(listed.stdout), 'session list').get('sessions'), 'sessions')
        except (subprocess.SubprocessError, ValueError, KeyError, TypeError) as exc:
            raise LaunchError('Manual handoff: default session could not be verified') from exc
        defaults = [entry for entry in sessions if entry.get('default') is True]
        if (len(defaults) != 1 or defaults[0].get('name') != session
                or defaults[0].get('socket_path') != os.environ['HERDR_SOCKET_PATH']):
            raise LaunchError('Manual handoff: listed default does not match intended session and inherited socket')
    info = socket.stat()
    return {'session': session, 'socket': str(socket), 'socket_device': info.st_dev,
            'socket_inode': info.st_ino, 'caller': os.environ['HERDR_PANE_ID'],
            'workspace': os.environ['HERDR_WORKSPACE_ID']}


def snapshot(context):
    live = mapping(call('api', 'snapshot', kind='session_snapshot').get('snapshot'), 'snapshot')
    protocol = live.get('protocol')
    if type(protocol) is not int or not (
            protocol == 19 or (protocol == 22 and live.get('version') == '0.9.5')):
        raise LaunchError('Unsupported Herdr protocol/version; inspect installed capabilities, do not update')
    for key in ('panes', 'workspaces', 'agents'):
        object_list(live.get(key), key)
    caller = [p for p in live['panes'] if p['pane_id'] == context['caller']
              and p['workspace_id'] == context['workspace']]
    if len(caller) != 1:
        raise LaunchError('Inherited caller does not match live context')
    context['terminal'] = string(caller[0], 'terminal_id')
    return live


def state_row(text, lane):
    rows = [i for i, line in enumerate(text.splitlines())
            if line.startswith('|') and line.split('|')[1].strip() == lane]
    if len(rows) != 1 or len(text.splitlines()[rows[0]].split('|')) != 7:
        raise LaunchError('STATE must contain one five-column lane row (last column Launch)')
    return rows[0]


class Launch:
    def __init__(self, args, context, live):
        self.args, self.context, self.live = args, context, live
        self.path = args.prompt.parent / f'{args.lane}-launch.json'
        self.record: dict = {}
        self.lock = self.group = None

    def checkpoint(self, stage=None, **fields):
        if stage:
            self.record.pop('error', None)
            self.record['stage'] = stage
            self.record.setdefault('checkpoints', {})[stage] = datetime.now(timezone.utc).isoformat()
        self.record.update(fields)
        atomic_write(self.path, json.dumps(self.record, indent=2) + '\n')

    def creation_check(self, source, field, expected, observed, matches=None):
        matches = observed == expected if matches is None else matches
        if not matches:
            # Keep only selected scalar evidence, not arbitrary objects or terminal text.
            if not (observed is None or type(observed) is int or (
                    isinstance(observed, str) and len(observed) <= 4096
                    and not any(ord(c) < 32 for c in observed))):
                observed = {'type': type(observed).__name__}
            failures = self.record.setdefault('creation_validation', {}).setdefault(source, {})
            failures[field] = {'expected': expected, 'observed': observed}
            self.checkpoint()
        return matches

    def release(self):
        if self.lock:
            self.lock.close()
            self.lock = None

    def grouping(self):
        """None only when project grouping is wholly absent; else the locked, validated pin or LaunchError."""
        project = self.args.project
        base = Path.home().resolve() / '.lane-anchors'
        anchor, lanes, lock = base / project, base / f'{project}-lanes', base / f'.{project}.lock'
        heading = f'◆ {project}'

        def related(w):
            wt = w.get('worktree') or {}
            return (w.get('label') == heading or wt.get('repo_root') == str(anchor)
                    or str(wt.get('checkout_path')).startswith(f'{lanes}/'))

        def check():
            heads = [w for w in self.live['workspaces'] if w.get('label') == heading]
            panes = [p for p in self.live['panes'] if heads and p.get('workspace_id') == heads[0].get('workspace_id')]
            wt = (heads[0].get('worktree') or {}) if heads else {}
            try:
                top, common, _ = git('rev-parse', '--path-format=absolute', '--show-toplevel',
                                     '--git-common-dir', 'HEAD^{commit}', cwd=anchor)
            except (LaunchError, OSError, ValueError):
                top = common = None
            if not (len(heads) == 1 and len(panes) == 1 and lock.is_file() and top == str(anchor)
                    and common == f'{anchor}/.git' and os.path.realpath(str(panes[0].get('cwd'))) == top
                    and (not wt or (wt.get('repo_root') == top and wt.get('checkout_path') == top
                                    and wt.get('repo_key') == common and wt.get('is_linked_worktree') is False))):
                raise LaunchError('Project grouping setup is partial, broken or ambiguous; stopped before launch, '
                                  'not flat. Inspect it and repair it with lane setup')
            return {'anchor': top, 'checkout': f'{lanes}/{self.args.lane[1:]}',
                    'heading': heads[0]['workspace_id'], 'key': common}

        if not any(related(w) for w in self.live['workspaces']) and not any(
                os.path.lexists(p) for p in (anchor, lanes, lock)):
            print(f'Project grouping is not set up for {project}; launching flat', file=sys.stderr)
            return None
        group = check()
        # Existing per-project lock only; never create setup. Nonblocking, released before agent startup.
        self.lock = lock.open('r+')
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.live = snapshot(dict(self.context))
        if check() != group:
            raise LaunchError('Project grouping changed while locking; inspect, never retry automatically')
        return group

    def collisions(self, group):
        checkout = group['checkout']
        if (os.path.lexists(checkout) or f'worktree {checkout}' in git('worktree', 'list', '--porcelain', cwd=group['anchor'])
                or any((w.get('worktree') or {}).get('checkout_path') == checkout for w in self.live['workspaces'])):
            raise LaunchError('Lane checkout already exists, is registered or open; inspect, never adopt')

    def confirm(self, live, workspace, panes, source):
        """Exact panes, source cwd, checkout membership and heading provenance from one snapshot."""
        group = self.record['group']
        one = [w for w in live['workspaces'] if w.get('workspace_id') == workspace]
        head = [w for w in live['workspaces'] if w.get('workspace_id') == group['heading']]
        wt = (one[0].get('worktree') or {}) if one else {}
        hw = (head[0].get('worktree') or {}) if head else {}
        found = {p.get('pane_id'): p for p in live['panes'] if p.get('workspace_id') == workspace}
        if not (len(one) == 1 and len(head) == 1 and one[0].get('label') == self.record['name']
                and wt.get('checkout_path') == group['checkout'] and wt.get('is_linked_worktree') is True
                and hw.get('is_linked_worktree') is False and hw.get('checkout_path') == group['anchor']
                and wt.get('repo_key') == hw.get('repo_key') == group['key']
                and {k: v.get('terminal_id') for k, v in found.items()} == panes
                and found[source].get('cwd') == str(self.args.repo)):
            raise LaunchError('Topology identity differs from receipt; inspect, do not reuse')

    def topology(self, group, workspace, temp, terminal):
        """Attach the checkout workspace, add the source-cwd pane, then close only our temporary shell."""
        self.checkpoint('Attaching', temporary={'pane': temp, 'terminal': terminal})
        opened = call('worktree', 'open', '--cwd', group['anchor'], '--path', group['checkout'], '--no-focus',
                      kind='worktree_opened')
        w, p = mapping(opened.get('workspace'), 'workspace'), mapping(opened.get('root_pane'), 'root_pane')
        if (opened.get('already_open') is not True or w.get('workspace_id') != workspace
                or w.get('label') != self.record['name'] or p.get('pane_id') != temp
                or p.get('terminal_id') != terminal):
            raise LaunchError('Attachment adopted another workspace or identity changed; inspect receipt')
        self.checkpoint('Splitting')
        pane = mapping(call('pane', 'split', temp, '--direction', 'right', '--cwd', str(self.args.repo),
                            '--env', 'DOTFILES_KEYRING_PROMPT=0', '--no-focus', kind='pane_info').get('pane'), 'pane')
        source, source_terminal = string(pane, 'pane_id'), string(pane, 'terminal_id')
        self.checkpoint(source={'pane': source, 'terminal': source_terminal})
        if pane.get('workspace_id') != workspace or source == temp or source_terminal == terminal:
            raise LaunchError('Split returned an unexpected pane; inspect receipt, never close')
        self.confirm(snapshot(dict(self.context)), workspace, {temp: terminal, source: source_terminal}, source)
        for _ in range(10):
            info = mapping(call('pane', 'process-info', '--pane', temp, kind='pane_process_info')
                           .get('process_info'), 'process_info')
            procs = info.get('foreground_processes') or []
            if (info.get('pane_id') == temp and len(procs) == 1 and procs[0].get('pid') == info.get('shell_pid')
                    and str(procs[0].get('name')).lstrip('-') in ('sh', 'bash', 'zsh', 'dash', 'fish')):
                break
            time.sleep(0.2)
        else:
            raise LaunchError('Temporary shell is not alone in the foreground; not closing, inspect receipt')
        self.checkpoint('Closing')
        call('pane', 'close', temp, kind='ok')
        self.confirm(snapshot(dict(self.context)), workspace, {source: source_terminal}, source)
        return source, source_terminal

    def agent(self, a=None):
        if a is None:
            a = call('agent', 'get', self.record['pane'], kind='agent_info')['agent']
        a = mapping(a, 'agent')
        expected = {'pane_id': self.record['pane'], 'workspace_id': self.record['workspace'],
                    'terminal_id': self.record['terminal'], 'name': self.record['name'], 'agent': 'pi'}
        if any(a.get(k) != v for k, v in expected.items()):
            raise LaunchError('Live agent identity differs from receipt; do not reuse')
        session = a.get('agent_session')
        if not isinstance(session, dict) or session.get('agent') != 'pi':
            raise LaunchError('Pi session identity is not available yet; no shell-only readiness')
        for key in ('source', 'kind', 'value'):
            string(session, key)
        if self.record.get('agent_session', session) != session:
            raise LaunchError('Pi session changed since receipt; do not reuse')
        if 'agent_session' not in self.record:
            # Pin first recognition, even when a dialog prevents reaching Ready.
            self.checkpoint(agent_session=session)
        string(a, 'agent_status')
        return a

    def ready(self):
        # Powerline footer's known 30-second welcome overlay dismisses itself.
        # Read the visible viewport, not scrollback containing stale welcome text.
        deadline = time.monotonic() + 30
        while True:
            a = self.agent()
            if a.get('interactive_ready') is True and a['agent_status'] in ('idle', 'done'):
                self.checkpoint('Ready', agent_session=a['agent_session'])
                return
            read = mapping(call('agent', 'read', self.record['pane'], '--source', 'visible', '--lines', '80',
                                kind='pane_read').get('read'), 'read')
            if read.get('pane_id') != self.record['pane']:
                raise LaunchError('Read returned a different pane')
            text = read.get('text')
            if not isinstance(text, str):
                raise LaunchError('Invalid response field: text')
            welcome = 'Welcome back!' in text and re.search(r'Press any key to continue \(([0-9]|[12][0-9]|30)s\)', text)
            dialog = re.search(r'(?i)\b(trust|permission|approve|allow|deny)\b|\?', text)
            if not welcome or dialog or time.monotonic() >= deadline:
                raise LaunchError('Startup blocked/unknown: user intervention or inspection required')
            time.sleep(1)

    def execute(self):
        args = self.args
        identity = {'project': args.project, 'lane': args.lane,
                    'name': lane_name(args.project, args.lane, args.name),
                    'prompt': str(args.prompt), 'prompt_sha256': digest(args.prompt),
                    'repo': str(args.repo), 'state': str(args.state), 'context': self.context}
        if self.path.exists():
            candidate = json.loads(self.path.read_text())
            if candidate.get('version') not in (1, 2) or any(candidate.get(k) != v for k, v in identity.items()):
                raise LaunchError('Receipt identity/context/prompt differs; inspect without adopting or renaming')
            self.record = candidate
            if self.record['stage'] == 'Creating':
                raise LaunchError('Creation uncertain; inspect live workspace list, never create again automatically')
            if self.record['stage'] not in ('Created', 'Starting', 'Ready', 'Submitting', 'Submitted'):
                raise LaunchError('Topology/launch stage is incomplete or unknown; inspect receipt and live panes only')
            if self.record['stage'] not in ('Submitting', 'Submitted'):
                group = self.group = self.grouping()
                if (group is not None or candidate['version'] == 2) and group != candidate.get('group'):
                    raise LaunchError('Receipt topology and current project grouping disagree; '
                                      'inspect, never regroup or fall back flat')
            w = mapping(call('workspace', 'get', self.record['workspace'],
                             kind='workspace_info').get('workspace'), 'workspace')
            if w.get('workspace_id') != self.record['workspace'] or w.get('label') != identity['name']:
                raise LaunchError('Workspace identity differs from receipt')
            panes = [p for p in self.live['panes'] if p['pane_id'] == self.record['pane']
                     and p['workspace_id'] == self.record['workspace'] and p['terminal_id'] == self.record['terminal']]
            if len(panes) != 1:
                raise LaunchError('Root pane identity differs from receipt')
            if self.group:
                self.confirm(self.live, self.record['workspace'], {self.record['pane']: self.record['terminal']},
                             self.record['pane'])
            if self.record['stage'] in ('Submitting', 'Submitted'):
                a = self.agent()
                self.checkpoint(observation=a['agent_status'])
                if self.record['stage'] == 'Submitting':
                    raise LaunchError('Delivery uncertain; inspected only, never automatically resend')
                return
        else:
            state = args.state.read_text()
            row = state.splitlines()[state_row(state, args.lane)]
            if row.split('|')[-2].strip() not in ('Manual', '—', ''):
                raise LaunchError('STATE records an existing launch without a matching receipt; inspect first')
            group = self.grouping()
            if any(w.get('label') == identity['name'] for w in self.live['workspaces']) or any(
                    a.get('name') == identity['name'] for a in self.live['agents']):
                raise LaunchError('Name collision or existing unrecorded launch; inspect, never adopt implicitly')
            if group:
                self.collisions(group)
            self.record = dict(version=1, **identity)
            initial_cwd = str(args.repo)
            if group:
                self.record.update(version=2, group=group)
                self.checkpoint('Checkout')
                git('worktree', 'add', '-q', '--detach', group['checkout'], cwd=group['anchor'])
                initial_cwd = group['checkout']
            self.checkpoint('Creating')
            result = call('workspace', 'create', '--cwd', initial_cwd, '--label', identity['name'],
                          '--no-focus', '--env', 'DOTFILES_KEYRING_PROMPT=0', kind='workspace_created')
            for key in ('workspace', 'root_pane'):
                self.creation_check('create', key, 'object', result.get(key),
                                    isinstance(result.get(key), dict))
            w = mapping(result.get('workspace'), 'workspace')
            p = mapping(result.get('root_pane'), 'root_pane')
            for obj, key, field in ((w, 'workspace_id', 'workspace.workspace_id'),
                                    (p, 'pane_id', 'root_pane.pane_id'),
                                    (p, 'terminal_id', 'root_pane.terminal_id')):
                try:
                    string(obj, key)
                except LaunchError:
                    self.creation_check('create', field, 'nonempty string', obj.get(key), False)
                    raise
            workspace, pane, terminal = w['workspace_id'], p['pane_id'], p['terminal_id']
            # Preserve observed IDs for inspection without certifying a valid creation.
            self.checkpoint(created_response={'workspace': workspace, 'pane': pane, 'terminal': terminal})
            checks = [self.creation_check('create', 'workspace.label', identity['name'], w.get('label')),
                      self.creation_check('create', 'root_pane.workspace_id', workspace, p.get('workspace_id'))]
            cwd_matches = self.creation_check('create', 'root_pane.cwd', initial_cwd, p.get('cwd'))
            if not all(checks):
                raise LaunchError('Creation returned unexpected workspace/root pane/cwd')
            if not cwd_matches:
                cwd = p.get('cwd')
                if cwd is not None and (not isinstance(cwd, str) or any(ord(c) < 32 for c in cwd)):
                    raise LaunchError('Creation returned unexpected workspace/root pane/cwd')
                # PaneInfo.cwd is optional/nullable. Confirm once, without changing
                # the inherited caller fingerprint or retrying any launch mutation.
                live = snapshot(dict(self.context))
                workspaces = [w for w in live['workspaces'] if w.get('workspace_id') == workspace]
                panes = [p for p in live['panes'] if p.get('pane_id') == pane]
                checks = [self.creation_check('snapshot', 'workspace_count', 1, len(workspaces)),
                          self.creation_check('snapshot', 'root_pane_count', 1, len(panes))]
                if all(checks):
                    checks = [self.creation_check('snapshot', field, expected, obj.get(key))
                              for obj, key, field, expected in (
                                  (workspaces[0], 'label', 'workspace.label', identity['name']),
                                  (panes[0], 'workspace_id', 'root_pane.workspace_id', workspace),
                                  (panes[0], 'terminal_id', 'root_pane.terminal_id', terminal),
                                  (panes[0], 'cwd', 'root_pane.cwd', initial_cwd))]
                if not all(checks):
                    raise LaunchError('Creation returned unexpected workspace/root pane/cwd; snapshot did not confirm target')
                self.checkpoint(creation_cwd_confirmed='snapshot')
            if group:
                pane, terminal = self.topology(group, workspace, pane, terminal)
            self.checkpoint('Created', workspace=workspace, pane=pane, terminal=terminal)
        self.release()
        if self.record['stage'] == 'Created':
            # A Created receipt certifies agent start has not yet been attempted.
            self.checkpoint('Starting')
            try:
                started = call('agent', 'start', identity['name'], '--kind', 'pi', '--pane', self.record['pane'],
                               '--', '--name', identity['name'], kind='agent_started', timeout=35)
            except LaunchError as exc:
                self.checkpoint(start_error=str(exc))
                # A startup timeout may leave a recognized Pi behind its welcome overlay.
                # Inspect it; never invoke start a second time.
            else:
                self.agent(started['agent'])
        if self.record['stage'] not in ('Starting', 'Ready'):
            raise LaunchError('Unknown launch stage; inspect receipt')
        self.ready()
        if digest(args.prompt) != identity['prompt_sha256']:
            raise LaunchError('Prompt changed during startup; do not submit')
        self.checkpoint('Submitting')
        result = call('agent', 'prompt', self.record['pane'], f'Read {args.prompt} and follow it.', kind='agent_prompted')
        self.agent(result['agent'])
        self.checkpoint('Submitted')
        a = self.agent()
        self.checkpoint(observation=a['agent_status'])

    def update_state(self):
        # Receipt is authoritative. STATE is one concise projection, written once on exit.
        args = self.args
        before = args.state.read_text()
        lines = before.splitlines(keepends=True)
        index = state_row(before, args.lane)
        stage = self.record.get('stage', 'Uncertain')
        summary = f"{self.path.name}: {self.record.get('name', '')}; {stage}"
        if self.record.get('pane'):
            summary += f"; {self.record['workspace']} / {self.record['pane']}"
        if self.record.get('error'):
            summary += '; inspect receipt'
        columns = lines[index].split('|')
        columns[-2] = f' {summary} '
        lines[index] = '|'.join(columns)
        if args.state.read_text() != before:
            raise LaunchError('STATE changed concurrently; receipt saved, update row manually')
        atomic_write(args.state, ''.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--requested', action='store_true', help='Only after an explicit user launch request')
    for flag in ('project', 'lane', 'prompt', 'repo', 'state', 'session'):
        parser.add_argument(f'--{flag}', required=True)
    parser.add_argument('--name', help='Explicit name override, subject to live alias constraints')
    args = parser.parse_args()
    launch = None
    try:
        if not args.requested:
            raise LaunchError('Explicit launch request required; preparing a prompt is not permission')
        lane_name(args.project, args.lane, args.name)
        context = inherited_context(args.session)
        for key in ('prompt', 'repo', 'state'):
            setattr(args, key, Path(getattr(args, key)).resolve(strict=True))
        if not args.repo.is_dir() or not args.prompt.is_file() or not args.prompt.read_text().strip():
            raise LaunchError('Source directory and nonempty approved prompt required')
        state_row(args.state.read_text(), args.lane)
        # Serialize launches sharing a lanes directory, then take a fresh live snapshot.
        lock_path = args.prompt.parent / '.launch.lock'
        with lock_path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            live = snapshot(context)
            launch = Launch(args, context, live)
            try:
                launch.execute()
            except (LaunchError, OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
                if launch.record:
                    launch.checkpoint(error=str(exc))
                raise
            finally:
                launch.release()
                if launch.record:
                    # Capture before entering the handler, where exc_info becomes the STATE error.
                    primary_error = sys.exc_info()[1]
                    try:
                        launch.update_state()
                    except (OSError, ValueError, KeyError, TypeError, AttributeError) as state_exc:
                        print(f'STATE summary needs updating from {launch.path.name}: {state_exc}',
                              file=sys.stderr)
                        if primary_error is None:
                            raise
        print(json.dumps(launch.record))
        return 0
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        print(f'Launch stopped: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
