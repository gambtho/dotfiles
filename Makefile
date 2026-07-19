.PHONY: install bootstrap update relink ai ai-check pins pins-check pins-update check syntax lint test validate

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

ai: ## Install/update all AI tool configs (claude, codex, litellm)
	@for installer in ai/*/install.sh; do \
		echo "Running $$installer..."; \
		bash "$$installer"; \
	done

ai-check: ## Dry-run: show what AI install would do
	@for installer in ai/*/install.sh; do \
		echo "Checking $$installer..."; \
		bash "$$installer" --check; \
	done

pins: ## List managed dependency versions and refs
	bash bin/versions list

pins-check: ## Check managed dependency pins for updates
	bash bin/versions check

pins-update: ## Interactively update managed dependency pins
	bash bin/versions update

validate: ## Validate AI config structure (agents, commands, skills)
	bash bin/validate-ai --verbose

# ── Verification ───────────────────────────────────────────────────────────────

check: syntax lint test validate

syntax:
	@bash -n $$(find bin -type f -not -name '*.zsh'; find ai core fonts languages platforms work -type f -name '*.sh')
	@zsh -n $$(find core languages platforms profiles tools work -type f \( -name '*.zsh' -o -name '*.symlink' \))

lint:
	shellcheck -x $$(find bin -type f -not -name '*.zsh'; find ai core fonts languages platforms work -type f -name '*.sh')
	shfmt -d -i 2 -ci $$(find bin ai core fonts languages platforms work -type f -name '*.sh') tests/test_helper.bash

test:
	bats tests

# ── Help ──────────────────────────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
