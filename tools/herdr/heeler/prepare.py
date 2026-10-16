#!/usr/bin/python3
"""Prepare optional Heeler persistence without restarting any live processes."""
import argparse
import base64
import fcntl
import importlib.util
import json
import os
import pwd
import re
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parents[2]
USER_UNIT = 'dotfiles-herdr.service'
SYSTEM_UNIT = 'dotfiles-heeler-sshd.service'
PUBLISHED_ENTRY = Path('/usr/local/lib/dotfiles-heeler/sshd-entrypoint.py')
PUBLISHED_UNIT = Path('/etc/systemd/system') / SYSTEM_UNIT
SYSTEM_MISE = Path('/usr/bin/mise')
MARKER = '# Managed by dotfiles: Heeler\n'
SERVICE_PATH = '%h/.pi/agent/bin:@DOTFILES@/bin:%h/.local/bin:/usr/local/bin:/usr/bin:/bin'
spec = importlib.util.spec_from_file_location('heeler_sshd', SOURCE / 'sshd-entrypoint.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def command(args, *, check=False, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, timeout=15, check=check, **kwargs)


def userctl(*args, check=True):
    return command(['/usr/bin/systemctl', '--user', *args], check=check)


def resolve_mise(home):
    for candidate in [home / '.local/bin/mise', SYSTEM_MISE]:
        if not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(candidate)) or '..' in candidate.parts:
            raise ValueError('unsupported Mise launcher path')
        if any(item.is_symlink() for item in [candidate, *candidate.parents]):
            raise ValueError(f'refusing symlink in Mise launcher: {candidate}')
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise ValueError('Mise must be installed in ~/.local/bin or /usr/bin')


def render_units(repo, name, uid, home):
    runtime.validate_identity(name, uid, str(home))
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(repo)) or '..' in Path(repo).parts:
        raise ValueError('unsupported dotfiles path for a systemd environment')
    user = (SOURCE / 'dotfiles-herdr.service.in').read_text().replace(
        '@SERVICE_PATH@', SERVICE_PATH.replace('@DOTFILES@', str(repo))).replace('@MISE@', str(resolve_mise(home)))
    system = (SOURCE / 'dotfiles-heeler-sshd.service.in').read_text().replace('@USER@', name)
    return user, system


def paths(home):
    return (home / '.config/systemd/user' / USER_UNIT,
            home / '.local/share/heeler' / SYSTEM_UNIT,
            home / '.local/share/heeler-trial/authorized_keys')


def safe_path(path, uid, directory=False):
    for item in [path, *path.parents]:
        if item.is_symlink():
            raise ValueError(f'refusing symlink: {item}')
    if path.exists():
        mode = path.stat()
        correct_type = stat.S_ISDIR(mode.st_mode) if directory else stat.S_ISREG(mode.st_mode)
        if not correct_type or mode.st_uid != uid:
            raise ValueError(f'foreign path: {path}')


def validate_keys(path, uid):
    safe_path(path, uid)
    if not path.exists():
        return False
    if path.stat().st_mode & 0o177:
        raise ValueError(f'key file must be private (0600 or 0400): {path}')
    return validate_key_text(path.read_text())


def validate_key_text(text):
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split()
        if len(fields) < 2 or fields[0] not in ('ssh-ed25519', 'ssh-rsa',
                                               'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384',
                                               'ecdsa-sha2-nistp521'):
            raise ValueError('expected plain SSH public keys, never private keys or authorized_keys options')
        try:
            blob = base64.b64decode(fields[1], validate=True)
            size = struct.unpack('>I', blob[:4])[0]
            if blob[4:4 + size].decode() != fields[0] or len(blob) <= size + 8:
                raise ValueError('public-key algorithm or payload mismatch')
        except (ValueError, UnicodeError, struct.error) as error:
            raise ValueError('invalid SSH public-key data') from error
    return any(line.strip() and not line.lstrip().startswith('#') for line in text.splitlines())


def service_environment(repo, home):
    # Read the same manager environment the user unit inherits. Values stay in
    # memory: shell-only tool overrides must not validate a different boot setup.
    result = command(['/usr/bin/busctl', '--user', '--json=short', 'get-property',
                      'org.freedesktop.systemd1', '/org/freedesktop/systemd1',
                      'org.freedesktop.systemd1.Manager', 'Environment'], check=True)
    payload = json.loads(result.stdout)
    if (not isinstance(payload, dict) or payload.get('type') != 'as'
            or not isinstance(payload.get('data'), list)):
        raise ValueError('invalid user-manager environment response')
    environment = {}
    for assignment in payload['data']:
        if not isinstance(assignment, str) or '=' not in assignment or not assignment.partition('=')[0]:
            raise ValueError('invalid user-manager environment assignment')
        key, _, value = assignment.partition('=')
        environment[key] = value
    if environment.get('HOME') != str(home):
        raise ValueError('user-manager HOME must match the selected Linux account')
    environment['PATH'] = SERVICE_PATH.replace('%h', str(home)).replace('@DOTFILES@', str(repo))
    return environment


