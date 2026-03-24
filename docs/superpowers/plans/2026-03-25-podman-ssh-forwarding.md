# Podman Machine SSH Agent Forwarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `devc ssh` work on macOS when the Docker engine is Podman Machine, by detecting the engine type and using SSH remote forwarding to tunnel the host agent socket into the VM.

**Architecture:** `detect_ssh_socket()` gains a Podman Machine branch that: (1) detects the engine via `podman machine inspect`, (2) establishes a background SSH tunnel (`-R`) from host agent to a stable VM-side socket path, (3) returns that VM-side path as `SSH_SOCKET_SOURCE` so the rest of `cmd_ssh` works unchanged. A companion `devc ssh-stop` teardown removes the tunnel and PID file.

**Tech Stack:** Bash, `podman machine inspect`, SSH remote forwarding (`-R`).

---

## File Structure

All changes are in a single file:

- **Modify:** `install.sh` (symlinked to `/Users/jasonhch/.local/bin/devc`)
  - New function: `detect_podman_machine()` — returns 0 if running Podman Machine, sets SSH config vars
  - New function: `start_ssh_tunnel()` — starts background SSH `-R` tunnel, writes PID file
  - New function: `stop_ssh_tunnel()` — kills tunnel by PID file, cleans up VM-side socket
  - Modified function: `detect_ssh_socket()` — add Podman Machine branch between Docker Desktop and generic fallback
  - Modified function: `verify_ssh_agent()` — add Podman-specific error guidance
  - Modified: `main()` dispatcher — add `ssh-stop` subcommand
  - Modified: `print_usage()` — add `ssh-stop` to help text
  - Modified: `cmd_completion()` — add `ssh-stop` to completions

## Important Context for Implementer

