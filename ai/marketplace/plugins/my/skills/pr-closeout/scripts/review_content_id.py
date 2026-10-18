#!/usr/bin/env python3
"""Fingerprint explicitly reviewed working content, stable across commit/staging.

Run from the reviewed checkout with --base COMMIT --paths /scratch/scope.json.
The JSON array must name the complete changed-file scope, including untracked
files but excluding Git-ignored scratch. Only approved paths are hashed; Git
performs normal changed-name discovery. Requires Python 3.11+.
This is evidence for a cooperative local workflow, not a worktree lock/sandbox.
"""

import argparse
import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path, PurePosixPath


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def identity(base, paths_file):
    root = Path(os.fsdecode(git("rev-parse", "--show-toplevel").rstrip(b"\n"))).resolve()
    base_sha = git("rev-parse", "--verify", "--end-of-options", f"{base}^{{commit}}").decode().strip()
    paths = json.loads(Path(paths_file).read_text())
    if not isinstance(paths, list):
        raise ValueError("review paths must be a JSON array")
    for name in paths:
        if not isinstance(name, str) or name in ("", ".") or "\0" in name:
            raise ValueError("unsafe review path")
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or relative.as_posix() != name:
            raise ValueError("unsafe review path")
    # --no-renames keeps the path universe identical before and after staging or
    # committing a reviewed added/renamed file. Enumerating names reads no body.
    changed = git("-C", str(root), "diff", "--no-ext-diff", "--name-only", "--no-renames", "-z", base_sha, "--")
    changed += git("-C", str(root), "ls-files", "--others", "--exclude-standard", "-z")
    if set(map(os.fsdecode, changed.rstrip(b"\0").split(b"\0"))) - {""} != set(paths):
        raise ValueError("scope does not match current changed paths; review new inputs first")
    entries = []
    for name in sorted(set(paths)):
        path = root / name
        # Do not follow a parent directory replaced with an external symlink.
        if any(parent.is_symlink() for parent in path.parents if parent != root and root in parent.parents):
            raise ValueError("unsafe symlinked review parent")
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            entries.append([name, "absent"])
            continue
        if stat.S_ISLNK(mode):
            entries.append([name, "symlink", os.readlink(path)])
        elif stat.S_ISREG(mode):
            with path.open("rb") as source:
                digest = hashlib.file_digest(source, "sha256").hexdigest()
            entries.append([name, "file", bool(mode & 0o111), digest])
        else:
            raise ValueError("nonregular review input; record separate evidence")
    payload = json.dumps([base_sha, entries], ensure_ascii=True, separators=(",", ":")).encode()
    return {"scheme": "review-content-v1", "base": base_sha, "scope": sorted(set(paths)), "content_sha256": hashlib.sha256(payload).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--paths", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(identity(args.base, args.paths)))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"review content identity: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