def prerequisites(repo, name, uid, home):
    if not sys.platform.startswith('linux'):
        raise ValueError('Heeler persistence is supported on Linux/systemd only')
    runtime.validate_identity(name, uid, str(home))
    gitdir = command(['/usr/bin/git', '-C', str(repo), 'rev-parse', '--path-format=absolute',
                      '--git-dir', '--git-common-dir'], check=True).stdout.splitlines()
    if len(gitdir) != 2 or gitdir[0] != gitdir[1]:
        raise ValueError('prepare only from the canonical checkout, never an implementation worktree')
    mise = str(resolve_mise(home))
    for executable in ['/usr/bin/tailscale', '/usr/sbin/sshd', '/usr/bin/busctl',
                       str(home / '.local/bin/herdr'), str(home / '.pi/agent/bin/pi')]:
        if not os.access(executable, os.X_OK):
            raise ValueError(f'missing prerequisite: {executable}; see the Heeler runbook')
    environment = service_environment(repo, home)
    version = command([mise, 'exec', '--', str(home / '.local/bin/herdr'), '--version'],
                      cwd=home, env=environment, check=True).stdout.strip()
    match = re.fullmatch(r'herdr (\d+)\.(\d+)\.(\d+)', version)
    if not match or tuple(map(int, match.groups())) < (0, 8, 0):
        raise ValueError(f'unsupported Herdr version: {version}')
    try:
        command([mise, 'exec', '--', 'node', '--version'], cwd=home, env=environment, check=True)
    except subprocess.CalledProcessError as error:
        raise ValueError('Node must be available through mise before preparing Herdr startup') from error


def preflight(repo, name, uid, home):
    prerequisites(repo, name, uid, home)
    linger = command(['/usr/bin/loginctl', 'show-user', name, '--property=Linger', '--value'],
                     check=True).stdout.strip()
    if linger != 'yes':
        raise ValueError('user lingering is required; enable it explicitly as documented')
    stock_ssh_masked()


def stock_ssh_masked():
    for unit in ['ssh.service', 'ssh.socket']:
        if command(['/usr/bin/systemctl', 'is-enabled', unit], check=False).stdout.strip() != 'masked':
            raise ValueError(f'{unit} must remain masked; do not replace a pre-existing SSH deployment')


def atomic_write(path, data, mode=0o644):
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apply(repo, name, uid, home):
    preflight(repo, name, uid, home)
    directory = paths(home)[1].parent
    safe_path(directory, uid, directory=True)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = directory / '.prepare.lock'
    safe_path(lock, uid)
    descriptor = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return publish(repo, name, uid, home)


def publish(repo, name, uid, home):
    user, staged, key = paths(home)
    pending = list(staged.parent.glob('.rollback-*'))
    if pending:
        raise ValueError(f'unfinished preparation retained at {pending[0]}; inspect before reapplying')
    expected = render_units(repo, name, uid, home)
    for target in [user, staged]:
        safe_path(target, uid)
        safe_path(target.parent, uid, directory=True)
        if target.exists() and not target.read_text().startswith(MARKER):
            raise ValueError(f'refusing a foreign unit: {target}')
    validate_keys(key, uid)
    for directory in [user.parent, staged.parent, key.parent]:
        safe_path(directory, uid, directory=True)
    enabled = userctl('is-enabled', USER_UNIT, check=False).stdout.strip() == 'enabled'
    old = [(target, target.read_bytes() if target.exists() else None,
            stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o644)
           for target in [user, staged]]
    changed = any(data != wanted.encode() for (_, data, _), wanted in zip(old, expected))
    for directory in [user.parent, staged.parent, key.parent]:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not key.exists():
        try:
            descriptor = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            # Enrollment can happen outside our preparation lock. Never replace it.
            pass
        else:
            os.close(descriptor)
    enrolled = validate_keys(key, uid)
    if not changed and enabled:
        print('Heeler service policy unchanged; no services restarted')
        if not enrolled:
            print(f'Phone enrollment required: add a public key to {key} (never a private key)')
        return
    backup = Path(tempfile.mkdtemp(prefix='.rollback-', dir=staged.parent))
    try:
        manifest = {'enabled': enabled, 'files': []}
        for index, (target, data, mode) in enumerate(old):
            if data is not None:
                (backup / str(index)).write_bytes(data)
            manifest['files'].append({'path': str(target), 'mode': mode, 'present': data is not None})
        (backup / 'manifest.json').write_text(json.dumps(manifest))
    except OSError as failure:
        # No policy was published yet; discard the partial snapshot, not live state.
        try:
            shutil.rmtree(backup)
        except OSError as cleanup:
            raise RuntimeError(f'backup incomplete ({failure}); partial preparation retained at {backup}: {cleanup}') from failure
        raise
    try:
        for target, wanted in zip([user, staged], expected):
            atomic_write(target, wanted.encode())
        userctl('daemon-reload')
        userctl('enable', '--no-reload', USER_UNIT)
    except (OSError, subprocess.SubprocessError) as failure:
        # Restore policy files, not live session state or the phone key.
        try:
            for target, data, mode in old:
                if data is None:
                    target.unlink(missing_ok=True)
                else:
                    atomic_write(target, data, mode)
            if not enabled:
                userctl('disable', '--no-reload', USER_UNIT)
            userctl('daemon-reload')
        except (OSError, subprocess.SubprocessError) as rollback:
            raise RuntimeError(f'rollback incomplete ({rollback}); original policy retained at {backup}') from failure
        shutil.rmtree(backup)
        raise
    shutil.rmtree(backup)
    print('Heeler prepared for next boot; no service was started, stopped or restarted')
    print(f'Operator publication required: {staged}')
    if not enrolled:
        print(f'Phone enrollment required: add a public key to {key} (never a private key)')


