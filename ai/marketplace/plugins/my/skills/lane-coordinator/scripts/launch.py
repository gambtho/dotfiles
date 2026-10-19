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
        result = json.loads(completed.stdout)['result']
        if result['type'] != kind:
            raise ValueError('Unexpected response type')
        return result
    except (ValueError, KeyError, TypeError) as exc:
        raise LaunchError(f'{argv[0:2]} returned malformed JSON; effects may be uncertain') from exc


def string(obj, key):
    value = obj.get(key)
    if not isinstance(value, str) or not value or any(ord(c) < 32 for c in value):
        raise LaunchError(f'Invalid response field: {key}')
    return value


def inherited_context(session):
    required = ('HERDR_SESSION', 'HERDR_SOCKET_PATH', 'HERDR_PANE_ID', 'HERDR_WORKSPACE_ID')
    if os.environ.get('HERDR_ENV') != '1' or any(not os.environ.get(k) for k in required):
        raise LaunchError('Manual handoff: missing inherited Herdr context')
    if os.environ['HERDR_SESSION'] != session:
        raise LaunchError('Manual handoff: intended and inherited sessions differ')
    socket = Path(os.environ['HERDR_SOCKET_PATH'])
    if not socket.is_absolute() or not stat.S_ISSOCK(socket.stat().st_mode):
        raise LaunchError('Manual handoff: inherited socket is not an absolute local socket')
    info = socket.stat()
    return {'session': session, 'socket': str(socket), 'socket_device': info.st_dev,
            'socket_inode': info.st_ino, 'caller': os.environ['HERDR_PANE_ID'],
            'workspace': os.environ['HERDR_WORKSPACE_ID']}


def snapshot(context):
    live = call('api', 'snapshot', kind='session_snapshot')['snapshot']
    if live['protocol'] != 19:
        raise LaunchError('Unsupported Herdr protocol; inspect installed capabilities, do not update')
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

    def checkpoint(self, stage=None, **fields):
        if stage:
            self.record.pop('error', None)
            self.record['stage'] = stage
            self.record.setdefault('checkpoints', {})[stage] = datetime.now(timezone.utc).isoformat()
        self.record.update(fields)
        atomic_write(self.path, json.dumps(self.record, indent=2) + '\n')

    def agent(self, a=None):
        if a is None:
            a = call('agent', 'get', self.record['pane'], kind='agent_info')['agent']
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
            read = call('agent', 'read', self.record['pane'], '--source', 'visible', '--lines', '80',
                        kind='pane_read')['read']
            if read.get('pane_id') != self.record['pane']:
                raise LaunchError('Read returned a different pane')
            text = read['text']
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
            if candidate.get('version') != 1 or any(candidate.get(k) != v for k, v in identity.items()):
                raise LaunchError('Receipt identity/context/prompt differs; inspect without adopting or renaming')
            self.record = candidate
            if self.record['stage'] == 'Creating':
                raise LaunchError('Creation uncertain; inspect live workspace list, never create again automatically')
            w = call('workspace', 'get', self.record['workspace'], kind='workspace_info')['workspace']
            if w.get('workspace_id') != self.record['workspace'] or w.get('label') != identity['name']:
                raise LaunchError('Workspace identity differs from receipt')
            panes = [p for p in self.live['panes'] if p['pane_id'] == self.record['pane']
                     and p['workspace_id'] == self.record['workspace'] and p['terminal_id'] == self.record['terminal']]
            if len(panes) != 1:
                raise LaunchError('Root pane identity differs from receipt')
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
            if any(w.get('label') == identity['name'] for w in self.live['workspaces']) or any(
                    a.get('name') == identity['name'] for a in self.live['agents']):
                raise LaunchError('Name collision or existing unrecorded launch; inspect, never adopt implicitly')
            self.record = dict(version=1, **identity)
            self.checkpoint('Creating')
            result = call('workspace', 'create', '--cwd', str(args.repo), '--label', identity['name'],
                          '--no-focus', kind='workspace_created')
            w, p = result['workspace'], result['root_pane']
            workspace, pane, terminal = string(w, 'workspace_id'), string(p, 'pane_id'), string(p, 'terminal_id')
            # Preserve observed IDs for inspection without certifying a valid creation.
            self.checkpoint(created_response={'workspace': workspace, 'pane': pane, 'terminal': terminal})
            if w.get('label') != identity['name'] or p.get('workspace_id') != workspace or p.get('cwd') != str(args.repo):
                raise LaunchError('Creation returned unexpected workspace/root pane/cwd')
            self.checkpoint('Created', workspace=workspace, pane=pane, terminal=terminal)
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
