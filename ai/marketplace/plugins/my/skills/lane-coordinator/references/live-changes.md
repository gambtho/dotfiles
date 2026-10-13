# Live changes

For anything outside a repo: cloud resources, tenant or app registrations, role
assignments, cluster objects, bot configuration.

1. **Propose before acting.** The lane shows the exact commands (subscription, resource
   group, region, name, tier, tags; context and namespace pinned on every call) and
   waits for the user's go. Read-only discovery first: confirm the target doesn't already
   exist and that nothing else owns it.
2. **Record each change with its undo** in a `LIVE-CHANGES.md` next to the lane's outputs:
   what was created or changed, when, its identity, and the exact undo command. Never
   adopt or delete something the lane didn't create.
3. **Decide keep or delete explicitly.** Default to deleting at the end; keep only when
   the user says so (e.g. a free resource a later lane will reuse), and record why.
4. **Credentials:** prefer short-lived tokens; otherwise a private 0600 file that's
   deleted at the end. Never print, log or pass secrets as arguments.
5. **Identity lookups:** if Graph is blocked, use the user's object ID from memory with an
   explicit principal type rather than looking it up.
6. Stop rather than silently changing region, tier, scope or permissions when something
   is refused.