def owned_cgroup(expected, actual):
    return bool(expected) and any(
        line.partition('::')[2] == expected or line.partition('::')[2].startswith(expected + '/')
        for line in actual.splitlines() if '::' in line)


def trusted_root_path(path):
    try:
        for item in [path, *path.parents]:
            info = item.lstat()
            if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                return False
        return path.is_file()
    except OSError:
        return False


def sshd_process_matches(raw, expected):
    argv = [value.decode() for value in raw.split(b'\0') if value]
    if argv == expected:
        return True
    # OpenSSH rewrites argv into its listener process title after startup.
    prefix = 'sshd: ' + ' '.join(expected) + ' [listener]'
    return len(argv) == 1 and (argv[0] == prefix or argv[0].startswith(prefix + ' '))


def unit_state(unit, user=False):
    args = ['/usr/bin/systemctl'] + (['--user'] if user else [])
    result = command(args + ['show', unit, '-p', 'ActiveState', '-p', 'SubState', '-p', 'Result',
                             '-p', 'MainPID', '-p', 'ControlGroup', '-p', 'FragmentPath'], check=True)
    state = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
    if 'ActiveState' not in state:
        raise ValueError(f'cannot inspect service state: {unit}')
    return state


def probe(home, uid):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(str(home / '.config/herdr/herdr.sock'))
        pid, peer_uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if peer_uid != uid:
            raise ValueError('Herdr socket belongs to another user')
        connection.sendall(b'{"id":"dotfiles-heeler-check","method":"ping","params":{}}\n')
        response = bytearray()
        while b'\n' not in response:
            chunk = connection.recv(4096)
            if not chunk or len(response) + len(chunk) > 16384:
                raise ValueError('invalid or excessive Herdr ping response')
            response.extend(chunk)
        packet = json.loads(response.split(b'\n', 1)[0])
        result = packet.get('result') if isinstance(packet, dict) else None
        protocol = result.get('protocol') if isinstance(result, dict) else None
        if (not isinstance(result, dict) or not isinstance(protocol, int) or protocol < 17
                or packet.get('id') != 'dotfiles-heeler-check' or result.get('type') != 'pong'):
            raise ValueError('Herdr does not provide the supported ping protocol')
        return pid


