.PHONY: help list setup lint lint-fix build test-docker release pre-release clean

IMAGE ?= ghcr.io/elysium-labs/eos-deploy-action
TAG   ?= dev

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' | sort

list: help ## List all available commands

setup: ## Install dev tools (shellcheck, lefthook) and git hooks
	@echo "Installing shellcheck..."
	@command -v shellcheck >/dev/null 2>&1 && echo "  shellcheck already installed" || \
		(command -v brew >/dev/null 2>&1 && brew install shellcheck || \
		 command -v apt-get >/dev/null 2>&1 && sudo apt-get install -y shellcheck || \
		 echo "  Install shellcheck manually: https://www.shellcheck.net/")
	@echo "Installing lefthook..."
	@command -v lefthook >/dev/null 2>&1 && echo "  lefthook already installed" || \
		(command -v brew >/dev/null 2>&1 && brew install lefthook || \
		 go install github.com/evilmartians/lefthook@latest)
	@echo "Installing git hooks..."
	lefthook install
	@echo "Setup complete."

lint: ## Lint shell scripts with shellcheck
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not found. Run: make setup"; exit 1; }
	shellcheck scripts/*.sh

lint-fix: ## Show shellcheck suggestions interactively
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not found. Run: make setup"; exit 1; }
	shellcheck --format=diff scripts/*.sh || true

build: ## Build Docker image locally (IMAGE=..., TAG=...)
	docker build -t $(IMAGE):$(TAG) .

test-docker: build ## Build and smoke-test the Docker image (prints usage without required vars)
	@echo "--- entrypoint smoke test (expect: SSH_HOST must be set) ---"
	docker run --rm $(IMAGE):$(TAG) 2>&1 | grep -q "SSH_HOST" && \
		echo "PASS: entrypoint validates required env vars" || \
		echo "FAIL: unexpected output"

release: ## Tag and push release (requires TAG=v0.1.0)
	@if [ -z "$(TAG)" ] || [ "$(TAG)" = "dev" ]; then echo "Usage: make release TAG=v0.1.0"; exit 1; fi
	git tag -a $(TAG) -m "Release $(TAG)"
	git push origin $(TAG)
	@echo "Tagged $(TAG) — CI will build and push to GHCR."

pre-release: ## Tag and push pre-release (requires TAG=v0.1.0-rc.1)
	@if [ -z "$(TAG)" ] || [ "$(TAG)" = "dev" ]; then echo "Usage: make pre-release TAG=v0.1.0-rc.1"; exit 1; fi
	git tag -a $(TAG) -m "Pre-release $(TAG)"
	git push origin $(TAG)

clean: ## Remove locally built images
	docker rmi $(IMAGE):$(TAG) 2>/dev/null || true
