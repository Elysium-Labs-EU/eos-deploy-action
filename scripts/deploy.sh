#!/bin/bash
# Runs inside the Docker container on the runner.
set -euo pipefail

SSH_HOST="${SSH_HOST:?SSH_HOST must be set}"
SSH_USER="${SSH_USER:?SSH_USER must be set}"
SSH_KEY="${SSH_KEY:?SSH_KEY must be set}"
SSH_PORT="${SSH_PORT:-22}"
SERVICE_YAML="${SERVICE_YAML:?SERVICE_YAML must be set}"
TARGET_DIR="${TARGET_DIR:-}"

# ── SSH key — load into agent, never touch disk ──────────────────────────────

eval "$(ssh-agent -s)" > /dev/null
echo "$SSH_KEY" | ssh-add - 2>/dev/null

# ── resolve path ─────────────────────────────────────────────────────────────

if [[ "$SERVICE_YAML" = /* ]]; then
    RESOLVED_YAML="$SERVICE_YAML"
elif [[ -n "$TARGET_DIR" ]]; then
    RESOLVED_YAML="$TARGET_DIR/$SERVICE_YAML"
else
    RESOLVED_YAML="$SERVICE_YAML"
fi

# ── remote deploy ─────────────────────────────────────────────────────────────

REMOTE_SCRIPT=$(cat <<'REMOTE'
set -euo pipefail

SERVICE_YAML="$1"

if ! command -v eos &>/dev/null; then
    echo "eos not found on remote host. Install: https://codeberg.org/Elysium_Labs/eos/releases"
    exit 1
fi

deploy_err=$(mktemp)
result=$(eos api run -f "$SERVICE_YAML" 2>"$deploy_err")
exit_code=$?

if [[ $exit_code -ne 0 ]]; then
    echo "eos api run failed (exit $exit_code):"
    cat "$deploy_err"
    exit 1
fi

echo "$result"

if echo "$result" | grep -q '"restarted":true'; then
    echo "EOS_DEPLOY_STATUS=restarted"
else
    echo "EOS_DEPLOY_STATUS=started"
fi
REMOTE
)

output=$(ssh \
    -o StrictHostKeyChecking=accept-new \
    -o BatchMode=yes \
    -p "$SSH_PORT" \
    "$SSH_USER@$SSH_HOST" \
    "bash -s -- '$RESOLVED_YAML'" <<< "$REMOTE_SCRIPT")

exit_code=$?

echo "$output"

if [[ $exit_code -ne 0 ]]; then
    exit $exit_code
fi

# Write status to GITHUB_OUTPUT (runner env var, mounted into container).
status=$(echo "$output" | grep '^EOS_DEPLOY_STATUS=' | cut -d= -f2 || true)
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "status=${status:-unknown}" >> "$GITHUB_OUTPUT"
fi

if [[ "$status" == "restarted" ]]; then
    echo "::notice::Service restarted successfully"
else
    echo "::notice::Service started fresh"
fi