def inspect(repo, name, uid, home):
    user, staged, key = paths(home)
    for target, wanted in zip([user, staged], render_units(repo, name, uid, home)):
        safe_path(target, uid)
        if not target.exists() or target.read_text() != wanted:
            print(f'Heeler not prepared or source drift: {target}')
            return 1
    if not validate_keys(key, uid):
        print('Heeler staged; phone public key enrollment is pending')
        return 2
    for target, wanted in [(PUBLISHED_ENTRY, (SOURCE / 'sshd-entrypoint.py').read_bytes()),
                           (PUBLISHED_UNIT, staged.read_bytes())]:
        if not trusted_root_path(target) or target.read_bytes() != wanted:
            print(f'Heeler staged; operator publication pending: {target}')
            return 2
    for unit, is_user in [(USER_UNIT, True), (SYSTEM_UNIT, False)]:
        args = ['/usr/bin/systemctl'] + (['--user'] if is_user else [])
        result = command(args + ['is-enabled', unit], check=False)
        if not result.stdout.strip():
            raise ValueError(f'cannot inspect persistent enablement: {unit}')
        if result.stdout.strip() != 'enabled':
            print(f'Heeler staged; persistent enablement pending: {unit}')
            return 2
    if command(['/usr/bin/loginctl', 'show-user', name, '--property=Linger', '--value'],
               check=True).stdout.strip() != 'yes':
        raise ValueError('user lingering is disabled; boot persistence is not established')
    for unit in ['ssh.service', 'ssh.socket']:
        if command(['/usr/bin/systemctl', 'is-enabled', unit], check=False).stdout.strip() != 'masked':
            raise ValueError(f'{unit} is no longer masked; review SSH exposure')
    own = unit_state(USER_UNIT, user=True)
    ssh = unit_state(SYSTEM_UNIT)
    for unit, state in [(USER_UNIT, own), (SYSTEM_UNIT, ssh)]:
        retrying = state.get('ActiveState') == 'activating' and (
            state.get('SubState') == 'auto-restart' or state.get('Result') not in (None, '', 'success'))
        if state.get('ActiveState') == 'failed' or retrying:
            if unit == SYSTEM_UNIT and retrying:
                network = json.loads(command(['/usr/bin/tailscale', 'status', '--json'], check=True).stdout)
                backend = network.get('BackendState') if isinstance(network, dict) else None
                node = network.get('Self') if isinstance(network, dict) else None
                if ((isinstance(backend, str) and backend and backend != 'Running')
                        or (backend == 'Running' and isinstance(node, dict) and node.get('Online') is False)):
                    print('Heeler waiting for online Tailscale; SSH startup retries automatically')
                    return 2
                runtime.tailnet_ipv4(network)
            raise ValueError(f'{unit} failed ({state.get("Result", "unknown result")}); inspect its journal')
    if own.get('ActiveState') != 'active' or ssh.get('ActiveState') != 'active':
        print('Heeler staged; managed service start/cutover is pending (existing daemons are untouched)')
        return 2
    if (own.get('FragmentPath') != str(user) or ssh.get('FragmentPath') != str(PUBLISHED_UNIT)
            or int(own.get('MainPID', 0)) <= 0 or int(ssh.get('MainPID', 0)) <= 0):
        raise ValueError('active services are not loaded from the managed persistent units')
    pid = probe(home, uid)
    if not owned_cgroup(own.get('ControlGroup'), Path(f'/proc/{pid}/cgroup').read_text()):
        raise ValueError('default socket is served by an unmanaged daemon; controlled cutover is pending')
    network = json.loads(command(['/usr/bin/tailscale', 'status', '--json'], check=True).stdout)
    address = runtime.tailnet_ipv4(network)
    expected_args = runtime.sshd_argv(name, uid, str(home), address)
    if not sshd_process_matches(Path(f'/proc/{int(ssh["MainPID"])}/cmdline').read_bytes(), expected_args):
        raise ValueError('SSH process policy differs from the managed default-session listener')
    listeners = command(['/usr/bin/ss', '-H', '-ltn', '( sport = :2222 )'], check=True).stdout.splitlines()
    fields = listeners[0].split() if len(listeners) == 1 else []
    if len(fields) < 4 or fields[3] != address + ':2222':
        raise ValueError('SSH listener is missing, additional, or not on the current tailnet IPv4')
    print('Managed Heeler services and default Herdr API are healthy; verify phone authentication separately')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument('--apply', action='store_true', help='prepare and enable for a later controlled cutover')
    actions.add_argument('--check', action='store_true', help='inspect without changing files or services')
    args = parser.parse_args()
    selected = os.environ.get('DOTFILES_HEELER_ENABLED', '')
    if selected in ('', '0'):
        print('Heeler provisioning not selected; set DOTFILES_HEELER_ENABLED=1 explicitly')
        return 0
    if selected != '1':
        raise ValueError('DOTFILES_HEELER_ENABLED must be 1, 0 or unset')
    account = pwd.getpwuid(os.getuid())
    home = Path(account.pw_dir)
    if Path.home() != home:
        raise ValueError('HOME must match the selected Linux account')
    runtime.validate_identity(account.pw_name, account.pw_uid, str(home))
    if args.apply:
        apply(ROOT, account.pw_name, account.pw_uid, home)
        return 0
    return inspect(ROOT, account.pw_name, account.pw_uid, home)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Heeler: {error}', file=sys.stderr)
        sys.exit(1)
