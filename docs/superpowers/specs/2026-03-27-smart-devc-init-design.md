# Smart `devc init` Design

## Problem

After `devc init`, users must separately run `devc ssh` and `devc peon-ping`, each triggering a full container rebuild (`--remove-existing-container`). This means 3 builds for a fresh setup.

## Solution

Make `devc init` detect available features and configure them **before** the first `cmd_up`, so only one container build is needed.

## Two Modes

### Interactive Mode (default)

Detects each feature, shows result, and asks user whether to enable it.

- Detected features default to **Y**
- Undetected features default to **N** (but user can still enable — config is written, just won't work until the service is available)

```
$ devc init

✔ Template installed

Configuring features...

SSH agent forwarding
  ✔ Detected: /run/user/1000/ssh-agent.sock
  Enable? [Y/n] y

Peon-ping relay
  ✗ Not detected (relay not running on localhost:19998)
  Enable anyway? [y/N] n

Building container...
✔ Done
```

### Quick Mode (`--quick`)

Auto-enables detected features, skips undetected ones. No prompts.

```
$ devc init --quick

✔ Template installed
✔ SSH forwarding — detected, enabled
⊘ Peon-ping — not detected, skipped
✔ Container started
```

## Detection Logic

| Feature | Detection | Config written on enable |
|---------|-----------|--------------------------|
| SSH forwarding | `detect_ssh_socket` succeeds | mount + `SSH_AUTH_SOCK` env + SELinux opt (if Podman) |
| Peon-ping relay | `curl -sf --max-time 2 http://$host:$port/health` returns OK | `--network=host` runArg + `PEON_RELAY_HOST/PORT` env |

## Post-build Verification

After `cmd_up`, run existing verify/configure functions for enabled features:

- SSH: `verify_ssh_agent` → `configure_git_signing` → `sync_known_hosts`
- Peon-ping: `verify_peon_relay`

Verification failures are warnings only — they do not fail the init.

## Implementation

### Changes to `cmd_init()`

```bash
cmd_init() {
  local quick=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quick) quick=true; shift ;;
      *) break ;;
    esac
  done

  # 1. Install template
  cmd_template "."

  local workspace_folder
  workspace_folder="$(cd "." && pwd)"
  local devcontainer_json="$workspace_folder/.devcontainer/devcontainer.json"

  detect_container_runtime

  # 2. Feature detection & configuration
  local ssh_enabled=false
  local peon_enabled=false

  # --- SSH ---
  local ssh_detected=false
  if detect_ssh_socket 2>/dev/null; then
    ssh_detected=true
  fi

  if [[ "$quick" == true ]]; then
    if [[ "$ssh_detected" == true ]]; then
      ssh_enabled=true
      log_info "SSH forwarding — detected, enabled"
    else
      log_info "SSH forwarding — not detected, skipped"
    fi
  else
    if [[ "$ssh_detected" == true ]]; then
      log_info "SSH agent forwarding"
      log_info "  ✔ Detected: $SSH_SOCKET_SOURCE"
      read -p "  Enable? [Y/n] " -n 1 -r; echo
      [[ ! $REPLY =~ ^[Nn]$ ]] && ssh_enabled=true
    else
      log_info "SSH agent forwarding"
      log_info "  ✗ Not detected"
      read -p "  Enable anyway? [y/N] " -n 1 -r; echo
      [[ $REPLY =~ ^[Yy]$ ]] && ssh_enabled=true
    fi
  fi

  # --- Peon-ping ---
  local relay_host="${PEON_RELAY_HOST:-$PEON_RELAY_HOST_DEFAULT}"
  local relay_port="${PEON_RELAY_PORT:-$PEON_RELAY_PORT_DEFAULT}"
  local peon_detected=false
  if curl -sf --max-time 2 "http://${relay_host}:${relay_port}/health" &>/dev/null; then
    peon_detected=true
  fi

  if [[ "$quick" == true ]]; then
    if [[ "$peon_detected" == true ]]; then
      peon_enabled=true
      log_info "Peon-ping — detected, enabled"
    else
      log_info "Peon-ping — not detected, skipped"
    fi
  else
    if [[ "$peon_detected" == true ]]; then
      log_info "Peon-ping relay"
      log_info "  ✔ Detected: http://${relay_host}:${relay_port}"
      read -p "  Enable? [Y/n] " -n 1 -r; echo
      [[ ! $REPLY =~ ^[Nn]$ ]] && peon_enabled=true
    else
      log_info "Peon-ping relay"
      log_info "  ✗ Not detected (relay not running on ${relay_host}:${relay_port})"
      read -p "  Enable anyway? [y/N] " -n 1 -r; echo
      [[ $REPLY =~ ^[Yy]$ ]] && peon_enabled=true
    fi
  fi

  # 3. Apply config before building
  if [[ "$ssh_enabled" == true ]]; then
    # Re-detect if needed (for socket source)
    if [[ "$ssh_detected" != true ]]; then
      detect_ssh_socket 2>/dev/null || true
    fi
    if [[ -n "${SSH_SOCKET_SOURCE:-}" ]]; then
      update_devcontainer_mounts "$devcontainer_json" "$SSH_SOCKET_SOURCE" "$SSH_CONTAINER_TARGET" "false"
      update_devcontainer_env "$devcontainer_json" "SSH_AUTH_SOCK" "$SSH_CONTAINER_TARGET"
      if [[ "$SSH_SOCKET_SOURCE" == "$PODMAN_VM_SSH_SOCK" ]]; then
        local updated
        updated=$(jq '.runArgs = ((.runArgs // []) | if any(. == "--security-opt") then . else . + ["--security-opt", "label=disable"] end)' "$devcontainer_json")
        echo "$updated" > "$devcontainer_json"
      fi
    fi
  fi

  if [[ "$peon_enabled" == true ]]; then
    local has_network_host
    has_network_host=$(jq -r '(.runArgs // []) | map(select(. == "--network=host")) | length' "$devcontainer_json")
    if [[ "$has_network_host" -eq 0 ]]; then
      local updated
      updated=$(jq '.runArgs = (.runArgs // []) + ["--network=host"]' "$devcontainer_json")
      echo "$updated" > "$devcontainer_json"
    fi
    update_devcontainer_env "$devcontainer_json" "PEON_RELAY_HOST" "$relay_host"
    update_devcontainer_env "$devcontainer_json" "PEON_RELAY_PORT" "$relay_port"
  fi

  # 4. Build container (once)
  cmd_up "."

  # 5. Post-build verification
  if [[ "$ssh_enabled" == true ]]; then
    verify_ssh_agent "$workspace_folder" 2>/dev/null && configure_git_signing "$workspace_folder" 2>/dev/null
    sync_known_hosts "$workspace_folder" 2>/dev/null
  fi
  if [[ "$peon_enabled" == true ]]; then
    verify_peon_relay "$workspace_folder" "$relay_host" "$relay_port" 2>/dev/null
  fi
}
```

### Changes to `main()`

Update the `init)` case to pass arguments:

```bash
init)
  cmd_init "$@"
  ;;
```

Remove the old argument check that blocked arguments to `devc init`.

### Backward Compatibility

- `devc ssh` and `devc peon-ping` remain unchanged — they still work standalone
- If features were already configured by `devc init`, running them again is a no-op (existing `needs_changes` guard)
