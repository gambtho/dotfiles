#!/usr/bin/python3
"""Explicit approved-byte bootstrap and isolated Root policy transaction.

This file is copied, digest-verified, into private Root staging before execution.
It never imports Python or executes Mise/Herdr/Pi from the invoking user's paths.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

PAYLOADS = ('publish.py', 'sshd-entrypoint.py', 'dotfiles-heeler-sshd.service.in')
ROOT_UID = 0
ROOT_ANCHOR = Path('/')
LIB = Path('/usr/local/lib/dotfiles-heeler')
UNIT = Path('/etc/systemd/system/dotfiles-heeler-sshd.service')
STATE = Path('/var/lib/dotfiles-heeler')
PRIVSEP = Path('/run/sshd')
STAGE = Path(__file__).absolute().parent
SYSTEM_ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C'}

# This exact text, including the expected hashes passed as arguments, is the
# operator-approved Root command. No imports from the checkout precede staging.
BOOTSTRAP_CODE = r'''
import hashlib, json, os, pwd, shutil, stat, subprocess, sys, tempfile
from pathlib import Path
ROOT_UID = 0
ROOT_ANCHOR = Path('/')
PAYLOADS = ('publish.py', 'sshd-entrypoint.py', 'dotfiles-heeler-sshd.service.in')
ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C'}
def safe(path):
    for p in [path, *path.parents]:
        if p.is_symlink(): raise ValueError('unsafe Root staging symlink')
        if p.exists():
            s = p.stat()
            if s.st_uid != ROOT_UID or s.st_mode & 0o022: raise ValueError('unsafe Root staging owner/mode')
        if p == ROOT_ANCHOR: break

def stage_bundle(bundle, digests, uid, base):
    if set(digests) != set(PAYLOADS): raise ValueError('unexpected payload allowlist')
    contents = {}
    dfd = os.open(bundle, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        ds = os.fstat(dfd)
        if ds.st_uid != uid or ds.st_mode & 0o077: raise ValueError('bundle must be private to invoking user')
        if set(os.listdir(dfd)) != set(PAYLOADS): raise ValueError('unexpected payload files')
        for name in PAYLOADS:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
            try:
                s = os.fstat(fd)
                if not stat.S_ISREG(s.st_mode) or s.st_uid != uid or s.st_size > 1048576:
                    raise ValueError('invalid candidate metadata')
                data = b''
                while len(data) <= 1048576:
                    chunk = os.read(fd, min(65536, 1048577 - len(data)))
                    if not chunk: break
                    data += chunk
                if len(data) > 1048576 or hashlib.sha256(data).hexdigest() != digests[name]:
                    raise ValueError('candidate digest mismatch')
                contents[name] = data
            finally: os.close(fd)
    finally: os.close(dfd)
    safe(base)
    if not base.exists(): base.mkdir(mode=0o700)
    if not base.is_dir() or base.stat().st_mode & 0o077: raise ValueError('Root staging must be private')
    staged = Path(tempfile.mkdtemp(prefix='.stage-', dir=base))
    try:
        for name, data in contents.items():
            p = staged / name
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
            with os.fdopen(fd, 'wb') as stream: stream.write(data)
        return staged
    except BaseException:
        shutil.rmtree(staged)
        raise

def main():
    if os.geteuid() != 0: raise PermissionError('administrator approval required')
    bundle, encoded, name, token = sys.argv[1:]
    uid = int(os.environ['SUDO_UID'])
    account = pwd.getpwnam(name)
    if uid < 1000 or account.pw_uid != uid or os.environ.get('SUDO_USER') != name:
        raise ValueError('invoking account mismatch')
    expected = json.loads(token)
    result = subprocess.run(['/usr/bin/systemctl', 'show', 'user@%d.service' % uid,
        '-p', 'InvocationID', '-p', 'MainPID', '-p', 'ActiveState'], env=ENV,
        check=True, text=True, capture_output=True, timeout=15)
    current = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    if current != expected or current.get('ActiveState') != 'active':
        raise ValueError('user manager changed or inactive; open an active user session and retry')
    staged = stage_bundle(Path(bundle), json.loads(encoded), uid, Path('/run/dotfiles-heeler-setup'))
    env = dict(ENV, SUDO_UID=str(uid), SUDO_USER=name)
    result = subprocess.run(['/usr/bin/python3', '-I', '-B', str(staged / 'publish.py'),
        '--user', name, '--manager', token], env=env, check=False)
    if result.returncode == 0: shutil.rmtree(staged)
    else: print('Publication failed; private Root staging retained: ' + str(staged), file=sys.stderr)
    return result.returncode
if __name__ == '__main__':
    try: sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print('Heeler publication refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
'''


def manager_token(value):
    if (not isinstance(value, dict) or set(value) != {'InvocationID', 'MainPID', 'ActiveState'}
            or value['ActiveState'] != 'active'
            or not isinstance(value['InvocationID'], str)
            or not re.fullmatch('[0-9a-f]{32}', value['InvocationID'])
            or not isinstance(value['MainPID'], str) or not value['MainPID'].isdigit()
            or int(value['MainPID']) <= 0):
        raise ValueError('an already-active user manager identity is required')
    return value


def build_bootstrap(bundle, digests, account, manager):
    manager_token(manager)
    if (set(digests) != set(PAYLOADS)
            or not all(isinstance(h, str) and re.fullmatch('[0-9a-f]{64}', h) for h in digests.values())
            or not re.fullmatch(r'[a-z_][a-z0-9_.-]*\$?', account)):
        raise ValueError('invalid publication request')
    return ['/usr/bin/sudo', '--', '/usr/bin/python3', '-I', '-c', BOOTSTRAP_CODE,
            str(bundle), json.dumps(digests, sort_keys=True), account, json.dumps(manager, sort_keys=True)]


def run(args, *, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True, timeout=20, env=SYSTEM_ENV)


def trusted(path, directory=False):
    for item in [path, *path.parents]:
        if item.is_symlink():
            raise ValueError(f'unsafe Root symlink: {item}')
        if item.exists():
            mode = item.stat()
            if mode.st_uid != ROOT_UID or mode.st_mode & 0o022:
                raise ValueError(f'unsafe Root ownership/mode: {item}')
        if item == ROOT_ANCHOR:
            break
    if path.exists():
        kind = stat.S_ISDIR if directory else stat.S_ISREG
        if not kind(path.stat().st_mode):
            raise ValueError(f'unsafe Root artifact type: {path}')


def read_owned(path):
    trusted(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        metadata = os.fstat(source.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != ROOT_UID:
            raise ValueError('unsafe Root artifact')
        data = source.read(1048577)
    if len(data) > 1048576:
        raise ValueError('Root artifact exceeds size limit')
    return data


def directory(path, mode):
    trusted(path, directory=True)
    if not path.exists():
        path.mkdir(mode=mode, parents=True)
        path.chmod(mode)
    if path.stat().st_mode & 0o777 != mode:
        raise ValueError(f'unexpected directory mode: {path}')


def write_owned(path, data, mode):
    trusted(path)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def verify_manager(uid, expected):
    manager_token(expected)
    result = run(['/usr/bin/systemctl', 'show', f'user@{uid}.service', '-p', 'InvocationID',
                  '-p', 'MainPID', '-p', 'ActiveState'])
    observed = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    if observed != expected:
        raise ValueError('user manager changed or inactive; retry from an active user session')


def verify_listener(runtime, account, address, existing):
    rows = run(['/usr/bin/ss', '-H', '-ltn', 'sport = :2222']).stdout.splitlines()
    if not rows:
        return
    if len(existing) != 2 or len(rows) != 1 or len(rows[0].split()) < 5 or rows[0].split()[3] != address + ':2222':
        raise ValueError('foreign or unknown port-2222 listener requires migration')
    result = run(['/usr/bin/systemctl', 'show', UNIT.name, '-p', 'ActiveState', '-p', 'MainPID', '-p', 'FragmentPath'])
    state = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    pid = state.get('MainPID', '')
    if state.get('ActiveState') != 'active' or state.get('FragmentPath') != str(UNIT) or not pid.isdigit() or int(pid) <= 0:
        raise ValueError('port-2222 listener is not the managed unit')
    proc = Path('/proc') / pid
    expected_group = '/system.slice/' + UNIT.name
    if proc.stat().st_uid != ROOT_UID or ('0::' + expected_group) not in (proc / 'cgroup').read_text().splitlines():
        raise ValueError('port-2222 listener provenance mismatch')
    with (proc / 'cmdline').open('rb') as stream:
        raw = stream.read(16385)
    argv = [v.decode() for v in raw.split(b'\0') if v]
    expected = runtime.sshd_argv(account.pw_name, account.pw_uid, account.pw_dir, address)
    title = 'sshd: ' + ' '.join(expected) + ' [listener]'
    if len(raw) > 16384 or not (argv == expected or (len(argv) == 1 and (argv[0] == title or argv[0].startswith(title + ' ')))):
        raise ValueError('port-2222 listener arguments do not match reviewed policy')


def publish_for_account(name, manager):
    if os.geteuid() != 0:
        raise PermissionError('publisher requires administrator approval')
    account = pwd.getpwnam(name)
    if (account.pw_uid < 1000 or str(account.pw_uid) != os.environ.get('SUDO_UID')
            or name != os.environ.get('SUDO_USER')):
        raise ValueError('invoking account mismatch')
    verify_manager(account.pw_uid, manager)
    for filename in PAYLOADS:
        read_owned(STAGE / filename)
    spec = importlib.util.spec_from_file_location('heeler_root_runtime', STAGE / 'sshd-entrypoint.py')
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    runtime.validate_identity(name, account.pw_uid, account.pw_dir)
    status = json.loads(run(['/usr/bin/tailscale', 'status', '--json']).stdout)
    address = runtime.tailnet_ipv4(status)
    for unit in ['ssh.service', 'ssh.socket']:
        if run(['/usr/bin/systemctl', 'is-enabled', unit], check=False).stdout.strip() != 'masked':
            raise ValueError('stock SSH must remain masked; explicit migration required')
    if run(['/usr/bin/ss', '-H', '-ltn', 'sport = :22']).stdout.strip():
        raise ValueError('existing port-22 listener requires explicit migration')
    entry = LIB / 'sshd-entrypoint.py'
    receipt = STATE / 'ownership.json'
    desired = {entry: (read_owned(STAGE / 'sshd-entrypoint.py'), 0o755),
               UNIT: (read_owned(STAGE / 'dotfiles-heeler-sshd.service.in').decode().replace('@USER@', name).encode(), 0o644)}
    for path in [entry, UNIT, receipt]:
        trusted(path)
    # A receipt is Root-controlled ownership evidence, never doctor authority.
    existing = {str(p): {'sha256': hashlib.sha256(read_owned(p)).hexdigest(),
                         'uid': p.stat().st_uid, 'mode': p.stat().st_mode & 0o777}
                for p in desired if p.exists()}
    if receipt.exists():
        record = json.loads(read_owned(receipt))
        if record != {'schema_version': 1, 'account': name, 'files': existing} or len(existing) != 2:
            raise ValueError('foreign or modified Root publication receipt/policy')
    elif existing and (len(existing) != 2 or any(read_owned(p) != data for p, (data, _) in desired.items())):
        raise ValueError('foreign or partial pre-existing Root policy requires migration')
    verify_listener(runtime, account, address, existing)
    directory(STATE, 0o700)
    lock = STATE / '.publish.lock'
    trusted(lock)
    fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+') as held:
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if any(STATE.glob('recovery-*')):
            raise ValueError(f'unresolved Root recovery evidence under {STATE}; operator inspection required')
        # Recheck ownership after acquiring the publication lock.
        for p in desired:
            if (p.exists() and hashlib.sha256(read_owned(p)).hexdigest() != existing.get(str(p), {}).get('sha256')) or (not p.exists() and str(p) in existing):
                raise ValueError('Root publication changed during discovery')
        directory(LIB, 0o755)
        directory(UNIT.parent, 0o755)
        directory(PRIVSEP, 0o755)
        run(['/usr/bin/python3', '-I', '-B', str(STAGE / 'sshd-entrypoint.py'), '--user', name, '--check'])
        was_enabled = False
        if UNIT.exists():
            state = run(['/usr/bin/systemctl', 'is-enabled', UNIT.name], check=False).stdout.strip()
            if state not in ('enabled', 'disabled'):
                raise ValueError('unknown existing Heeler enablement state')
            was_enabled = state == 'enabled'
        before = {p: (read_owned(p) if p.exists() else None) for p in [*desired, receipt]}
        before_modes = {p: p.stat().st_mode & 0o777 for p, data in before.items() if data is not None}
        backup = Path(tempfile.mkdtemp(prefix='recovery-', dir=STATE))
        try:
            for p, data in before.items():
                if data is not None:
                    write_owned(backup / p.name, data, 0o600)
            write_owned(backup / 'manifest.json', json.dumps({
                'schema_version': 1, 'account': name, 'was_enabled': was_enabled,
                'files': {str(p): p.name if data is not None else None for p, data in before.items()},
                'modes': {str(p): mode for p, mode in before_modes.items()}
            }).encode(), 0o600)
        except OSError as original:
            try:
                shutil.rmtree(backup)
            except OSError as cleanup:
                raise RuntimeError(f'snapshot failed ({original}); cleanup failed ({cleanup}); retained {backup}') from original
            raise
        mutated = False
        enable_attempted = False
        linger_attempted = False
        try:
            for p, (data, mode) in desired.items():
                mutated = True
                write_owned(p, data, mode)
            run(['/usr/bin/systemctl', 'daemon-reload'])
            enable_attempted = True
            run(['/usr/bin/systemctl', 'enable', '--no-reload', UNIT.name])
            verify_manager(account.pw_uid, manager)
            linger = run(['/usr/bin/loginctl', 'show-user', name, '--property=Linger', '--value']).stdout.strip()
            if linger not in ('yes', 'no'):
                raise ValueError('unknown user lingering state')
            if linger == 'no':
                verify_manager(account.pw_uid, manager)
                linger_attempted = True
                run(['/usr/bin/loginctl', 'enable-linger', name])
            record = {'schema_version': 1, 'account': name,
                      'files': {str(p): {'sha256': hashlib.sha256(data).hexdigest(), 'uid': ROOT_UID, 'mode': mode}
                                for p, (data, mode) in desired.items()}}
            write_owned(receipt, json.dumps(record, sort_keys=True).encode(), 0o600)
        except (ValueError, OSError, subprocess.SubprocessError) as original:
            if linger_attempted:
                print('User lingering may now be enabled; policy recovery does not undo it or stop the user manager.', file=sys.stderr)
            try:
                if enable_attempted and not was_enabled:
                    run(['/usr/bin/systemctl', 'disable', '--no-reload', UNIT.name])
                for p, data in before.items():
                    if data is None:
                        p.unlink(missing_ok=True)
                    else:
                        write_owned(p, data, before_modes[p])
                if mutated:
                    run(['/usr/bin/systemctl', 'daemon-reload'])
                    if was_enabled:
                        run(['/usr/bin/systemctl', 'enable', '--no-reload', UNIT.name])
                shutil.rmtree(backup)
            except (ValueError, OSError, subprocess.SubprocessError) as recovery:
                raise RuntimeError(f'publication failed ({original}); recovery failed ({recovery}); retained {backup}') from original
            raise
        shutil.rmtree(backup)
        return {'root_policy': 'published', 'system_unit': 'enabled without start',
                'lingering': 'already enabled' if linger == 'yes' else 'enabled; not automatically undone on later failure'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--user', required=True)
    parser.add_argument('--manager', required=True)
    args = parser.parse_args()
    try:
        result = publish_for_account(args.user, json.loads(args.manager))
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, KeyError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Heeler publication incomplete: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
