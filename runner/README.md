# veraxi-runner

Turn your own PC, Mac, homelab, or VPS into a Veraxi agentic-coding
sandbox — without opening any inbound ports. The runner connects
**outbound** over WebSocket to the Veraxi backend and executes the
agent's commands inside a single repository worktree on your machine.

## Install

```bash
pip install ./runner   # from the Veraxi repo checkout
```

## Connect

```bash
veraxi-runner connect --url wss://veraxi.me --token <TOKEN> \
    --repo /path/to/repo --runtime docker
```

- `--token`: the per-tenant runner token from Veraxi Settings →
  Code Sandboxes → Local Runner. It can also be supplied via the
  `VERAXI_RUNNER_TOKEN` environment variable. Your tenant id can be
  passed with `--tenant-id` or `VERAXI_TENANT_ID`.
- `--repo`: the only directory the agent can touch. Every file path
  is resolved under this root; traversal outside it is rejected.
- `--runtime`:
  - `docker` (default): each command runs in a hardened container —
    `--cap-drop=ALL`, `--security-opt=no-new-privileges`, a single
    worktree mount at `/repo`, and `--network none` with `--offline`.
  - `microsandbox`: commands are delegated to a local
    [Microsandbox](https://github.com/microsandbox/microsandbox)
    installation (the `microsandbox` binary must be on `PATH`).
  - `direct`: commands run directly on the host inside `--repo`
    (least isolation — only for machines you fully trust the agent on).

## Safety properties

- Commands run with a **scrubbed environment allowlist**
  (`PATH`, `HOME`, `LANG`, `LC_ALL`, `TERM`, `TMPDIR`) — your host
  environment, `~/.ssh`, and `~/.env` contents are never passed to
  agent commands.
- The connection is outbound-only: no listening ports, works behind
  NAT and firewalls.
- The backend authenticates the runner token against the tenant's
  encrypted sandbox config before accepting the socket.
