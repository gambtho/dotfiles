.PHONY: install bootstrap update relink ai ai-check ai-heeler ai-heeler-check ai-heeler-setup automations automations-check automation-run pins pins-check pins-update check syntax lint test python-test pi-runtime-test validate

# ── Main targets ──────────────────────────────────────────────────────────────

install: ## Run full install (packages, runtimes, shell, git, neovim, fonts, ai)
	bash bin/dot-install

bootstrap: ## First-time setup (prereqs, gitconfig, profile, symlinks)
	bash libexec/bootstrap

update: ## Update packages, runtimes, neovim plugins
	bash bin/dot-update

relink: ## Remove dead symlinks and re-create from current layout
	bash libexec/relink

# ── Opt-in host cache maintenance ─────────────────────────────────────────────

.PHONY: cache-maintenance cache-maintenance-check

cache-maintenance: ## Install and enable weekly native cache pruning on this machine
	bash tools/cache-maintenance/install.sh --apply

cache-maintenance-check: ## Inspect cache timer and last service result without cleanup
	bash tools/cache-maintenance/install.sh --check

# ── Linux credential keyring ───────────────────────────────────────────────────

.PHONY: keyring-check keyring-unlock

keyring-check: ## Inspect the existing GNOME login keyring without activating it
	/usr/bin/python3 libexec/keyring check

keyring-unlock: ## Explicitly unlock the GNOME login keyring with hidden password input
	/usr/bin/python3 libexec/keyring unlock

# ── AI tools ──────────────────────────────────────────────────────────────────

.PHONY: agent-knowledge agent-knowledge-check agent-knowledge-adopt agent-knowledge-sync

agent-knowledge: ## Ensure private knowledge storage; notify rather than refresh existing notes
	bash libexec/agent-knowledge ensure

agent-knowledge-check: ## Inspect private knowledge readiness without filesystem changes
	bash libexec/agent-knowledge check

agent-knowledge-adopt: ## Explicit stopped-Pi migration of existing private review records
	bash libexec/agent-knowledge adopt

agent-knowledge-sync: ## Explicit stopped-Pi fast-forward and verified pending publication
	bash libexec/agent-knowledge sync

# Failures are aggregated rather than aborting the loop: one broken installer
# must not block the rest, but it must still fail the target — a plain loop
# reports only the last installer's status and hides every earlier failure.
ai: ## Reconcile Pi configuration and bootstrap Copilot CLI
	@failed=""; for installer in ai/pi/install.sh ai/copilot/install.sh; do \
		echo "Running $$installer..."; \
		bash "$$installer" || failed="$$failed $$installer"; \
	done; \
	if [ -n "$$failed" ]; then echo "make ai: failed:$$failed" >&2; exit 1; fi

ai-check: ## Dry-run: show what the AI installers would do
	@failed=""; for installer in ai/pi/install.sh ai/copilot/install.sh; do \
		echo "Checking $$installer..."; \
		bash "$$installer" --check || failed="$$failed $$installer"; \
	done; \
	if [ -n "$$failed" ]; then echo "make ai-check: failed:$$failed" >&2; exit 1; fi

ai-heeler: ## Prepare opt-in default Herdr/Heeler persistence without live takeover
	bash tools/herdr/heeler/install.sh --apply

ai-heeler-check: ## Inspect prepared or live managed Heeler state without mutation
	bash tools/herdr/heeler/install.sh --check

ai-heeler-setup: ## Guide explicit per-host enrollment and one operator-approved Root publication
	bash tools/herdr/heeler/setup.sh

automations: ## Install and enable the weekly review timers on this machine
	bash tools/automations/install.sh --apply

automations-check: ## Show weekly review timers and each automation's last result
	bash tools/automations/install.sh --check

automation-run: ## Run one review now: make automation-run NAME=<name> [DRY_RUN=1]
	python3 libexec/automation_run.py "$(NAME)" $(if $(DRY_RUN),--dry-run)

pins: ## List managed dependency versions and refs
	bash libexec/versions list

pins-check: ## Check managed dependency pins for updates
	bash libexec/versions check

pins-update: ## Interactively update managed dependency pins
	bash libexec/versions update

validate: ## Validate AI config structure (agents, commands, skills)
	bash libexec/validate-ai --verbose

# ── Verification ───────────────────────────────────────────────────────────────

check: syntax lint test python-test validate

syntax:
	@bash -o pipefail -c 'libexec/list-check-files bash | xargs -0 -n 1 bash -n'
	@bash -o pipefail -c 'libexec/list-check-files zsh | xargs -0 -n 1 zsh -n'

lint:
	@bash -o pipefail -c 'libexec/list-check-files shellcheck | xargs -0 shellcheck -x -S warning -e SC1091'
	@bash -o pipefail -c 'libexec/list-check-files shfmt | xargs -0 shfmt -d -i 2 -ci'

test:
	bats tests

python-test:
	python3 -m unittest discover -s tests/python -p 'test_*.py'

pi-runtime-test: ## Exercise selected installed Pi/permission/subagents/LSP packages without paid providers
	node --test tests/pi_extension_runtime.test.mjs tests/pi_native_packages.test.mjs tests/pi_settings_publication.test.mjs

# ── Help ──────────────────────────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
