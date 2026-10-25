# Contributing to eos-deploy-action

## Prerequisites

`bash`, `docker`, and `make` are required. Verify with `docker --version` and `make --version`.

## Setup

```bash
git clone https://github.com/Elysium-Labs-EU/eos-deploy-action
cd eos-deploy-action
make setup
```

`make setup` installs the development toolchain (shellcheck, lefthook) and the pre-commit git hook. Run `make help` to see all available targets; always prefer a make target over raw `shellcheck` or `docker` commands.

## Making Changes

The action's logic lives in `scripts/deploy.sh`, run inside the container defined by `Dockerfile` and wired up via `action.yml`. There is no STYLE.md; follow the existing script's conventions — `set -euo pipefail`, `${VAR:?msg}` for required inputs, `${VAR:-default}` for optional ones.

Open an issue before starting work on a non-trivial change, such as adding a new input or changing SSH handling. This avoids duplicate effort and makes sure the direction fits the project. Small fixes and documentation improvements can go straight to a PR.

Branch from `main` and name the branch after the change: `feat/known-hosts-input`, `fix/ssh-timeout-default`, `test/passphrase-key-detection`.

## Running Tests

```bash
make lint
make test-docker
make test-ssh
```

`make lint` runs ShellCheck against `scripts/*.sh`; the same check runs as a pre-commit hook via lefthook. `make test-docker` builds the Docker image and smoke-tests the entrypoint's required-env-var validation. `make test-ssh` runs `deploy.sh` against a throwaway sshd in Docker and checks host key pinning, remote command quoting, and error output; run it when you touch SSH handling. All must pass before opening a PR.

## Commit Format

eos-deploy-action uses [Conventional Commits](https://www.conventionalcommits.org). The prefix determines which section of the changelog the commit appears in.

```
feat: add known_hosts input for strict host key checking
fix: default SSH_COMMAND_TIMEOUT when unset
test: cover passphrase-protected key detection
refactor: extract ssh-agent setup to its own function
docs: document SSH_KNOWN_HOSTS env variable
chore: bump action-shellcheck to v2.0.0
```

Breaking changes go in the commit footer: `BREAKING CHANGE: <description>`.

## Opening a Pull Request

The PR description should explain *why* the change is needed, not just what it does. Link the issue it resolves with `Closes #N`.

All CI checks must be green. A PR that breaks ShellCheck or the Docker smoke test will not be reviewed until it is fixed.
