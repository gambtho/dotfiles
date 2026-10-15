.PHONY: install bootstrap update relink ai ai-check ai-paseo ai-paseo-check ai-paseo-domain-check ai-paseo-domain-setup ai-heeler ai-heeler-check pins pins-check pins-update check syntax lint test python-test pi-runtime-test validate

# ── Main targets ──────────────────────────────────────────────────────────────

install: ## Run full install (packages, runtimes, shell, git, neovim, fonts, ai)
	bash bin/dot-install

bootstrap: ## First-time setup (prereqs, gitconfig, profile, symlinks)
	bash libexec/bootstrap

update: ## Update packages, runtimes, neovim plugins
	bash bin/dot-update

relink: ## Remove dead symlinks and re-create from current layout
	bash libexec/relink

# ── AI tools ──────────────────────────────────────────────────────────────────

# Failures are aggregated rather than aborting the loop: one broken installer
# must not block the rest, but it must still fail the target — a plain loop
# reports only the last installer's status and hides every earlier failure.
ai: ## Reconcile Pi configuration and update extensions through native Pi
	@failed=""; for installer in ai/pi/install.sh; do \
		echo "Running $$installer..."; \
		bash "$$installer" || failed="$$failed $$installer"; \
	done; \
	if [ -n "$$failed" ]; then echo "make ai: failed:$$failed" >&2; exit 1; fi

ai-check: ## Dry-run: show what the Pi install would do
	@failed=""; for installer in ai/pi/install.sh; do \
		echo "Checking $$installer..."; \
		bash "$$installer" --check || failed="$$failed $$installer"; \
	done; \
	if [ -n "$$failed" ]; then echo "make ai-check: failed:$$failed" >&2; exit 1; fi

ai-paseo: ## Install/update the opt-in Paseo
	bash ai/pi/paseo/install.sh --apply

ai-paseo-check: ## Inspect Paseo state without mutation
	bash ai/pi/paseo/install.sh --check

ai-paseo-domain-check: ## Inspect Paseo custom-domain state without mutation
	bash ai/pi/paseo/custom-domain.sh check

ai-paseo-domain-setup: ## Build and install the opt-in custom-domain Caddy service
	bash ai/pi/paseo/custom-domain.sh setup

ai-heeler: ## Prepare opt-in default Herdr/Heeler persistence without live takeover
	bash tools/herdr/heeler/install.sh --apply

ai-heeler-check: ## Inspect prepared or live managed Heeler state without mutation
	bash tools/herdr/heeler/install.sh --check

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
	node --test tests/pi_extension_runtime.test.mjs tests/pi_native_packages.test.mjs

# ── Help ──────────────────────────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
