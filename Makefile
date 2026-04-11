.PHONY: install bootstrap update relink ai ai-check

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

ai: ## Install/update all AI tool configs (opencode, claude, copilot)
	@for installer in ai/*/install.sh; do \
		echo "Running $$installer..."; \
		bash "$$installer"; \
	done

ai-check: ## Dry-run: show what AI install would do
	bash ai/opencode/install.sh --check

validate: ## Validate AI config structure (agents, commands, skills)
	bash bin/validate-ai --verbose

# ── Help ──────────────────────────────────────────────────────────────────────

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
