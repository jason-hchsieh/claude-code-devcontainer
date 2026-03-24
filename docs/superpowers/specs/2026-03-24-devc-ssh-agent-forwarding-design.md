# Design: `devc ssh` — SSH Agent Forwarding

**Date:** 2026-03-24
**Status:** Draft

## Summary

Add a `devc ssh` subcommand that configures SSH agent forwarding into the devcontainer. Instead of mounting SSH key files, the container connects to the host's `ssh-agent` via a forwarded Unix socket. Private keys never enter the container.

## Approach

Socket mount + `containerEnv` in `devcontainer.json` (Approach A). This follows existing devcontainer conventions and integrates with the existing mount preservation system (`extract_mounts_to_file`/`merge_mounts_from_file`).

Rejected alternatives:
- **runArgs `--mount`** — fights the devcontainer abstraction, breaks mount preservation
- **Runtime-only socat proxy** — fragile, requires extra tooling, doesn't persist

## Platform Detection

`devc ssh` detects the host platform and container runtime to determine the correct socket source path.

| Platform | Source socket path |
|---|---|
| macOS + Docker Desktop | `/run/host-services/ssh-auth.sock` (Docker Desktop built-in; independent of host `SSH_AUTH_SOCK`) |
| macOS + Colima | `$SSH_AUTH_SOCK` (Lima forwards host agent into VM) |
| Linux + Docker | `$SSH_AUTH_SOCK` (direct bind mount) |
| Linux + Podman | `$SSH_AUTH_SOCK` (direct bind mount, rootless) |

**Container-side target:** `/tmp/ssh-agent.sock` (consistent across all platforms).

**Detection logic:**
1. If macOS and Docker Desktop is the container runtime, use the Docker Desktop socket.
2. Otherwise, read `$SSH_AUTH_SOCK` from the host environment. Fail with platform-specific guidance if unset or missing.

### macOS + Docker Desktop detection

Docker Desktop is identified when the platform is macOS (`uname -s` = `Darwin`) and the container runtime is `docker` (not overridden to podman). Colima users set `CONTAINER_RUNTIME=podman` or the detected runtime resolves to podman, distinguishing them from Docker Desktop users.

Edge case: macOS users running Docker via Colima with the `docker` CLI (Colima can expose a Docker-compatible socket). These users will have `CONTAINER_RUNTIME` unset and `docker` on PATH. The Docker Desktop socket `/run/host-services/ssh-auth.sock` won't exist in their containers. This is caught at the verification step, which will diagnose the issue and suggest using `$SSH_AUTH_SOCK` instead. A future enhancement could detect Colima explicitly.

## Host Diagnostics

Before configuring, `devc ssh` validates the host SSH agent is reachable.

**macOS + Docker Desktop:**
- Skip `SSH_AUTH_SOCK` check — Docker Desktop provides its own socket.

**All other platforms:**
- Check `$SSH_AUTH_SOCK` is set. If not: error with guidance ("No SSH agent detected. Start one with: `eval $(ssh-agent -s)` then `ssh-add`").
- Check the socket file exists at that path. If not: error ("SSH_AUTH_SOCK points to `<path>` but the file doesn't exist. Your agent may have died. Restart with: `eval $(ssh-agent -s)`").
- Run `ssh-add -l` to check for loaded keys. If none: warning (not error) ("SSH agent is running but has no keys loaded. Run `ssh-add` to add your keys."). Setup proceeds.

Hard errors (no agent) block setup. Warnings (no keys) do not.

## State Detection & Idempotency

Before making changes, `devc ssh` inspects `devcontainer.json`:

1. Scan `.mounts[]` for any entry targeting `/tmp/ssh-agent.sock`.
2. Check `.containerEnv.SSH_AUTH_SOCK` for value `/tmp/ssh-agent.sock`.

| Mount exists | Env var exists | Action |
|---|---|---|
| No | No | Full setup: add mount + env var, recreate container |
| Yes | No | Add env var only, recreate container |
| No | Yes | Add mount only, recreate container |
| Yes | Yes | Skip config, jump to verification |

If the mount source path or env var value doesn't match what platform detection expects (e.g., user switched from Docker Desktop to Colima), report the mismatch and update.

## Configuration Changes

When changes are needed, `devc ssh` modifies `devcontainer.json`:

**Mount:** Added via existing `update_devcontainer_mounts()`:
```
source=<platform-specific-socket>,target=/tmp/ssh-agent.sock,type=bind
```

**Environment variable:** Added via new `update_devcontainer_env()` helper:
```json
"containerEnv": {
  "SSH_AUTH_SOCK": "/tmp/ssh-agent.sock"
}
```

After configuration, the container is recreated with `devcontainer up --remove-existing-container` (same pattern as `cmd_mount()`).

## Container-Side Verification

After configuration (or immediately if already configured), `devc ssh` verifies forwarding works inside the container via `devcontainer exec`:

1. Check `/tmp/ssh-agent.sock` exists.
2. Run `SSH_AUTH_SOCK=/tmp/ssh-agent.sock ssh-add -l`.
3. Report results.

**Success output:**
```
[devc] SSH agent forwarding is working
[devc]   2 keys available:
[devc]     256 SHA256:abc... user@host (ED25519)
[devc]     256 SHA256:def... user@host (RSA)
```

**Failure diagnostics:**

| Symptom | Diagnosis |
|---|---|
| Socket missing in container | "Socket not mounted. Try `devc ssh` again or `devc rebuild`." |
| Socket exists, connection refused | macOS+Docker Desktop: "Enable 'Allow the default Docker socket to be used' in Docker Desktop settings." Others: "Host SSH agent may have stopped. Check `ssh-add -l` on the host." |
| Agent responds, no keys | Warning: "Agent is reachable but no keys loaded. Run `ssh-add` on the host." |

If the container is not running, skip verification with: "Container is not running. Changes will take effect on next `devc up`."

## Implementation Scope

All changes are in `install.sh`. No changes to `Dockerfile`, `devcontainer.json` template, or `post_install.py`.

**New code:**
- `cmd_ssh()` — main command function
- `update_devcontainer_env()` — helper to add/update a key in `.containerEnv` via `jq`

**Modified code:**
- Command dispatch `case` statement — add `ssh)`
- Help text — add `ssh` description
- Completion scripts (zsh + bash) — add `ssh` to command lists

## Testing

Manual validation (consistent with project's existing approach):
1. macOS + Docker Desktop: run `devc ssh`, verify `ssh-add -l` works in container
2. Run `devc ssh` twice — second run should detect existing config and skip to verify
3. Remove env var manually, run `devc ssh` — should detect partial state and fix
4. Stop host agent, run `devc ssh` — should show diagnostic guidance
5. Verify SSH mount survives `devc template` update (mount preservation system)