- The user's system has `docker` CLI from Homebrew pointing at Podman Machine. `detect_container_runtime()` sets `CONTAINER_RUNTIME="docker"` because `command -v docker` succeeds — so you **cannot** rely on `CONTAINER_RUNTIME == "podman"` to detect Podman Machine. Use `podman machine inspect` instead.
- virtiofs (Podman Machine's file sharing) **cannot** share Unix sockets. Direct bind-mounting of macOS sockets fails with "operation not supported". The SSH tunnel is the proven community workaround ([containers/podman#23785](https://github.com/containers/podman/issues/23785)).
- Existing constants near `cmd_ssh`: `SSH_CONTAINER_TARGET="/tmp/ssh-agent.sock"`, `DOCKER_DESKTOP_SSH_SOCK="/run/host-services/ssh-auth.sock"`.
- The tunnel PID file goes in `$HOME/.local/state/devc/` to survive across shell sessions.
- **Tunnel lifecycle:** The SSH tunnel intentionally survives `devc down` and is reused across up/down cycles. Only `devc ssh-stop` or `devc destroy` should tear it down. This avoids re-establishing the tunnel on every `devc up`.
- **Line references:** All line numbers refer to the file state *before* this plan's modifications. Use contextual landmarks (function names, comments) to locate insertion points after earlier tasks shift lines.
- **Multi-machine limitation:** `podman machine inspect` without arguments inspects the default machine. This plan does not support multiple Podman machines.

---

### Task 1: Add `detect_podman_machine()` helper

**Files:**
- Modify: `install.sh` — add after existing `DOCKER_DESKTOP_SSH_SOCK` constant (near `cmd_ssh`)

- [ ] **Step 1: Add constants and helper function**

Add immediately after the `DOCKER_DESKTOP_SSH_SOCK=` line:

```bash
PODMAN_VM_SSH_SOCK="/tmp/devc-ssh-agent.sock"
DEVC_STATE_DIR="${HOME}/.local/state/devc"
SSH_TUNNEL_PIDFILE="${DEVC_STATE_DIR}/ssh-tunnel.pid"

# Detect if we're running on a Podman Machine.
# Sets PODMAN_SSH_PORT, PODMAN_SSH_KEY, PODMAN_SSH_USER on success.
# Returns 1 if not Podman Machine or not running.
detect_podman_machine() {
  command -v podman &>/dev/null || return 1
  local inspect
  inspect=$(podman machine inspect 2>/dev/null) || return 1

  local state
  state=$(echo "$inspect" | jq -r '.[0].State' 2>/dev/null)
  [[ "$state" == "running" ]] || return 1

  PODMAN_SSH_PORT=$(echo "$inspect" | jq -r '.[0].SSHConfig.Port')
  PODMAN_SSH_KEY=$(echo "$inspect" | jq -r '.[0].SSHConfig.IdentityPath')
  PODMAN_SSH_USER=$(echo "$inspect" | jq -r '.[0].SSHConfig.RemoteUsername')
  return 0
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n install.sh`
Expected: no output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat(ssh): add detect_podman_machine() helper"
```

---

### Task 2: Add `start_ssh_tunnel()` and `stop_ssh_tunnel()`

**Files:**
- Modify: `install.sh` (add after `detect_podman_machine()`)

- [ ] **Step 1: Add tunnel management functions**

```bash
# Start an SSH tunnel forwarding host SSH agent into the Podman VM.
# Creates a stable socket at PODMAN_VM_SSH_SOCK inside the VM.
# Requires: PODMAN_SSH_PORT, PODMAN_SSH_KEY, PODMAN_SSH_USER set by detect_podman_machine()
start_ssh_tunnel() {
  mkdir -p "$DEVC_STATE_DIR"

  # Reuse existing tunnel if still alive
  if [[ -f "$SSH_TUNNEL_PIDFILE" ]]; then
    local old_pid
    old_pid=$(cat "$SSH_TUNNEL_PIDFILE")
    if kill -0 "$old_pid" 2>/dev/null; then
      log_info "SSH tunnel already running (PID $old_pid)"
      return 0
    fi
    rm -f "$SSH_TUNNEL_PIDFILE"
  fi

  # Clean up any stale socket inside the VM so SSH -R can bind
  podman machine ssh -- rm -f "$PODMAN_VM_SSH_SOCK" 2>/dev/null || true

  log_info "Starting SSH agent tunnel into Podman VM..."

  # Background with & to capture PID directly (ssh -f makes PID capture unreliable)
  # Host key checking disabled: Podman VM regenerates keys on recreation
  ssh -N \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ExitOnForwardFailure=yes \
    -i "$PODMAN_SSH_KEY" \
    -p "$PODMAN_SSH_PORT" \
    -R "$PODMAN_VM_SSH_SOCK:${SSH_AUTH_SOCK}" \
    "${PODMAN_SSH_USER}@localhost" &
  local tunnel_pid=$!

  # Brief wait for SSH to establish the forwarding
  sleep 1

  # Verify the tunnel process is still alive (authentication/forwarding failure exits immediately)
  if ! kill -0 "$tunnel_pid" 2>/dev/null; then
    log_error "SSH tunnel failed to start. Check that Podman Machine is running."
    return 1
  fi

  # Verify the socket was created inside the VM
  if ! podman machine ssh -- test -S "$PODMAN_VM_SSH_SOCK" 2>/dev/null; then
    kill "$tunnel_pid" 2>/dev/null || true
    log_error "SSH tunnel started but socket not created in VM."
    log_info "The VM's sshd may not support StreamLocalBindUnlink. Try: devc ssh again."
    return 1
  fi

  echo "$tunnel_pid" > "$SSH_TUNNEL_PIDFILE"

  # Relax socket permissions so containers (which may run as different UIDs) can access it
  podman machine ssh -- chmod 660 "$PODMAN_VM_SSH_SOCK" 2>/dev/null || true

  log_success "SSH tunnel started (PID $tunnel_pid)"
}

# Stop the SSH agent tunnel.
stop_ssh_tunnel() {
  if [[ ! -f "$SSH_TUNNEL_PIDFILE" ]]; then
    log_info "No SSH tunnel PID file found"
    return 0
  fi

  local pid
  pid=$(cat "$SSH_TUNNEL_PIDFILE")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    log_success "SSH tunnel stopped (PID $pid)"
  else
    log_info "SSH tunnel was not running (stale PID $pid)"
  fi

  rm -f "$SSH_TUNNEL_PIDFILE"

  # Clean up VM-side socket
  if command -v podman &>/dev/null; then
    podman machine ssh -- rm -f "$PODMAN_VM_SSH_SOCK" 2>/dev/null || true
  fi
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n install.sh`
Expected: no output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat(ssh): add start_ssh_tunnel() and stop_ssh_tunnel() for Podman VM"
```

---

### Task 3: Modify `detect_ssh_socket()` to handle Podman Machine

**Files:**
- Modify: `install.sh` — `detect_ssh_socket()` function

- [ ] **Step 1: Add Podman Machine branch**

Insert after the Docker Desktop `fi` block and before the `# All other platforms: use host SSH_AUTH_SOCK` comment:

```bash
  # macOS + Podman Machine: tunnel agent into VM via SSH -R
  if [[ "$os" == "Darwin" ]] && detect_podman_machine; then
    # Host SSH_AUTH_SOCK must be valid for the tunnel source
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
      log_error "No SSH agent detected."
      log_info "Start one with: eval \$(ssh-agent -s) && ssh-add"
      return 1
    fi
    if [[ ! -S "$SSH_AUTH_SOCK" ]]; then
      log_error "SSH_AUTH_SOCK points to '$SSH_AUTH_SOCK' but the socket doesn't exist."
      return 1
    fi

    # Start the tunnel (idempotent — skips if already running)
    if ! start_ssh_tunnel; then
      return 1
    fi

    SSH_SOCKET_SOURCE="$PODMAN_VM_SSH_SOCK"
    return 0
  fi
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n install.sh`
Expected: no output

- [ ] **Step 3: Smoke test — run `devc ssh` in ~/sandbox**

Run: `cd ~/sandbox && devc ssh`

Expected output should show:
- "Starting SSH agent tunnel into Podman VM..."
- "SSH tunnel started (PID ...)"
- "Adding SSH agent socket mount: /tmp/devc-ssh-agent.sock -> /tmp/ssh-agent.sock"
- Container rebuild
- "SSH agent forwarding is working"

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "feat(ssh): detect Podman Machine and tunnel agent via SSH -R"
```

---

### Task 4: Add `ssh-stop` subcommand, update help/completions, wire into `cmd_destroy`

**Files:**
- Modify: `install.sh` — `print_usage()`, `cmd_completion()`, `main()` dispatcher, `cmd_destroy()`

- [ ] **Step 1: Add cmd_ssh_stop function**

Add after `cmd_ssh()`:

```bash
cmd_ssh_stop() {
  stop_ssh_tunnel
}
```

- [ ] **Step 2: Update help text**

In `print_usage()`, after the `ssh` line, add:

```
    ssh-stop            Stop the SSH agent tunnel (Podman Machine only)
```

And in the Examples section, after the `devc ssh` example:

```
    devc ssh-stop               # Stop SSH agent tunnel
```

- [ ] **Step 3: Add to dispatcher**

In `main()`, after the `ssh)` case, add:

```bash
  ssh-stop)
    cmd_ssh_stop
    ;;
