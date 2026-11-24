# Hosts and lane workers

To avoid local winning by omission, match the lane against each Hosts row's `Use for`;
local is the fallback when no row matches. Record the host, worker choice and brief reason
in its `Host:` line and STATE row's `What / report` cell; the coordinator stays the single
STATE writer.

## Lane workers

A Hosts row whose `Worker` is `lane` opts **that host for that project** into developerlanes.
For start, status, steering, answers, reports, finishing and restart there, read
[the bundled coordinator skill](../SKILL.md#lane-mechanics-read-the-bundled-coordinator)
and follow it. The row grants no new publication, answer or launch authority. Our habits on top:

- **Before first use**, verify the saved host/worker enrollment and the project allowlist.
- **Label and requester.** Every start carries `--label "<project> W<n>" --by <project>-coord`,
  so status, the inbox and notifications show our lane number and which coordinator asked.
- **Inputs.** Pass only the approved context as inert `--input` files: the project
  AGENTS/authority brief, the host-resolved COMMON-RULES and the selected read-only review
  profile. Keep STATE, other lanes' context, credentials and session trees on their owning
  hosts. A project's content goes only to hosts its Hosts table allows.
- **STATE.** Write the IDs the bundled skill tells you to save in the lane's STATE row.
- **One prompt file.** On another machine, a fresh start after a set-aside reuses the same
  prompt file under a new creation ID. Do not rename it to force a new start, which leaves
  two copies of one prompt.
- **Reports.** Before finishing a task, save its fetched report and optional handoff under
  the project's report folder; a displayed remote path is not a local copy. A failed, stale
  or unsafe read is unknown.
- **Readiness.** A row's `readiness` is evidence beside
  [our report checks](../SKILL.md#handle-a-lane-report), not a replacement for them.
- **Answers.** The human answers question cards; the coordinator answers only a
  [covered answer](covered-answers.md).

## Hosts that are not lane workers

Bindings, `herdr-lane --host`, manual copy/start, rsync report fetch and workspace close
are frozen in [the Herdr-only legacy reference](legacy-herdr.md#remote-lanes-on-herdr-hosts).
