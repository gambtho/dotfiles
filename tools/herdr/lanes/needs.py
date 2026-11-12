#!/usr/bin/env python3
"""Live project summary in a "◆ <project>" heading pane.

Every 5 s it:
- publishes `needs` on each ◆ heading (lanes in its worktree group that are blocked
  or report phase=needs-decision), which the sidebar shows as the red count;
- draws this project's numbered/coord lanes, grouped or not, with state, phase and
  task. Longest matching ~/<project>-local folder owns each label. The summary can
  include ungrouped needs-you lanes that are not in the sidebar's grouped count.
Run it in the heading's own pane. Ctrl-C stops it.
"""
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

ICON = {"blocked": "×", "working": "◐", "idle": "○", "done": "✓", "unknown": "·"}
RED, YEL, GRN, DIM, BOLD, OFF = "\033[31m", "\033[33m", "\033[32m", "\033[2m", "\033[1m", "\033[0m"
COLOR = {"blocked": RED, "working": YEL, "idle": GRN, "done": GRN, "unknown": DIM}


def herdr(*args):
    out = subprocess.run(["herdr", *args], capture_output=True, text=True,
                         timeout=5, check=True).stdout
    return json.loads(out)["result"]


def needs_you(w):
    return w["agent_status"] == "blocked" or (w.get("tokens") or {}).get("phase") == "needs-decision"


def section(w):
    phase = (w.get("tokens") or {}).get("phase")
    if needs_you(w):
        return 0, "needs you"
    if phase == "ready":
        return 1, "ready"
    if w["agent_status"] == "working":
        return 2, "working"
    return 3, {"unknown": "no agent"}.get(w["agent_status"], w["agent_status"])


def lane_key(label, project):
    rest = label[len(project) + 1:]
    return (0, 0) if rest == "coord" else (1, int(rest)) if rest.isdigit() else (2, rest)


def project_for_label(label):
    projects = (folder.name[:-6] for folder in Path.home().glob("*-local") if folder.is_dir())
    return max((project for project in projects
                if label == project or label.startswith(project + "-")), key=len, default=None)


def publish(spaces, last):
    for head in spaces:
        wt = head.get("worktree") or {}
        if not head["label"].startswith("◆ ") or wt.get("is_linked_worktree", False):
            continue
        # New headings have no provenance until their first linked lane opens.
        repo = wt.get("repo_key")
        n = sum(1 for w in spaces if repo and (w.get("worktree") or {}).get("repo_key") == repo
                and w["worktree"]["is_linked_worktree"] and needs_you(w))
        if last.get(head["workspace_id"]) != n or int(time.time()) % 60 < 5:
            subprocess.run(["herdr", "workspace", "report-metadata", head["workspace_id"],
                            "--source", "projects", "--token", f"needs={n}"],
                           capture_output=True, timeout=5, check=True)
            last[head["workspace_id"]] = n


def draw(spaces, me):
    cols = shutil.get_terminal_size((80, 24)).columns
    head = next((w for w in spaces if w["workspace_id"] == me), None)
    project = head["label"][2:] if head and head["label"].startswith("◆ ") else None
    if not project:
        return [f"{DIM}Not in a ◆ heading pane; publishing counts only.{OFF}"]
    repo = ((head or {}).get("worktree") or {}).get("repo_key")
    lanes = [w for w in spaces if re.fullmatch(re.escape(project) + r"-(coord|\d+)", w["label"])
             and project_for_label(w["label"]) == project]
    lanes.sort(key=lambda w: (section(w)[0], lane_key(w["label"], project)))
    counts = {}
    for w in lanes:
        counts[section(w)[1]] = counts.get(section(w)[1], 0) + 1
    n = counts.get("needs you", 0)
    title = f"{BOLD}◆ {project}{OFF}" + (f"  {RED}{BOLD}{n} need{'s' if n == 1 else ''} you{OFF}" if n else f"  {DIM}nothing needs you{OFF}")
    lines = [title + f"   {DIM}{time.strftime('%H:%M:%S')}{OFF}", ""]
    if not lanes:
        lines.append(f"{DIM}No {project} lanes open.{OFF}")
    for w in lanes:
        tokens = w.get("tokens") or {}
        st = w["agent_status"]
        name = w["label"][len(project) + 1:]
        sec = section(w)[1]
        grouped = bool(repo) and (w.get("worktree") or {}).get("repo_key") == repo
        task = tokens.get("task", "")
        tag = "" if grouped else f" {DIM}(not grouped){OFF}"
        left = f"  {COLOR.get(st, DIM)}{ICON.get(st, '·')}{OFF} {name:<6} {(RED if sec == 'needs you' else DIM)}{sec:<10}{OFF} "
        room = max(cols - 22 - (14 if not grouped else 0), 10)
        lines.append(left + (task[:room - 1] + "…" if len(task) > room else task) + tag)
    lines += ["", DIM + " · ".join(f"{k} {v}" for k, v in counts.items()) + OFF,
              f"{DIM}Ctrl-C stops this summary and the sidebar count.{OFF}"]
    return lines


def main():
    me = os.environ.get("HERDR_WORKSPACE_ID", "")
    last = {}
    while True:
        try:
            spaces = herdr("workspace", "list")["workspaces"]
            publish(spaces, last)
            lines = draw(spaces, me)
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            # Keep going on CLI/read failures, but make the failure visible.
            lines = [f"{RED}{time.strftime('%H:%M:%S')} read failed: {error}{OFF}"]
        print("\033[H\033[2J" + "\n".join(lines), end="", flush=True)
        time.sleep(5)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
