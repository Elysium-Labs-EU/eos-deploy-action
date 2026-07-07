#!/bin/bash
set -euo pipefail

SSH_HOST="${SSH_HOST:?SSH_HOST must be set}"
SSH_USER="${SSH_USER:?SSH_USER must be set}"
SSH_KEY="${SSH_KEY:?SSH_KEY must be set}"
SSH_PORT="${SSH_PORT:-22}"
SERVICE_YAML="${SERVICE_YAML:?SERVICE_YAML must be set}"
TARGET_DIR="${TARGET_DIR:-}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-30}"
SSH_COMMAND_TIMEOUT="${SSH_COMMAND_TIMEOUT:-300}"

# ── SSH key — load into agent, never touch disk ──────────────────────────────

eval "$(ssh-agent -s)" > /dev/null

# Detect passphrase-protected key before attempting to add
if ! echo "$SSH_KEY" | ssh-keygen -y -P "" -f /dev/stdin > /dev/null 2>&1; then
    echo "Error: SSH key is passphrase-protected. Passphrase-protected keys are not supported."
    exit 1
fi

echo "$SSH_KEY" | ssh-add -

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
COMMAND_TIMEOUT="$2"

if ! command -v eos &>/dev/null; then
    echo "eos not found on remote host. Install: https://codeberg.org/Elysium_Labs/eos/releases"
    exit 1
fi

deploy_err=$(mktemp)
result=$(timeout "$COMMAND_TIMEOUT" eos api run -f "$SERVICE_YAML" 2>"$deploy_err")
exit_code=$?

if [[ $exit_code -eq 124 ]]; then
    echo "eos api run timed out after ${COMMAND_TIMEOUT}s"
    exit 1
fi

if [[ $exit_code -ne 0 ]]; then
    echo "eos api run failed (exit $exit_code):"
    cat "$deploy_err"
    exit 1
fi

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
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
    -p "$SSH_PORT" \
    "$SSH_USER@$SSH_HOST" \
    "bash -s -- '$RESOLVED_YAML' '$SSH_COMMAND_TIMEOUT'" <<< "$REMOTE_SCRIPT")

exit_code=$?

if [[ $exit_code -ne 0 ]]; then
    echo "$output"
    exit $exit_code
fi

# Write status to GITHUB_OUTPUT
status=$(echo "$output" | grep '^EOS_DEPLOY_STATUS=' | cut -d= -f2 || true)
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "status=${status:-unknown}" >> "$GITHUB_OUTPUT"
fi

if [[ "$status" == "restarted" ]]; then
    echo "Service restarted successfully"
else
    echo "Service started fresh"
fi
