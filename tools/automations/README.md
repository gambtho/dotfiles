# Weekly automations

Three reviews run from systemd user timers on Monday mornings. Each one opens a pull request carrying a report, with small fixes when they are safe. Nothing merges by itself.

| Automation | Timer | Publishes to | Can include fixes |
|---|---|---|---|
| `tooling-radar` | 06:00 | this repository | Docs and the Herdr config template only |
| `dotfiles-health` | 07:00 | this repository | Mechanical docs fixes only |
| `lane-review` | 08:00 | the private `agent-knowledge` repository | No; skill changes appear as diffs in the report |

The report is a rolling file under `docs/automation-reports/` (`automation-reports/` in the private repository), so a PR's diff shows what changed since last week and the files don't pile up.

## Commands

```bash
make automations
```

```bash
make automations-check
```

```bash
make automation-run NAME=dotfiles-health DRY_RUN=1
```

`make automations` installs and enables the timers. It must run from the primary `~/.dotfiles` checkout, and it is opt-in per machine because every run uses model quota and opens PRs. `make automations-check` shows the next run times and the last result of each automation. A dry run does the full review and policy checks but stops before pushing. It writes the diff beside the status files in `~/.local/state/dotfiles-automations/`.

## How a run works

1. **Backpressure.** If this automation already has an open PR, the run stops without spending anything. Merge or close last week's PR to resume.
2. **Gather.** The runner clones a fresh copy of the target and collects evidence. Failed checks are recorded as `UNKNOWN` rather than skipped.
3. **Review.** Pi runs in a bubblewrap sandbox with only file tools. It sees the clone and the evidence, with no shell, no web tools and no extensions other than `guard.ts`.
4. **Check.** The runner applies the path policy and a secret scan to what the agent produced.
5. **Publish.** The runner, not the agent, commits, pushes and opens the PR. The PR's CI is the test gate, because agent-written code is never run on this machine.

If the agent changes nothing, there is no PR. Each automation has a short list of files it may fix, in `libexec/automation_run.py`. If fixes go outside that list, touch a protected path, or exceed 12 files or 300 lines, they are dropped and the report still goes out, with a note in the PR. If the secret scan matches anything, nothing is published and the run is marked failed.

## Why the agent is sandboxed

The radar reads text written by strangers, and this machine's `gh` token can delete repositories, so a prompt injection must not be able to reach anything valuable.

- The agent's `$HOME` is empty apart from the Pi runtime and a throwaway agent directory. It cannot see `~/*-local`, `~/.ssh`, the `gh` keyring or real Pi sessions.
- The `.git` directory is read-only, so the agent can't plant hooks or config for the publishing step. Publishing also disables hooks.
- The sandbox starts with an empty environment, so tokens and sockets from the caller's shell don't carry over.
- `guard.ts` limits file tools to the clone and the evidence, and rejects path forms Pi would reinterpret after the check (`@`, `~`, `file:` and Unicode spaces). This keeps the credential copy in the throwaway directory out of reach. That directory is deleted when the run ends.
- Pi still needs network access to reach the model, so the sandbox is not offline. It has no tool that can make its own requests.

## Private lane data

`lane-review` copies a limited snapshot rather than mounting the project folders: each project's rule and state files, plus the start of recently changed lane records. `PEOPLE.md` is excluded. The report goes only to a repository the runner has confirmed is private on that same run, and the prompt keeps it at the level of process. Two projects have no Git remote, so this report is the one place a summary of their process leaves the machine. Skill changes it proposes must be copied by hand into a dotfiles PR.

## Rejecting findings

Close the PR without merging, and comment with the reason if it matters. The next run reads recent PRs and comments from the owner, members and collaborators, and does not raise rejected findings again unless the facts change.

## Failures

A failed run opens no PR and sends no notification. The usual cause would be a locked keyring blocking `gh`. Check `make automations-check`, and `~/.local/state/dotfiles-automations/<name>.log` for agent output.
