#!/bin/bash
# End-to-end test of deploy.sh against a throwaway sshd in Docker.
# Covers host key pinning, the unverified fallback, and remote command quoting.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE="eos-deploy-action-test-sshd:dev"
CONTAINER="eos-deploy-action-test-$$"
WORK=$(mktemp -d)
failures=0

cleanup() {
    docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# ── test server: sshd, login shell /bin/sh (not bash), stub eos ──────────────

docker build -q -t "$IMAGE" - > /dev/null <<'EOF'
FROM alpine:3.21
RUN apk add --no-cache openssh-server bash \
 && adduser -D -s /bin/sh deploy \
 && echo "deploy:$(head -c 24 /dev/urandom | base64)" | chpasswd \
 && mkdir -p /home/deploy/.ssh \
 && chmod 700 /home/deploy/.ssh \
 && chown deploy:deploy /home/deploy/.ssh \
 && echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
EOF

ssh-keygen -q -t ed25519 -N "" -f "$WORK/deploy_key"
ssh-keygen -q -t ed25519 -N "" -f "$WORK/wrong_host_key"

# The stub drains stdin like a misbehaving eos; deploy.sh must keep it away
# from the script bash is reading over the same channel.
cat > "$WORK/eos" <<'EOF'
#!/bin/sh
cat > /dev/null
printf '%s' "$4" > /tmp/eos-arg
echo '{"restarted":true}'
EOF
chmod 755 "$WORK/eos"

docker run -d --name "$CONTAINER" -p 127.0.0.1::22 "$IMAGE" \
    sh -c 'ssh-keygen -A && exec /usr/sbin/sshd -D -e' > /dev/null
docker cp "$WORK/deploy_key.pub" "$CONTAINER:/home/deploy/.ssh/authorized_keys"
docker exec "$CONTAINER" chown deploy:deploy /home/deploy/.ssh/authorized_keys
docker cp "$WORK/eos" "$CONTAINER:/usr/local/bin/eos"

PORT=$(docker port "$CONTAINER" 22/tcp | head -n1 | sed 's/.*://')

# Readiness only; the keys it returns are never trusted.
for _ in $(seq 1 30); do
    ssh-keyscan -p "$PORT" 127.0.0.1 > /dev/null 2>&1 && break
    sleep 0.5
done

# Pin the host key read from the server's filesystem, not from the network.
HOST_PUB=$(docker exec "$CONTAINER" cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)
GOOD_KNOWN_HOSTS="[127.0.0.1]:$PORT $HOST_PUB"
WRONG_KNOWN_HOSTS="[127.0.0.1]:$PORT $(cut -d' ' -f1,2 "$WORK/wrong_host_key.pub")"

run_deploy() {
    env -u SSH_KNOWN_HOSTS -u GITHUB_OUTPUT \
        SSH_HOST=127.0.0.1 \
        SSH_USER=deploy \
        SSH_KEY="$(cat "$WORK/deploy_key")" \
        SSH_PORT="$PORT" \
        SERVICE_YAML=service.yaml \
        "$@" \
        bash "$ROOT/scripts/deploy.sh"
}

# ── cases ────────────────────────────────────────────────────────────────────

rc=0; out=$(run_deploy SSH_KNOWN_HOSTS="$GOOD_KNOWN_HOSTS" 2>&1) || rc=$?
if [[ $rc -eq 0 && "$out" == *"Service restarted successfully"* ]]; then
    pass "pinned host key matches: deploy succeeds"
else
    fail "pinned host key matches: rc=$rc out=$out"
fi

rc=0; out=$(run_deploy SSH_KNOWN_HOSTS="$WRONG_KNOWN_HOSTS" 2>&1) || rc=$?
if [[ $rc -ne 0 && "$out" == *"Host key verification failed"* ]]; then
    pass "pinned host key mismatches: deploy refused"
else
    fail "pinned host key mismatches: rc=$rc out=$out"
fi

# accept-new would write to the real ~/.ssh/known_hosts; redirect it.
mkdir "$WORK/shim"
cat > "$WORK/shim/ssh" <<'EOF'
#!/bin/sh
exec "$REAL_SSH" -o UserKnownHostsFile="$SHIM_KNOWN_HOSTS" "$@"
EOF
chmod 755 "$WORK/shim/ssh"
rc=0
out=$(REAL_SSH=$(command -v ssh) SHIM_KNOWN_HOSTS="$WORK/known_hosts" \
    PATH="$WORK/shim:$PATH" run_deploy 2>&1) || rc=$?
if [[ $rc -eq 0 && "$out" == *"::warning"* ]]; then
    pass "known_hosts unset: warns and falls back to accept-new"
else
    fail "known_hosts unset: rc=$rc out=$out"
fi

HOSTILE="/tmp/it's \$(touch /tmp/pwned) \`id\`; y.yaml"
rc=0; out=$(run_deploy SSH_KNOWN_HOSTS="$GOOD_KNOWN_HOSTS" SERVICE_YAML="$HOSTILE" 2>&1) || rc=$?
received=$(docker exec "$CONTAINER" cat /tmp/eos-arg 2>/dev/null || true)
if [[ $rc -eq 0 && "$received" == "$HOSTILE" ]] \
    && ! docker exec "$CONTAINER" test -e /tmp/pwned; then
    pass "hostile service_yaml reaches eos verbatim, nothing executed"
else
    fail "hostile service_yaml: rc=$rc received=[$received] out=$out"
fi

rc=0; out=$(run_deploy SSH_KNOWN_HOSTS="$GOOD_KNOWN_HOSTS" SSH_COMMAND_TIMEOUT='1;id' 2>&1) || rc=$?
if [[ $rc -ne 0 && "$out" == *"must be a whole number"* ]]; then
    pass "non-numeric timeout rejected before connecting"
else
    fail "non-numeric timeout: rc=$rc out=$out"
fi

rc=0; out=$(run_deploy SSH_KNOWN_HOSTS="$GOOD_KNOWN_HOSTS"$'\r' 2>&1) || rc=$?
if [[ $rc -eq 0 && "$out" == *"Service restarted successfully"* ]]; then
    pass "CRLF in pasted known_hosts is tolerated"
else
    fail "CRLF known_hosts: rc=$rc out=$out"
fi

rc=0; out=$(run_deploy SSH_KNOWN_HOSTS="$GOOD_KNOWN_HOSTS" SSH_PORT='22 -oProxyCommand=id' 2>&1) || rc=$?
if [[ $rc -ne 0 && "$out" == *"SSH_PORT must be a whole number"* ]]; then
    pass "non-numeric port rejected before connecting"
else
    fail "non-numeric port: rc=$rc out=$out"
fi

rc=0; out=$(run_deploy SSH_KNOWN_HOSTS="$GOOD_KNOWN_HOSTS" SSH_COMMAND_TIMEOUT=0 2>&1) || rc=$?
if [[ $rc -ne 0 && "$out" == *"must be at least 1 second"* ]]; then
    pass "zero timeout rejected (0 would disable the limit)"
else
    fail "zero timeout: rc=$rc out=$out"
fi

: > "$WORK/github_output"
rc=0; out=$(run_deploy SSH_KNOWN_HOSTS="$GOOD_KNOWN_HOSTS" GITHUB_OUTPUT="$WORK/github_output" 2>&1) || rc=$?
if [[ $rc -eq 0 && "$(cat "$WORK/github_output")" == "status=restarted" ]]; then
    pass "GITHUB_OUTPUT gets exactly one validated status line"
else
    fail "GITHUB_OUTPUT: rc=$rc file=[$(cat "$WORK/github_output")]"
fi

rc=0; out=$(run_deploy SSH_KNOWN_HOSTS="$GOOD_KNOWN_HOSTS" SSH_PORT=99999 2>&1) || rc=$?
if [[ $rc -ne 0 && "$out" == *"SSH_PORT must be between 1 and 65535"* ]]; then
    pass "out-of-range port rejected before connecting"
else
    fail "out-of-range port: rc=$rc out=$out"
fi

ssh-keygen -q -t ed25519 -N "secret" -f "$WORK/protected_key"
rc=0
out=$(run_deploy SSH_KNOWN_HOSTS="$GOOD_KNOWN_HOSTS" SSH_KEY="$(cat "$WORK/protected_key")" \
    2>&1 < /dev/null) || rc=$?
if [[ $rc -ne 0 && "$out" == *"passphrase-protected keys are not supported"* ]]; then
    pass "passphrase-protected key fails fast without prompting"
else
    fail "passphrase-protected key: rc=$rc out=$out"
fi

# Remote failures must surface their message, not just a bare exit code.
docker exec "$CONTAINER" mv /usr/local/bin/eos /usr/local/bin/eos.real
rc=0; out=$(run_deploy SSH_KNOWN_HOSTS="$GOOD_KNOWN_HOSTS" 2>&1) || rc=$?
if [[ $rc -ne 0 && "$out" == *"eos not found on remote host"* ]]; then
    pass "missing eos on remote: message is shown"
else
    fail "missing eos: rc=$rc out=$out"
fi

printf '%s\n' '#!/bin/sh' 'echo "boom: bad service file" >&2' 'echo "::error::forged" >&2' 'exit 3' > "$WORK/eos-fail"
chmod 755 "$WORK/eos-fail"
docker cp "$WORK/eos-fail" "$CONTAINER:/usr/local/bin/eos"
rc=0; out=$(run_deploy SSH_KNOWN_HOSTS="$GOOD_KNOWN_HOSTS" 2>&1) || rc=$?
if [[ $rc -ne 0 && "$out" == *"eos api run failed (exit 3)"* && "$out" == *"boom: bad service file"* ]] \
    && ! grep -q '^::' <<< "$out"; then
    pass "failing eos: exit code and stderr are shown, no line starts with '::'"
else
    fail "failing eos: rc=$rc out=$out"
fi

echo
if [[ $failures -ne 0 ]]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "All tests passed"
