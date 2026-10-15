#!/usr/bin/python3
"""Root-owned, isolated entrypoint for the optional tailnet-only SSH listener.

No user configuration or executables are loaded here. Herdr and Pi belong to
an ordinary user service; sshd handles authentication and drops privileges.
"""
import argparse
import ipaddress
import json
import os
import pwd
import re
import subprocess
import sys
from pathlib import PurePosixPath

TAILNET = ipaddress.ip_network('100.64.0.0/10')
SYSTEM_ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C'}


def validate_identity(name, uid, home):
    if uid < 1000 or not re.fullmatch(r'[a-z_][a-z0-9_.-]*\$?', name):
        raise ValueError('Heeler requires an ordinary, non-root Linux account')
    if (not re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+', home)
            or '..' in PurePosixPath(home).parts):
        raise ValueError('unsupported home path: whitespace, specifiers and traversal are refused')
    if len(os.fsencode(home + '/.config/herdr/herdr.sock')) >= 108:
        raise ValueError('home path exceeds the Unix-socket address limit')


def tailnet_ipv4(status):
    if not isinstance(status, dict) or status.get('BackendState') != 'Running':
        raise ValueError('Tailscale is not running')
    own = status.get('Self')
    if not isinstance(own, dict) or own.get('Online') is not True:
        raise ValueError('Tailscale node is not online')
    addresses = own.get('TailscaleIPs')
    if not isinstance(addresses, list) or not all(isinstance(value, str) for value in addresses):
        raise ValueError('Tailscale addresses are missing')
    parsed = [ipaddress.ip_address(value) for value in addresses]
    ipv4 = [value for value in parsed if value.version == 4]
    if len(ipv4) != 1 or ipv4[0] not in TAILNET:
        raise ValueError('expected exactly one current Tailscale IPv4 address')
    return str(ipv4[0])


def sshd_argv(name, uid, home, address):
    validate_identity(name, uid, home)
    ip = ipaddress.ip_address(address)
    if ip.version != 4 or ip not in TAILNET:
        raise ValueError('refusing a non-tailnet listener')
    options = [
        f'ListenAddress={ip}', 'PidFile=/run/dotfiles-heeler/sshd.pid',
        'UsePAM=yes', 'AuthenticationMethods=publickey', 'PubkeyAuthentication=yes',
        'PasswordAuthentication=no', 'KbdInteractiveAuthentication=no',
        'PermitRootLogin=no', f'AllowUsers={name}',
        f'AuthorizedKeysFile={home}/.local/share/heeler-trial/authorized_keys',
        'AllowStreamLocalForwarding=local', 'AllowTcpForwarding=local',
        # OpenSSH 9.6 shares TCP and Unix forwarding permissions. A blanket
        # TCP deny also blocks Unix channels; allow only the exact socket.
        f'PermitOpen=[{home}/.config/herdr/herdr.sock]:*',
        'AllowAgentForwarding=no', 'X11Forwarding=no', 'Subsystem=sftp internal-sftp',
    ]
    args = ['/usr/sbin/sshd', '-D', '-e', '-f', '/dev/null', '-p', '2222']
    for option in options:
        args.extend(['-o', option])
    return args


def launch(name, check=False):
    if os.geteuid() != 0:
        raise PermissionError('the installed SSH entrypoint must run as root')
    account = pwd.getpwnam(name)
    validate_identity(account.pw_name, account.pw_uid, account.pw_dir)
    result = subprocess.run(
        ['/usr/bin/tailscale', 'status', '--json'], check=True,
        capture_output=True, text=True, timeout=10, env=SYSTEM_ENV,
    )
    address = tailnet_ipv4(json.loads(result.stdout))
    args = sshd_argv(account.pw_name, account.pw_uid, account.pw_dir, address)
    if check:
        subprocess.run([args[0], '-t', *args[3:]], check=True, timeout=10, env=SYSTEM_ENV)
        print('Heeler SSH configuration valid; no listener started')
        return
    os.execve(args[0], args, SYSTEM_ENV)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--user', required=True)
    parser.add_argument('--check', action='store_true', help='validate effective sshd configuration without listening')
    args = parser.parse_args()
    try:
        launch(args.user, check=args.check)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        print(f'Heeler SSH not started: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
