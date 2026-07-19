# Vekil Shell Integration Design

**Date:** 2026-07-19

## Goal

Load the repository-managed Vekil client environment automatically in every
interactive zsh session while preserving an explicit, convenient way to launch
Claude Code or Codex without the proxy.

## Design

`core/shell/load-custom.zsh` will explicitly source `ai/vekil/env.zsh` after the
normal core, language, and tool customizations. The source occurs before
platform, profile, and `.localrc` loading so machine-specific configuration can
still override the managed proxy environment.

`ai/vekil/env.zsh` will define two convenience functions regardless of proxy
readiness:

- `claude-direct` launches the external `claude` command after removing the
  Vekil-managed Anthropic endpoint, dummy API key, and default model variables
  from the child environment.
- `codex-direct` launches the external `codex` command after removing the
  Vekil-managed OpenAI endpoint and dummy API key variables from the child
  environment. Executing through `env` bypasses the proxied zsh `codex`
  function.

Both functions forward arguments unchanged and affect only the launched child
process. The current shell remains configured for proxied `claude` and `codex`
commands. User-supplied real API keys and custom Claude model values are
preserved; only values marked as Vekil-managed are removed.

## Compatibility and Failure Behavior

If the proxy is unavailable, the existing readiness logic leaves proxy client
variables unset. The direct functions remain available because they do not
depend on Vekil readiness. Existing user-defined endpoint variables and
machine-local `.localrc` overrides retain their current precedence.

Direct Claude execution relies on Claude Code's normal stored authentication or
an explicitly supplied real credential. Direct Codex execution relies on its
normal OpenAI authentication and repository-managed non-provider configuration.

## Verification

Add shell-loading coverage that proves a fresh loader invocation sources the
Vekil environment when a healthy endpoint is available. Add focused tests using
fake client executables to prove `claude-direct` and `codex-direct` remove only
their proxy variables, forward arguments, and invoke the external commands.

Run the focused shell tests followed by the complete `make check` gate.

## Exclusions

- No generic proxy toggle or persistent disable setting.
- No changes to Vekil lifecycle, authentication, networking, or model routing.
- No changes to direct-client authentication storage.
