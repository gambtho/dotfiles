# Live changes

For anything outside a repo: cloud resources, tenant or app registrations, role
assignments, cluster objects, bot configuration.

1. **Follow the project's authority table.** Where it permits, an approved plan with a cost cap
   covers the lane's own resources. Otherwise, propose the exact commands and wait
   for the user's go. Specify subscription, resource group, region, name, tier and tags;
   pin context and namespace on every call. Read-only discovery first: confirm the
   target doesn't already exist and that nothing else owns it.
2. **Record each change with its undo** in a `LIVE-CHANGES.md` next to the lane's outputs:
   what was created or changed, when, its identity, and the exact undo command. Never
   adopt or delete something the lane didn't create.
3. **Decide keep or delete explicitly.** Default to deleting at the end; keep only when
   the user says so (e.g. a free resource a later lane will reuse), and record why.
4. **Credentials:** Use short-lived tokens. A temporary credential file is an option
   only where the project's rules permit it; keep it private (0600) and delete it at the end.
   Never print, log or pass secrets as arguments.
5. **Identity lookups:** if Graph is blocked, a remembered object ID may be proposed, but
   only after the user confirms it against an authoritative source (the portal, or a
   role-assignment readback). Always pass an explicit principal type.
6. Stop rather than silently changing region, tier, scope or permissions when something
   is refused.
