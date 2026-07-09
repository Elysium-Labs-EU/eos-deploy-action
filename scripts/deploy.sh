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
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-}"

# ── SSH key — load into agent, never touch disk ──────────────────────────────

eval "$(ssh-agent -s)" > /dev/null

# Detect passphrase-protected key before attempting to add
if ! echo "$SSH_KEY" | ssh-keygen -y -P "" -f /dev/stdin > /dev/null 2>&1; then
    echo "Error: SSH key is passphrase-protected. Passphrase-protected keys are not supported."
    exit 1
fi

echo "$SSH_KEY" | ssh-add -

# ── host key verification ────────────────────────────────────────────────────
# CI runners have no persistent known_hosts, so accept-new gives zero real
# protection: every run looks like a "first connection" and silently trusts
# whatever key is presented. If known_hosts is supplied, pin it and verify
# strictly; otherwise fall back to the old (unverified) behavior.

if [[ -n "$SSH_KNOWN_HOSTS" ]]; then
    KNOWN_HOSTS_FILE=$(mktemp)
    trap 'rm -f "$KNOWN_HOSTS_FILE"' EXIT
    echo "$SSH_KNOWN_HOSTS" > "$KNOWN_HOSTS_FILE"
    SSH_HOST_KEY_OPTS=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS_FILE")
else
    echo "Warning: known_hosts not set, host identity is not verified (accept-new). See action input 'known_hosts'."
    SSH_HOST_KEY_OPTS=(-o StrictHostKeyChecking=accept-new)
fi

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

printf -v QUOTED_YAML '%q' "$RESOLVED_YAML"
printf -v QUOTED_TIMEOUT '%q' "$SSH_COMMAND_TIMEOUT"

output=$(ssh \
    "${SSH_HOST_KEY_OPTS[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
    -p "$SSH_PORT" \
    "$SSH_USER@$SSH_HOST" \
    "bash -s -- $QUOTED_YAML $QUOTED_TIMEOUT" <<< "$REMOTE_SCRIPT")

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
