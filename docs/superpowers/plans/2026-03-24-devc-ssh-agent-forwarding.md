# `devc ssh` — SSH Agent Forwarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `devc ssh` command that configures SSH agent forwarding into the devcontainer with platform detection, idempotent state management, and diagnostic verification.

**Architecture:** New `cmd_ssh()` function in `install.sh` that detects the platform-specific SSH agent socket, adds a bind mount + `SSH_AUTH_SOCK` env var to `devcontainer.json`, recreates the container, and verifies the forwarding works. A new `update_devcontainer_env()` helper handles `containerEnv` modifications.

**Tech Stack:** Bash, jq, Docker/Podman CLI

**Spec:** `docs/superpowers/specs/2026-03-24-devc-ssh-agent-forwarding-design.md`

**Note:** This project has no automated tests. Validation is manual. Each task includes manual verification steps.

---

## File Structure

All changes are in a single file:

- **Modify:** `install.sh` — add `update_devcontainer_env()` helper, `detect_ssh_socket()`, `verify_ssh_agent()`, `cmd_ssh()`, wire into help/completions/dispatch

---

### Task 1: Add `update_devcontainer_env()` helper

**Files:**
- Modify: `install.sh:230` (insert after `update_devcontainer_mounts()`)

This helper merges a key-value pair into the existing `.containerEnv` object in `devcontainer.json`, preserving all other env vars.

- [ ] **Step 1: Add `update_devcontainer_env()` function**

Insert after line 230 (end of `update_devcontainer_mounts()`):

```bash
# Add or update an environment variable in devcontainer.json containerEnv
update_devcontainer_env() {
  local devcontainer_json="$1"
  local key="$2"
  local value="$3"

  local updated
  updated=$(jq --arg key "$key" --arg value "$value" '
    .containerEnv[$key] = $value
  ' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}
```

- [ ] **Step 2: Verify the helper works**

Run manually against a copy of `devcontainer.json`:

```bash
cp .devcontainer/devcontainer.json /tmp/test-dc.json
bash -c 'source install.sh 2>/dev/null; update_devcontainer_env /tmp/test-dc.json SSH_AUTH_SOCK /tmp/ssh-agent.sock'
jq '.containerEnv' /tmp/test-dc.json
```

Expected: `SSH_AUTH_SOCK` appears in `containerEnv` alongside all existing env vars (NODE_OPTIONS, CLAUDE_CONFIG_DIR, etc.).

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat(ssh): add update_devcontainer_env() helper"
```

---

### Task 2: Add platform detection helper

**Files:**
- Modify: `install.sh` (insert after `update_devcontainer_env()`, before `cmd_template()`)

- [ ] **Step 1: Add `detect_ssh_socket()` function**

This function sets the `SSH_SOCKET_SOURCE` variable based on platform and runtime. Insert after `update_devcontainer_env()`:

```bash
# Detect the platform-specific SSH agent socket path.
# Sets SSH_SOCKET_SOURCE on success.
# Returns 1 with diagnostic guidance on failure.
detect_ssh_socket() {
  SSH_SOCKET_SOURCE=""
  local os
  os="$(uname -s)"

  # macOS + Docker Desktop: uses a built-in socket
  if [[ "$os" == "Darwin" && "$CONTAINER_RUNTIME" == "docker" ]]; then
    local docker_host
    docker_host=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
    if [[ "$docker_host" != *".colima"* ]]; then
      SSH_SOCKET_SOURCE="/run/host-services/ssh-auth.sock"
      return 0
    fi
  fi

  # All other platforms: use host SSH_AUTH_SOCK
  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    log_error "No SSH agent detected."
    log_info "Start one with: eval \$(ssh-agent -s) && ssh-add"
    return 1
  fi

  if [[ ! -S "$SSH_AUTH_SOCK" ]]; then
    log_error "SSH_AUTH_SOCK points to '$SSH_AUTH_SOCK' but the socket doesn't exist."
    log_info "Your agent may have died. Restart with: eval \$(ssh-agent -s) && ssh-add"
    return 1
  fi

  # Check for loaded keys (warning only, not blocking)
  if ! ssh-add -l &>/dev/null; then
    log_warn "SSH agent is running but has no keys loaded. Run 'ssh-add' to add your keys."
  fi

  SSH_SOCKET_SOURCE="$SSH_AUTH_SOCK"
  return 0
}
```

- [ ] **Step 2: Verify detection on your machine**

```bash
source install.sh 2>/dev/null || true
detect_container_runtime
detect_ssh_socket && echo "Socket: $SSH_SOCKET_SOURCE" || echo "Failed"
```

Expected on macOS + Docker Desktop: `Socket: /run/host-services/ssh-auth.sock`
Expected on macOS + Colima or Linux: `Socket: <your SSH_AUTH_SOCK path>`

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "feat(ssh): add detect_ssh_socket() platform detection"
```

