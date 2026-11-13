"""Explicit human-invoked remote lanes; no installation, grouping or automatic replay."""
import fcntl
import json
import os
import re
import shlex
import signal
import stat
import subprocess
from pathlib import Path

# Executed in the selected host's Python, never written to its filesystem.
INSPECT = '''import os, pathlib, sys
root = pathlib.Path(sys.argv[1])
for text in sys.argv[1:]:
    p = pathlib.Path(text)
    for parent in (p, *p.parents):
        if parent.is_symlink():
            raise SystemExit("symlink in delivery path")
    if p != root and root not in p.parents:
        raise SystemExit("delivery path escaped root")
    if p.exists():
        directory = p == root or p in (root / "lanes", root / "reports", root / "review-profile")
        if (directory and not p.is_dir()) or (not directory and not p.is_file()):
            raise SystemExit("unexpected delivery path type")
        if p.stat().st_uid != os.geteuid():
            raise SystemExit("delivery path owned by another user")
'''
HOST = '''import json, os, pathlib, pwd, shutil, socket, sys
print(json.dumps(dict(hostname=socket.gethostname(), user=pwd.getpwuid(os.geteuid()).pw_name,
                     home=str(pathlib.Path.home()), tools=all(os.access(p, os.X_OK) for p in sys.argv[1:])
                     and shutil.which("rsync") is not None)))
'''


def clean(value):
    if not isinstance(value, str) or not value or any(ord(c) < 32 or 127 <= ord(c) < 160 or c == '\\' for c in value):
        raise ValueError('binding/path must be nonempty text without controls or backslashes')
    return value


def inventory(snapshot):
    panes = snapshot['panes']
    if not isinstance(panes, list) or not panes:
        raise ValueError('endpoint inventory empty or malformed')
    rows = [tuple(clean(p[k]) for k in ('workspace_id', 'pane_id', 'terminal_id')) for p in panes]
    if len(set(rows)) != len(rows):
        raise ValueError('endpoint inventory contains duplicate identities')
    return sorted(rows)


class FocusOnly(ValueError):
    """The existing workspace was focused; no delivery or input was attempted."""


