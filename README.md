# eos Deploy Action

A GitHub/Gitea Action that SSHes into a remote host and runs `eos api run` to start or restart a service. eos must be pre-installed on the remote.

## What it does

Connects to your server over SSH and tells eos to run the service defined by a `service.yaml`. Reports back whether the service was started fresh or restarted as a step output.

```yaml
- uses: elysium-labs/eos-deploy-action@v0
  with:
    host: ${{ secrets.REMOTE_HOST }}
    username: ${{ secrets.REMOTE_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    service_yaml: /opt/myapp/service.yaml
    known_hosts: ${{ vars.SSH_KNOWN_HOSTS }}
```

Outputs `status: restarted` or `status: started` for use in downstream steps. The `key` must be an unencrypted private key. Passphrase-protected keys are not supported.

## Pin the host key

Set `known_hosts` to verify the server's identity. Without it, the action trusts whatever host key it sees on every run and logs a warning. CI runners have no saved host keys, so a man-in-the-middle could capture your deploy key.

Read the key on the server, over a connection you already trust (your provider's console, or an SSH session whose key you verified). Do not use `ssh-keyscan` from CI. That only repeats the trust-on-first-use problem.

```bash
cat /etc/ssh/ssh_host_ed25519_key.pub
```

Prefix it with the host. Use `[host]:port` if the port is not 22:

```
example.com ssh-ed25519 AAAA...
[example.com]:2222 ssh-ed25519 AAAA...
```

Store the line as a repository variable. It is public data, so it needs no secret. If the key does not match, the deploy fails with `Host key verification failed`. Rotate the variable when you rotate the server's host keys.

## How it is tested

Shell scripts are linted with ShellCheck on every push and pull request. A pre-commit hook via lefthook runs the same check locally before any commit reaches CI. `make test-ssh` runs the action against a throwaway sshd in Docker and checks host key pinning, the unverified fallback, and remote command quoting.

## How it is managed

`make help` lists all available commands. Use `make lint` to run ShellCheck locally, `make build` to build the Docker image, and `make release TAG=v0.1.0` to tag and push a release. CI publishes the image to GHCR on every version tag.

## License

MIT
