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

# Inputs are never echoed back: a value with a newline could forge workflow commands.
for var in SSH_PORT SSH_CONNECT_TIMEOUT SSH_COMMAND_TIMEOUT; do
    if [[ ! "${!var}" =~ ^[0-9]{1,9}$ ]]; then
        echo "Error: $var must be a whole number."
        exit 1
    fi
done

for var in SSH_CONNECT_TIMEOUT SSH_COMMAND_TIMEOUT; do
    if (( 10#${!var} < 1 )); then
        echo "Error: $var must be at least 1 second (0 would disable the limit)."
        exit 1
    fi
done

if (( 10#$SSH_PORT < 1 || 10#$SSH_PORT > 65535 )); then
    echo "Error: SSH_PORT must be between 1 and 65535."
    exit 1
fi

# ── SSH key — load into agent, never touch disk ──────────────────────────────

KNOWN_HOSTS_FILE=""

cleanup() {
    [[ -n "$KNOWN_HOSTS_FILE" ]] && rm -f "$KNOWN_HOSTS_FILE"
    ssh-agent -k > /dev/null 2>&1 || true
}

eval "$(ssh-agent -s)" > /dev/null
# Installed only after our own agent exists, so cleanup never kills an inherited one.
trap cleanup EXIT

# A passphrase-protected key must fail here, not prompt: force askpass to /bin/false.
# (Probing with ssh-keygen -f /dev/stdin is rejected on macOS: /dev/stdin is mode 0660.)
if ! add_output=$(printf '%s\n' "$SSH_KEY" \
    | SSH_ASKPASS="$(command -v false)" SSH_ASKPASS_REQUIRE=force DISPLAY=none ssh-add - 2>&1); then
    echo "Error: SSH key could not be loaded. It is invalid or passphrase-protected; passphrase-protected keys are not supported."
    echo "$add_output"
    exit 1
fi

# ── host key verification ────────────────────────────────────────────────────
# CI runners have no persistent known_hosts, so accept-new gives zero real
# protection: every run looks like a "first connection" and silently trusts
# whatever key is presented. If known_hosts is supplied, pin it and verify
# strictly; otherwise fall back to the old (unverified) behavior.

if [[ -n "$SSH_KNOWN_HOSTS" ]]; then
    KNOWN_HOSTS_FILE=$(mktemp)
    printf '%s\n' "${SSH_KNOWN_HOSTS//$'\r'/}" > "$KNOWN_HOSTS_FILE"
    SSH_HOST_KEY_OPTS=(
        -o StrictHostKeyChecking=yes
        -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
        -o GlobalKnownHostsFile=/dev/null
    )
else
    echo "::warning title=SSH host key not verified::known_hosts is not set, so the host identity is trusted on first use (accept-new) with no MITM protection. Set the action input 'known_hosts'."
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
    echo "eos not found on remote host. Install: https://github.com/Elysium-Labs-EU/eos/releases"
    exit 1
fi

deploy_err=$(mktemp)
trap 'rm -f "$deploy_err"' EXIT

exit_code=0
# </dev/null: this script arrives on bash's stdin, so eos must not read it.
result=$(timeout "$COMMAND_TIMEOUT" eos api run -f "$SERVICE_YAML" 2>"$deploy_err" </dev/null) || exit_code=$?

if [[ $exit_code -eq 124 ]]; then
    echo "eos api run timed out after ${COMMAND_TIMEOUT}s"
    exit 1
fi

if [[ $exit_code -ne 0 ]]; then
    echo "eos api run failed (exit $exit_code):"
    cat "$deploy_err"
    exit 1
fi

if grep -q '"restarted":true' <<< "$result"; then
    echo "EOS_DEPLOY_STATUS=restarted"
else
    echo "EOS_DEPLOY_STATUS=started"
fi
REMOTE
)

# POSIX single-quote escaping, safe for sh-family login shells (unlike %q,
# which can emit $'...' that dash does not parse). csh/tcsh are not supported.
sh_quote() {
    local escaped_quote="'\\''"
    printf "'%s'" "${1//\'/$escaped_quote}"
}

QUOTED_YAML=$(sh_quote "$RESOLVED_YAML")
QUOTED_TIMEOUT=$(sh_quote "$SSH_COMMAND_TIMEOUT")

exit_code=0
output=$(ssh \
    "${SSH_HOST_KEY_OPTS[@]}" \
    -o BatchMode=yes \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
    -p "$SSH_PORT" \
    -- \
    "$SSH_USER@$SSH_HOST" \
    "bash -s -- $QUOTED_YAML $QUOTED_TIMEOUT" <<< "$REMOTE_SCRIPT") || exit_code=$?

if [[ $exit_code -ne 0 ]]; then
    # Indented so remote text can never start a line with "::" (a workflow command).
    # shellcheck disable=SC2001  # ${var//} cannot anchor to every line start
    sed 's/^/  /' <<< "$output"
    exit "$exit_code"
fi

# Remote output is untrusted: take the first status line, accept known values only.
status=$(grep -m1 '^EOS_DEPLOY_STATUS=' <<< "$output" | cut -d= -f2- || true)
case "$status" in
    restarted|started) ;;
    *) status=unknown ;;
esac

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "status=$status" >> "$GITHUB_OUTPUT"
fi

case "$status" in
    restarted) echo "Service restarted successfully" ;;
    started) echo "Service started fresh" ;;
    *) echo "Deploy finished, but the service status could not be determined" ;;
esac