---

### Task 3: Add `verify_ssh_agent()` — container-side verification

**Files:**
- Modify: `install.sh` (insert after `cmd_mount()`, around line 401)

- [ ] **Step 1: Add `verify_ssh_agent()` function and `SSH_CONTAINER_TARGET` constant**

Insert after `cmd_mount()`:

```bash
SSH_CONTAINER_TARGET="/tmp/ssh-agent.sock"

# Verify SSH agent forwarding works inside the container
verify_ssh_agent() {
  local workspace_folder="$1"

  # Check if container is running
  local label="devcontainer.local_folder=$workspace_folder"
  local container_id
  container_id=$($CONTAINER_RUNTIME ps -q --filter "label=$label" 2>/dev/null || true)

  if [[ -z "$container_id" ]]; then
    log_info "Container is not running. Changes will take effect on next 'devc up'."
    return 0
  fi

  log_info "Verifying SSH agent forwarding..."

  # Check socket exists in container
  if ! "${DEVCONTAINER_CMD[@]}" exec "${DOCKER_PATH_ARGS[@]}" --workspace-folder "$workspace_folder" \
    test -e "$SSH_CONTAINER_TARGET" 2>/dev/null; then
    log_error "Socket not mounted at $SSH_CONTAINER_TARGET inside container."
    log_info "Try 'devc ssh' again or 'devc rebuild'."
    return 1
  fi

  # Check SSH agent responds
  local ssh_output
  ssh_output=$("${DEVCONTAINER_CMD[@]}" exec "${DOCKER_PATH_ARGS[@]}" --workspace-folder "$workspace_folder" \
    env "SSH_AUTH_SOCK=$SSH_CONTAINER_TARGET" ssh-add -l 2>&1) || true

  if echo "$ssh_output" | grep -q "Could not open a connection"; then
    local os
    os="$(uname -s)"
    if [[ "$os" == "Darwin" && "$SSH_SOCKET_SOURCE" == "/run/host-services/ssh-auth.sock" ]]; then
      log_error "Connection refused. In Docker Desktop, check that SSH agent forwarding is enabled."
    else
      log_error "Host SSH agent may have stopped. Check 'ssh-add -l' on the host."
    fi
    return 1
  fi

  if echo "$ssh_output" | grep -q "The agent has no identities"; then
    log_warn "SSH agent is reachable but no keys loaded. Run 'ssh-add' on the host."
    return 0
  fi

  log_success "SSH agent forwarding is working"
  # Print each key
  while IFS= read -r line; do
    [[ -n "$line" ]] && log_info "  $line"
  done <<< "$ssh_output"
}
```

- [ ] **Step 2: Commit**

```bash
git add install.sh
git commit -m "feat(ssh): add verify_ssh_agent() container diagnostics"
```

---

### Task 4: Add `cmd_ssh()` — state detection and configuration

**Files:**
- Modify: `install.sh` (insert after `verify_ssh_agent()`)

- [ ] **Step 1: Add `cmd_ssh()` function**

Insert immediately after `verify_ssh_agent()`:

