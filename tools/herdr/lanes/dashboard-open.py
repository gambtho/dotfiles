#!/usr/bin/env python3
"""Focus Projects, or open the installed dashboard in its primary pane."""
import os
import subprocess
import sys
from pathlib import Path

from lane import fresh_pane, herdr, unique, wait_shell


def open_dashboard():
    spaces = herdr('workspace', 'list')['workspaces']
    existing = unique(spaces, 'Projects')
    if existing:
        herdr('workspace', 'focus', existing['workspace_id'])
        return
    data = Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local/share')
    dashboard = data / 'dotfiles/herdr-dashboard'
    if not (dashboard / 'dashboard.py').is_file():
        raise ValueError('dashboard is not installed; run make herdr-dashboard')
    result = herdr('workspace', 'create', '--cwd', str(dashboard), '--label', 'Projects',
                   '--focus', '--env', 'DOTFILES_KEYRING_PROMPT=0')
    pane = fresh_pane(result, spaces, 'Projects')
    wait_shell(pane)
    herdr('pane', 'run', pane, './dashboard.py')


def main():
    try:
        open_dashboard()
    except (ValueError, KeyError, TypeError, AttributeError, OSError, subprocess.SubprocessError) as error:
        print(f'Projects: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
