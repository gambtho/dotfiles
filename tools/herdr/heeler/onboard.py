#!/usr/bin/python3
"""Guide explicitly selected per-host Heeler publication; never start live units."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import pwd
import re
import shlex
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

SOURCE = Path(__file__).absolute().parent
ROOT = SOURCE.parents[2]


def load_source(name):
    spec = importlib.util.spec_from_file_location('heeler_' + name, SOURCE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prepare = load_source('prepare')
publisher = load_source('publish')


class Pending(RuntimeError):
    """An explicit operator prerequisite, not a healthy installation."""


def discover(repo, name, uid, home):
    prepare.runtime.validate_identity(name, uid, str(home))
    try:
        result = prepare.command(['/usr/bin/systemctl', 'show', f'user@{uid}.service',
                                  '-p', 'InvocationID', '-p', 'MainPID', '-p', 'ActiveState'], check=True)
        manager = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        publisher.manager_token(manager)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise Pending('An already-active user manager is required; open an ordinary user session and retry. '
                      'Do not enable lingering to start dormant enabled units.') from error
    # Includes canonical checkout, manager/bus HOME and shared Mise/Node probes;
    # unlike final preflight, discovery does not require lingering yet.
    try:
        prepare.prerequisites(repo, name, uid, home)
    except subprocess.SubprocessError as error:
        if getattr(error, 'cmd', [None])[0] == '/usr/bin/busctl':
            raise Pending('An already-active correct-user manager and user bus are required; open a user session and retry') from error
        raise
    prepare.stock_ssh_masked()
    if prepare.command(['/usr/bin/ss', '-H', '-ltn', 'sport = :22'], check=True).stdout.strip():
        raise Pending('Existing port-22 access requires explicit migration; nothing was stopped')
    guidance = ('Tailscale must already be signed in and online. Complete native Tailscale sign-in '
                'in your operator terminal, then rerun; no join/reset/SSH/Serve settings were changed.')
    try:
        status = prepare.command(['/usr/bin/tailscale', 'status', '--json'], check=True)
    except (OSError, subprocess.SubprocessError) as error:
        raise Pending(guidance) from error
    network = json.loads(status.stdout)
    if isinstance(network, dict):
        backend = network.get('BackendState')
        own = network.get('Self')
        if ((isinstance(backend, str) and backend != 'Running')
                or (isinstance(own, dict) and own.get('Online') is False)):
            raise Pending(guidance)
    address = prepare.runtime.tailnet_ipv4(network)
    # Refuse an unknown existing listener before asking for authorization. The
    # Root phase repeats this check; discovery is not cross-authority atomicity.
    if prepare.command(['/usr/bin/ss', '-H', '-ltn', 'sport = :2222'], check=True).stdout.strip():
        published = {}
        for path in [prepare.PUBLISHED_ENTRY, prepare.PUBLISHED_UNIT]:
            if not prepare.trusted_root_path(path):
                raise Pending('Existing port-2222 listener requires explicit migration; no policy was published')
            published[path] = path.read_bytes()
        live_runtime = publisher.load_runtime(prepare.PUBLISHED_ENTRY)
        publisher.verify_listener(live_runtime, pwd.getpwuid(uid), address, published)
        # Discovery establishes provenance, not ownership adoption. Only the
        # Root phase can validate its private receipt before changing old policy.
    return {'name': name, 'uid': uid, 'home': home, 'manager': manager, 'address': address}


def public_key_data(data):
    if not isinstance(data, bytes) or len(data) > 16384:
        raise ValueError('SSH public-key input exceeds 16 KiB')
    text = data.decode('utf-8')
    if not prepare.validate_key_text(text):
        raise Pending('A plain SSH public key from the phone is required')
    return (text.rstrip('\n') + '\n').encode()


def read_public_key(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError('public-key input must be a regular file')
        return public_key_data(source.read(16385))


def enroll_public_key(home, supplied):
    keys = prepare.paths(home)[2]
    uid = os.getuid()
    if prepare.validate_keys(keys, uid):
        if supplied is not None and public_key_data(keys.read_bytes()) != public_key_data(supplied):
            raise ValueError('existing phone keys were preserved; explicit key replacement is not supported')
        return False
    if keys.exists():
        raise Pending(f'Existing empty key file preserved: {keys}; enroll a public key there and retry')
    data = public_key_data(supplied)
    prepare.safe_path(keys.parent, uid, directory=True)
    keys.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        fd = os.open(keys, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        if not prepare.validate_keys(keys, uid) or public_key_data(keys.read_bytes()) != data:
            raise ValueError('phone enrollment changed concurrently; existing key was not overwritten') from None
        return False
    with os.fdopen(fd, 'wb') as output:
        output.write(data)
        os.fchmod(output.fileno(), 0o600)
    return True


def invoke_publication(argv):
    # Authentication stays on the operator terminal; no passwords or auth URLs
    # are collected, copied into argv or captured by this coordinator.
    return subprocess.run(argv, check=False).returncode


def connection_card(info):
    public = Path('/etc/ssh/ssh_host_ed25519_key.pub')
    if not prepare.trusted_root_path(public):
        raise ValueError('cannot verify the Root-controlled SSH host public key')
    result = prepare.command(['/usr/bin/ssh-keygen', '-lf', str(public)], check=True)
    match = re.search(r'\bSHA256:[A-Za-z0-9+/]+', result.stdout)
    if not match:
        raise ValueError('cannot parse SSH host public-key fingerprint')
    return (f'Heeler connection: Host {info["address"]} / Port 2222 / User {info["name"]}\n'
            f'Herdr session: default / Direct SSH\nSSH host ED25519 fingerprint: {match[0]}\n'
            'Verify this fingerprint on the phone. Connect only after managed services are healthy.')


def setup(repo, key_file=None, input_fn=input):
    root_completed = False
    root_attempted = False
    try:
        selected = os.environ.get('DOTFILES_HEELER_ENABLED', '')
        if selected in ('', '0'):
            print('Heeler setup not selected; set DOTFILES_HEELER_ENABLED=1 explicitly')
            return 0
        if selected != '1':
            raise ValueError('DOTFILES_HEELER_ENABLED must be 1, 0 or unset')
        account = pwd.getpwuid(os.getuid())
        home = Path(account.pw_dir)
        if os.geteuid() == 0 or Path.home() != home:
            raise ValueError('run setup as the ordinary account with matching HOME, never through sudo')
        if not sys.stdin.isatty():
            raise Pending('Guided setup requires an interactive operator terminal; no publication attempted')
        info = discover(repo, account.pw_name, account.pw_uid, home)
        keys = prepare.paths(home)[2]
        existing = prepare.validate_keys(keys, account.pw_uid)
        if keys.exists() and not existing:
            raise Pending(f'Existing empty key file preserved: {keys}; enroll a public key there and retry')
        data = read_public_key(key_file) if key_file is not None else None
        if existing:
            if data is not None and public_key_data(keys.read_bytes()) != data:
                raise ValueError('existing keys preserved; setup does not replace phone keys')
            with contextlib.redirect_stdout(io.StringIO()):
                healthy = prepare.inspect(repo, account.pw_name, account.pw_uid, home) == 0
            if healthy:
                print(connection_card(info))
                return 0
        elif data is None:
            data = public_key_data(input_fn('Paste the phone SSH PUBLIC key (never a private key): ').encode())
        with tempfile.TemporaryDirectory(prefix='heeler-publication-') as folder:
            bundle = Path(folder)
            digests = {}
            for filename in publisher.PAYLOADS:
                payload = (SOURCE / filename).read_bytes()
                (bundle / filename).write_bytes(payload)
                digests[filename] = hashlib.sha256(payload).hexdigest()
            argv = publisher.build_bootstrap(bundle, digests, account.pw_name, info['manager'])
            print('Proposed Root phase: publish only the reviewed SSH entrypoint/unit and private recovery metadata;\n'
                  'enable the system unit WITHOUT starting it; enable lingering only for this already-active manager.\n'
                  'No sessions, credentials, host keys, Tailscale preferences or live daemons will be replaced.\n'
                  'Invoking account: ' + account.pw_name + '\nApproved payload SHA256: ' + json.dumps(digests, sort_keys=True))
            print('Exact administrator command:\n' + shlex.join(argv))
            if input_fn('Type publish to authorize this one administrator transaction (anything else cancels): ').strip() != 'publish':
                raise Pending('Canceled before enrollment/publication; no administrator command executed')
            enroll_public_key(home, data)
            root_attempted = True
            if invoke_publication(argv) != 0:
                raise RuntimeError('Root publication failed; enrollment is retained. Inspect the reported private Root '
                                   'staging/recovery path before retrying; no user unit was changed by this phase.')
            root_completed = True
            print('Root phase completed; user preparation and authoritative checks are next')
        prepare.apply(repo, account.pw_name, account.pw_uid, home)
        result = prepare.inspect(repo, account.pw_name, account.pw_uid, home)
        print(connection_card(info))
        if result == 2:
            print('Pending controlled cutover: existing daemons were not stopped or adopted. '
                  'After saving work, restart only this WSL distro yourself and rerun ai-heeler-check.')
        return result
    except Pending as error:
        print(f'Heeler setup pending: {error}')
        return 2
    except (EOFError, KeyboardInterrupt):
        print('Setup canceled. ' + ('Administrator publication may be incomplete; inspect private recovery evidence.'
                                    if root_attempted else 'No administrator command executed.'))
        return 2
    except (ValueError, KeyError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        prefix = 'Root phase completed; user preparation/check incomplete. ' if root_completed else ''
        print(f'Heeler setup error: {prefix}{error}')
        return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key-file', type=Path, help='plain SSH PUBLIC-key file for first enrollment; never a private key')
    args = parser.parse_args()
    return setup(ROOT, args.key_file)


if __name__ == '__main__':
    sys.exit(main())