```bash
cmd_ssh() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"
  local devcontainer_json="$workspace_folder/.devcontainer/devcontainer.json"

  if [[ ! -f "$devcontainer_json" ]]; then
    log_error "No devcontainer.json found. Run 'devc template' first."
    exit 1
  fi

  check_devcontainer_cli

  # Detect platform-specific socket
  if ! detect_ssh_socket; then
    exit 1
  fi

  # Check existing state in devcontainer.json
  local has_mount="false"
  local has_env="false"
  local current_mount_source=""
  local needs_changes="false"

  # Check if mount targeting SSH_CONTAINER_TARGET exists
  current_mount_source=$(jq -r --arg target "$SSH_CONTAINER_TARGET" '
    .mounts // [] | map(select(contains("target=" + $target))) | .[0] // ""
  ' "$devcontainer_json")
  [[ -n "$current_mount_source" ]] && has_mount="true"

  # Check if containerEnv.SSH_AUTH_SOCK is set
  local current_env
  current_env=$(jq -r '.containerEnv.SSH_AUTH_SOCK // ""' "$devcontainer_json")
  [[ "$current_env" == "$SSH_CONTAINER_TARGET" ]] && has_env="true"

  # Determine what needs to change
  if [[ "$has_mount" == "false" ]]; then
    needs_changes="true"
    log_info "Adding SSH agent socket mount: $SSH_SOCKET_SOURCE -> $SSH_CONTAINER_TARGET"
    update_devcontainer_mounts "$devcontainer_json" "$SSH_SOCKET_SOURCE" "$SSH_CONTAINER_TARGET" "false"
  else
    # Check if mount source matches expected
    if [[ "$current_mount_source" != *"source=${SSH_SOCKET_SOURCE},"* ]]; then
      needs_changes="true"
      log_warn "SSH mount source changed. Updating: $SSH_SOCKET_SOURCE -> $SSH_CONTAINER_TARGET"
      update_devcontainer_mounts "$devcontainer_json" "$SSH_SOCKET_SOURCE" "$SSH_CONTAINER_TARGET" "false"
    else
      log_info "SSH agent socket mount already configured"
    fi
  fi

  if [[ "$has_env" == "false" ]]; then
    needs_changes="true"
    log_info "Setting SSH_AUTH_SOCK=$SSH_CONTAINER_TARGET in containerEnv"
    update_devcontainer_env "$devcontainer_json" "SSH_AUTH_SOCK" "$SSH_CONTAINER_TARGET"
  else
    log_info "SSH_AUTH_SOCK already set in containerEnv"
  fi

  # Recreate container if changes were made
  if [[ "$needs_changes" == "true" ]]; then
    log_info "Recreating container with SSH agent forwarding..."
    "${DEVCONTAINER_CMD[@]}" up "${DOCKER_PATH_ARGS[@]}" --workspace-folder "$workspace_folder" --remove-existing-container
  fi

  # Verify SSH agent inside container
  verify_ssh_agent "$workspace_folder"
}
```

- [ ] **Step 2: Commit**

```bash
git add install.sh
git commit -m "feat(ssh): add cmd_ssh() with state detection and configuration"
```

---

### Task 5: Wire `ssh` into help, completions, and dispatch

**Files:**
- Modify: `install.sh:41` (help text)
- Modify: `install.sh:58` (examples)
- Modify: `install.sh:727` (zsh completion)
- Modify: `install.sh:759` (bash completion)
- Modify: `install.sh:942-997` (case dispatch)

**Note:** Line numbers are approximate — they will have shifted due to code added in Tasks 1-4. Use content matching, not line numbers.

- [ ] **Step 1: Add `ssh` to help text**

In `print_usage()`, add after the `mount` line:

```
    ssh                 Configure SSH agent forwarding in the container
```

Add to examples section (after the `mount` example):

```
    devc ssh                    # Set up SSH agent forwarding
```

- [ ] **Step 2: Add `ssh` to zsh completion**

In the zsh completion commands array, add after the `mount` entry:

```
    'ssh:Configure SSH agent forwarding'
```

- [ ] **Step 3: Add `ssh` to bash completion**

In the bash completion commands string, add `ssh` to the list:

```
  local commands=". up rebuild down shell exec upgrade mount ssh template self-install self-update update completion help"
```

- [ ] **Step 4: Add `ssh` to case dispatch**

In the `main()` case statement, add after the `mount)` case:

```bash
  ssh)
    cmd_ssh
    ;;
```

- [ ] **Step 5: Verify help and completion output**

```bash
bash install.sh help | grep ssh
bash install.sh completion | grep ssh
```

Expected: `ssh` appears in both help output and completion script.

- [ ] **Step 6: Commit**

```bash
git add install.sh
git commit -m "feat(ssh): wire devc ssh into help, completions, and dispatch"
```

---

### Task 6: Manual end-to-end validation

- [ ] **Step 1: Run `devc ssh` for first-time setup**

```bash
devc ssh
```

Expected: Detects platform, adds mount + env var, recreates container, verifies SSH keys visible.

- [ ] **Step 2: Run `devc ssh` again (idempotent)**

```bash
devc ssh
```

Expected: Detects existing config, skips to verification, shows keys.

- [ ] **Step 3: Test partial state recovery**

Manually remove `SSH_AUTH_SOCK` from `containerEnv` in `.devcontainer/devcontainer.json`, then:

```bash
devc ssh
```

Expected: Detects missing env var, adds it, recreates container, verifies.

- [ ] **Step 4: Test host agent diagnostics**

Stop SSH agent on host (or unset `SSH_AUTH_SOCK` for non-Docker-Desktop platforms), then:

```bash
devc ssh
```

Expected: Shows platform-specific diagnostic guidance and does not proceed with configuration.

- [ ] **Step 5: Verify mount survives template update**

```bash
devc template .
devc ssh
```

Expected: After template overwrite, the SSH mount is preserved by `extract_mounts_to_file()`/`merge_mounts_from_file()`. `devc ssh` only needs to re-add the env var (which is not preserved by the mount system).

- [ ] **Step 6: Commit any fixes from validation**

If any issues were found and fixed during validation, commit them.