```

- [ ] **Step 4: Add to completions**

In the zsh completion `commands` array, after the `ssh` entry:

```
    'ssh-stop:Stop SSH agent tunnel'
```

In the bash completion `commands` string, add `ssh-stop` after `ssh`:

```
... ssh ssh-stop sync cp destroy ...
```

- [ ] **Step 5: Wire tunnel cleanup into `cmd_destroy()`**

In `cmd_destroy()`, after the "Removing image" block and before the final `log_success` line, add:

```bash
  # Clean up SSH tunnel if running (Podman Machine only)
  stop_ssh_tunnel 2>/dev/null
```

- [ ] **Step 6: Verify syntax**

Run: `bash -n install.sh`
Expected: no output

- [ ] **Step 7: Test ssh-stop**

Run: `devc ssh-stop`
Expected: "SSH tunnel stopped (PID ...)" or "No SSH tunnel PID file found"

- [ ] **Step 8: Commit**

```bash
git add install.sh
git commit -m "feat(ssh): add devc ssh-stop, wire tunnel cleanup into destroy"
```

---

### Task 5: Update `verify_ssh_agent()` with Podman-specific guidance

**Files:**
- Modify: `install.sh` — `verify_ssh_agent()` function

- [ ] **Step 1: Add Podman-specific error message**

In `verify_ssh_agent()`, find the "Could not open a connection" error block. Replace the existing if/else with:

```bash
  if echo "$ssh_output" | grep -q "Could not open a connection"; then
    if [[ "$SSH_SOCKET_SOURCE" == "$DOCKER_DESKTOP_SSH_SOCK" ]]; then
      log_error "Connection refused. In Docker Desktop, check that SSH agent forwarding is enabled."
    elif [[ "$SSH_SOCKET_SOURCE" == "$PODMAN_VM_SSH_SOCK" ]]; then
      log_error "SSH tunnel may have stopped. Run 'devc ssh' to restart it."
    else
      log_error "Host SSH agent may have stopped. Check 'ssh-add -l' on the host."
    fi
    return 1
  fi
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n install.sh`
Expected: no output

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "fix(ssh): add Podman-specific error guidance in verify_ssh_agent"
```

---

### Task 6: End-to-end verification

- [ ] **Step 1: Clean slate — remove existing SSH config from devcontainer.json**

Remove the SSH mount and `SSH_AUTH_SOCK` env from `~/sandbox/.devcontainer/devcontainer.json` if present, then stop any running tunnel:

```bash
devc ssh-stop
```

Edit devcontainer.json to remove the SSH mount line and `SSH_AUTH_SOCK` entry.

- [ ] **Step 2: Run `devc ssh` from scratch**

Run: `cd ~/sandbox && devc ssh`

Expected:
1. Podman Machine detected
2. SSH tunnel started
3. Mount added with `/tmp/devc-ssh-agent.sock` source
4. Container rebuilt
5. SSH agent verification passes — keys listed

- [ ] **Step 3: Verify `devc up` works with SSH mount in place**

Run: `cd ~/sandbox && devc down && devc up`

Expected: Container starts successfully (no "operation not supported" error)

- [ ] **Step 4: Verify `devc ssh` is idempotent**

Run: `cd ~/sandbox && devc ssh`

Expected: "SSH tunnel already running", "SSH agent socket mount already configured", verification passes

- [ ] **Step 5: Verify `devc ssh-stop` cleans up**

Run: `devc ssh-stop`

Expected: "SSH tunnel stopped (PID ...)"

Verify: `cat ~/.local/state/devc/ssh-tunnel.pid` should fail (file removed)

- [ ] **Step 6: Commit any final adjustments**

```bash
git add install.sh
git commit -m "fix(ssh): final adjustments from e2e verification"
```
