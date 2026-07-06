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
```

Outputs `status: restarted` or `status: started` for use in downstream steps.

## How it is tested

Shell scripts are linted with ShellCheck on every push and pull request. A pre-commit hook via lefthook runs the same check locally before any commit reaches CI.

## How it is managed

`make help` lists all available commands. Use `make lint` to run ShellCheck locally, `make build` to build the Docker image, and `make release TAG=v0.1.0` to tag and push a release. CI publishes the image to GHCR on every version tag.

## License

MIT