class Remote:
    def __init__(self, label, prompt, host, lane):
        self.lane, self.label, self.host = lane, label, host
        self.stage, self.observed = 'preflight', ''
        project, number = lane.resolve(label)
        if not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', label) or not number.isdecimal():
            raise ValueError('remote label must be <project>-<number>, at most 32 characters')
        if not re.fullmatch(r'[a-z][a-z0-9_-]*', host):
            raise ValueError('invalid host key')
        self.local = Path.home() / f'{project}-local'
        binding_file = self.local / 'lane-hosts.json'
        required = ('machine_id', 'saved_target', 'target', 'session', 'hostname', 'user', 'root',
                    'herdr', 'mise', 'pi', 'transport', 'agents', 'rules', 'profile')
        try:
            self.config = json.loads(binding_file.read_text())[host]
            for key in required:
                clean(self.config[key])
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise ValueError(f'Cannot load binding {host} from {binding_file}: {error}') from error
        c = self.config
        for key in ('target', 'hostname', 'user'):
            if not re.fullmatch(r'[a-zA-Z0-9_][a-zA-Z0-9_.-]*', c[key]):
                raise ValueError(f'invalid {key} binding')
        if c['transport'] not in ('ssh', 'tailscale'):
            raise ValueError('transport must be ssh or tailscale')
        for key in ('root', 'herdr', 'mise', 'pi'):
            if not Path(c[key]).is_absolute() or '..' in Path(c[key]).parts:
                raise ValueError(f'{key} must be an absolute concrete path')
        self.root = Path(c['root'])
        if self.root.name != f'{project}-local':
            raise ValueError('remote root must name the selected project-local directory')
        sources = [c['agents'], c['rules'], prompt, c['profile']]
        self.sources = [Path(clean(p)) if Path(clean(p)).is_absolute() else self.local / p for p in sources]
        self.targets = [self.root / p for p in ('AGENTS.md', 'lanes/COMMON-RULES.md',
                                               'lanes/' + self.sources[2].name, 'review-profile/learnings.md')]
        if len(set(self.targets)) != 4:
            raise ValueError('prompt basename conflicts with another delivery snapshot')
        self.originals = [self.source(p) for p in self.sources]
        self.prefix = (['tailscale', 'ssh'] if c['transport'] == 'tailscale' else
                       ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                        '-o', 'ConnectTimeout=10'])
        state = Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local/state')
        self.lock = state / 'dotfiles/lane-locks' / f'{project}-{host}.lock'

    @staticmethod
    def source(path):
        if path.is_symlink():
            raise ValueError(f'symlink source refused: {path}; select a regular snapshot file')
        info = path.stat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError(f'non-regular source refused: {path}')
        return path.read_bytes(), info.st_mtime_ns, info.st_size

    def run(self, argv):
        # A local timeout does not cancel a request already admitted remotely.
        with subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, start_new_session=True) as child:
            try:
                stdout, _ = child.communicate(timeout=10)
            except BaseException as error:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.communicate()
                if isinstance(error, subprocess.TimeoutExpired):
                    raise ValueError(f'{self.stage} timed out after 10 s; inspect, do not resend') from error
                raise
            if child.returncode:
                raise ValueError(f'{self.stage} failed (exit {child.returncode}); inspect the target')
            return stdout

    def ssh(self, script):
        c = self.config
        return self.run([*self.prefix, c['user'] + '@' + c['target'],
                         shlex.join(['/bin/sh', '-c', script])])

    def api(self, *args):
        raw = self.run(['herdr', '--machine', self.config['machine_id'], *args])
        if not raw.strip() and args[:2] in (('pane', 'run'), ('workspace', 'focus')):
            return {}
        result = json.loads(raw)['result']
        if not isinstance(result, dict):
            raise ValueError('malformed API result')
        return result

    def catalog(self):
        profiles = json.loads(self.run(['herdr', 'machine', 'list', '--json']))
        c = self.config
        matches = [p for p in profiles if p['id'] == c['machine_id']]
        if (len(matches) != 1 or matches[0].get('enabled') is not True
                or matches[0].get('target') != c['saved_target'] or matches[0].get('session') != c['session']):
            raise ValueError('saved-machine target/session binding changed or unavailable')

    def binding(self):
        self.stage = 'saved-machine binding'
        self.catalog()
        self.stage = 'SSH host binding'
        c = self.config
        info = json.loads(self.ssh(shlex.join(['python3', '-c', HOST, c['herdr'], c['mise'], c['pi']])))
        if (info['hostname'] != c['hostname'] or info['user'] != c['user']
                or Path(info['home']) != self.root.parent or info['tools'] is not True):
            raise ValueError('SSH host/user/home/tools binding mismatch')
        self.stage = 'endpoint session binding'
        snapshot = ('unset HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID '
                    'HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_CONFIG_PATH; exec ' +
                    shlex.join([c['herdr'], '--session', c['session'], 'api', 'snapshot']))
        first = inventory(json.loads(self.ssh(snapshot))['result']['snapshot'])
        middle = inventory(self.api('api', 'snapshot')['snapshot'])
        last = inventory(json.loads(self.ssh(snapshot))['result']['snapshot'])
        if first != middle or middle != last:
            raise ValueError('endpoint session inventories disagree; no lane input sent')

    def spaces(self):
        spaces = self.api('workspace', 'list')['workspaces']
        if not isinstance(spaces, list):
            raise ValueError('malformed workspace list')
        return spaces

    def existing(self, spaces):
        found = self.lane.unique(spaces, self.label)
        if found:
            self.catalog()
            self.stage = 'remote focus'
            self.api('workspace', 'focus', clean(found['workspace_id']))
            print(f'{self.host}/{self.config["session"]}: {self.label} already open; remote server focus set')
            raise FocusOnly('Laptop machine selection unchanged; inputs unchanged; prompt not sent. '
                             'Select it in Herdr to inspect.')

    def deliver(self):
        self.stage = 'delivery path inspection'
        directories = [self.root, *(self.root / p for p in ('lanes', 'reports', 'review-profile'))]
        paths = [str(p) for p in (*directories, *self.targets)]
        self.ssh(shlex.join(['python3', '-c', INSPECT, *paths]))
        self.stage = 'delivery directory creation'
        self.catalog()
        self.ssh(shlex.join(['mkdir', '-p', '--', *(str(p) for p in directories)]))
        # rsync adds the host argument; supply user@host ourselves (Tailscale rejects -l).
        shell = shlex.join(['sh', '-c', 'exec ' + shlex.join(self.prefix) +
                            ' ' + shlex.quote(self.config['user']) + '@"$@"', 'sh'])
        for src, dst, original in zip(self.sources, self.targets, self.originals):
            self.stage = f'delivery {dst.relative_to(self.root)}'
            self.catalog()
            self.run(['rsync', '-a', '-e', shell, str(src), self.config['target'] + ':' + str(dst)])
            self.stage = f'read-back {dst.relative_to(self.root)}'
            if self.ssh(shlex.join(['cat', '--', str(dst)])) != original[0]:
                raise ValueError(f'read-back mismatch: {dst.relative_to(self.root)}; no lane started. '
                                 'Inspect the source; make its mtime distinct before retrying delivery.')
        if [self.source(p) for p in self.sources] != self.originals:
            raise ValueError('source inputs changed during delivery; no lane started')

    def start(self):
        self.binding()
        self.existing(self.spaces())
        self.deliver()
        self.binding()
        spaces = self.spaces()
        self.existing(spaces)
        self.catalog()
        self.stage = 'workspace create'
        made = self.api('workspace', 'create', '--cwd', str(self.root), '--label', self.label,
                        '--no-focus', '--env', 'DOTFILES_KEYRING_PROMPT=0')
        # Preserve whatever identifiers arrived, even when later metadata is rejected.
        workspace, pane = made.get('workspace'), made.get('root_pane')
        self.observed = ' '.join(clean(v) for obj, key in ((workspace, 'workspace_id'), (pane, 'pane_id'))
                                 if isinstance(obj, dict) and isinstance(v := obj.get(key), str) and v)
        pid = self.lane.fresh_pane(made, spaces, self.label)
        terminal = clean(pane['terminal_id'])
        self.stage = 'new pane verification'
        live = self.api('pane', 'get', pid)['pane']
        if (live['pane_id'] != pid or live['workspace_id'] != workspace['workspace_id']
                or live['terminal_id'] != terminal
                or self.lane.unique(self.spaces(), self.label)['workspace_id'] != workspace['workspace_id']):
            raise ValueError('new workspace/pane/terminal identity changed')
        self.lane.wait_shell(pid, call=self.api)
        self.catalog()
        c = self.config
        prompt = f'Read {self.targets[2]} and follow it.'
        command = ('test "$(hostname)" = ' + shlex.quote(c['hostname']) +
                   ' && test "$(id -un)" = ' + shlex.quote(c['user']) +
                   ' && cd ' + shlex.quote(str(self.root)) + ' && ' +
                   shlex.join([c['mise'], 'exec', '--', c['pi'], '--name', self.label, '--', prompt]))
        self.stage = 'pane run'
        self.api('pane', 'run', pid, shlex.join(['/bin/sh', '-c', command]))
        print(f'{self.host}/{c["session"]}: {self.label} created (flat); four snapshots verified')
        print(f'workspace={workspace["workspace_id"]} pane={pid}; startup command admitted once; '
              'Pi readiness unconfirmed')


def open_remote(label, prompt, host, lane):
    remote = Remote(label, prompt, host, lane)
    remote.lock.parent.mkdir(parents=True, exist_ok=True)
    with remote.lock.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            remote.start()
        except FocusOnly:
            raise
        except (ValueError, KeyError, TypeError, AttributeError, IndexError, OSError,
                subprocess.SubprocessError) as error:
            detail = str(error) if isinstance(error, ValueError) else type(error).__name__
            raise ValueError(f'{host}/{remote.config["session"]}: {remote.stage}; incomplete or uncertain '
                             f'{remote.observed}: {detail}; inspect, do not resend. '
                             'Rerunning an existing label only focuses it.') from error
