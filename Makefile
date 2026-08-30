.PHONY: install bootstrap update relink ai ai-check pins pins-check pins-update check syntax lint test python-test validate

# ── Main targets ──────────────────────────────────────────────────────────────

install: ## Run full install (packages, runtimes, shell, git, neovim, fonts, ai)
	bash bin/install

bootstrap: ## First-time setup (prereqs, gitconfig, profile, symlinks)
	bash bin/bootstrap

update: ## Update packages, runtimes, neovim plugins
	bash bin/dot-update

relink: ## Remove dead symlinks and re-create from current layout
	bash bin/relink

# ── AI tools ──────────────────────────────────────────────────────────────────

# Failures are aggregated rather than aborting the loop: one broken installer
# must not block the rest, but it must still fail the target — a plain loop
# reports only the last installer's status and hides every earlier failure.
ai: ## Install/update Pi and its managed configuration
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

pins: ## List managed dependency versions and refs
	bash bin/versions list

pins-check: ## Check managed dependency pins for updates
	bash bin/versions check

pins-update: ## Interactively update managed dependency pins
	bash bin/versions update

validate: ## Validate AI config structure (agents, commands, skills)
	bash bin/validate-ai --verbose

# ── Verification ───────────────────────────────────────────────────────────────

check: syntax lint test python-test validate

syntax:
	@bash -o pipefail -c 'bin/list-check-files bash | xargs -0 -n 1 bash -n'
	@bash -o pipefail -c 'bin/list-check-files zsh | xargs -0 -n 1 zsh -n'

lint:
	@bash -o pipefail -c 'bin/list-check-files shellcheck | xargs -0 shellcheck -x -S warning -e SC1091'
	@bash -o pipefail -c 'bin/list-check-files shfmt | xargs -0 shfmt -d -i 2 -ci'

test:
	bats tests

python-test:
	python3 -m unittest discover -s tests/python -p 'test_*.py'

# ── Help ──────────────────────────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
