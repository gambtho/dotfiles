# Synchronous Vekil Shell Loading

## Problem

`core/shell/zshrc.symlink` defers `load_custom`, which currently sources
`ai/vekil/env.zsh`. A new interactive shell can therefore run the raw Codex
binary before Vekil installs its managed `codex` function. If that shell
inherits `OPENAI_API_KEY=dummy`, Codex sends the placeholder key directly to
OpenAI.

## Design

Source `ai/vekil/env.zsh` synchronously in `zshrc.symlink` before scheduling
`load_custom` with `zsh-defer`. Keep the existing source in `load-custom.zsh`
as an idempotent fallback for callers that load customizations directly.

All other shell customization remains deferred. No proxy lifecycle, Codex
configuration, or devcontainer behavior changes.

## Verification

Add a shell-loading regression test whose `zsh-defer` stub queues but does not
execute `load_custom`. After sourcing `zshrc.symlink`, the test requires the
managed `codex` function to exist. Run the focused shell-loading tests and the
full Bats suite.
