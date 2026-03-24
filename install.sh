#!/bin/bash
set -euo pipefail

# Claude Code Devcontainer CLI Helper
# Provides the `devc` command for managing devcontainers

# Resolve symlinks to get actual script location
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
  cat <<EOF
Usage: devc <command> [options]

Commands:
    .                   Install devcontainer template to current directory and start
    up                  Start the devcontainer in current directory
    rebuild             Rebuild the devcontainer (preserves auth volumes)
    down                Stop the devcontainer
    shell               Open a shell in the running container
    self-install        Install 'devc' command to ~/.local/bin
    self-update         Pull latest code and re-install devc (alias: update)
    completion          Output shell completion script
    template [dir]      Copy devcontainer template to directory (default: current)
    exec <cmd>          Execute a command in the running container
    upgrade             Upgrade Claude Code to latest version
    mount <host> <cont> Add a mount to the devcontainer (recreates container)
    ssh                 Configure SSH agent forwarding in the container
    ssh-stop            Stop the SSH agent tunnel (Podman Machine only)
    sync [project] [--trusted]  Sync sessions from devcontainers to host
    cp <cont> <host>    Copy files/directories from container to host
    destroy [-f] [dir]  Remove container, volumes, and image for a project
    help                Show this help message

Examples:
    devc .                      # Install template and start container
    devc up                     # Start container in current directory
    devc rebuild                # Clean rebuild
    devc shell                  # Open interactive shell
    devc self-install           # Install devc to PATH
    devc self-update            # Pull latest and re-install (or: devc update)
    devc completion             # Print shell completion script
    devc exec ls -la            # Run command in container
    devc upgrade                # Upgrade Claude Code to latest
    devc mount ~/data /data     # Add mount to container
    devc ssh                    # Set up SSH agent forwarding
    devc ssh-stop               # Stop SSH agent tunnel
    devc sync                   # Sync sessions from all devcontainers
    devc sync crypto            # Sync only matching devcontainer
    devc cp /some/file ./out    # Copy a path from container to host
    devc destroy                # Remove all project Docker resources
    devc destroy -f             # Skip confirmation prompt
EOF
}

log_info() {
  echo -e "${BLUE}[devc]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[devc]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[devc]${NC} $1"
}

log_error() {
  echo -e "${RED}[devc]${NC} $1" >&2
}

CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-}"
# Support env var override: split string into array if set
if [[ -n "${DEVCONTAINER_CMD:-}" ]]; then
  read -ra DEVCONTAINER_CMD <<< "$DEVCONTAINER_CMD"
else
  DEVCONTAINER_CMD=()
fi
DOCKER_PATH_ARGS=()

_setup_podman() {
  DOCKER_PATH_ARGS=(--docker-path podman)
  if [[ -z "${DOCKER_HOST:-}" ]]; then
    DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
    export DOCKER_HOST
  fi
}

detect_container_runtime() {
  if [[ -n "$CONTAINER_RUNTIME" ]]; then
    [[ "$CONTAINER_RUNTIME" == "podman" ]] && _setup_podman
    return
  fi
  if command -v docker &>/dev/null; then
    CONTAINER_RUNTIME="docker"
  elif command -v podman &>/dev/null; then
    CONTAINER_RUNTIME="podman"
    _setup_podman
  else
    log_error "No container runtime found. Install Docker or Podman."
    exit 1
  fi
}

detect_devcontainer_cli() {
  if [[ ${#DEVCONTAINER_CMD[@]} -gt 0 ]]; then return; fi
  if command -v devcontainer &>/dev/null; then
    DEVCONTAINER_CMD=(devcontainer)
  elif command -v npx &>/dev/null; then
    DEVCONTAINER_CMD=(npx @devcontainers/cli)
  else
    log_error "devcontainer CLI not found."
    log_info "Install Node.js and use: npx @devcontainers/cli"
    exit 1
  fi
}

check_devcontainer_cli() {
  detect_container_runtime
  detect_devcontainer_cli
}

check_no_sys_admin() {
  local workspace="${1:-.}"
  local dc_json="$workspace/.devcontainer/devcontainer.json"
  [[ -f "$dc_json" ]] || return 0
  if jq -e '
    (.runArgs[]? | select(test("SYS_ADMIN"))) //
    (.capAdd[]? | select(. == "SYS_ADMIN"))
  ' "$dc_json" >/dev/null 2>&1; then
    log_error "SYS_ADMIN capability detected in devcontainer.json."
    log_error "This defeats the read-only .devcontainer mount."
    exit 1
  fi
}

get_workspace_folder() {
  echo "${1:-$(pwd)}"
}

# Extract custom mounts from devcontainer.json to a temp file
# Returns the temp file path, or empty string if no custom mounts
#
# Security: .devcontainer/ is mounted read-only inside the container to prevent
# a compromised process from injecting malicious mounts or commands into
# devcontainer.json that execute on the host during rebuild. This protection
# requires that SYS_ADMIN is never added to runArgs (it would allow remounting
# read-write).
extract_mounts_to_file() {
  local devcontainer_json="$1"
  local temp_file

  [[ -f "$devcontainer_json" ]] || return 0

  temp_file=$(mktemp)

  # Filter out default mounts by target path (immune to project name changes)
  local custom_mounts
  custom_mounts=$(jq -c '
    .mounts // [] | map(
      select(
        (contains("target=/commandhistory,") | not) and
        (contains("target=/home/vscode/.claude,") | not) and
        (contains("target=/home/vscode/.config/gh,") | not) and
        (contains("target=/home/vscode/.gitconfig,") | not) and
        (contains("target=/workspace/.devcontainer,") | not)
      )
    ) | if length > 0 then . else empty end
  ' "$devcontainer_json" 2>/dev/null) || true

  if [[ -n "$custom_mounts" ]]; then
    echo "$custom_mounts" >"$temp_file"
    echo "$temp_file"
  else
    rm -f "$temp_file"
  fi
}

# Merge preserved mounts back into devcontainer.json
merge_mounts_from_file() {
  local devcontainer_json="$1"
  local mounts_file="$2"

  [[ -f "$mounts_file" ]] || return 0
  [[ -s "$mounts_file" ]] || return 0

  local custom_mounts
  custom_mounts=$(cat "$mounts_file")

  local updated
  updated=$(jq --argjson custom "$custom_mounts" '
    .mounts = ((.mounts // []) + $custom | unique)
  ' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}

# Add or update a mount in devcontainer.json
update_devcontainer_mounts() {
  local devcontainer_json="$1"
  local host_path="$2"
  local container_path="$3"
  local readonly="${4:-false}"

  local mount_str="source=${host_path},target=${container_path},type=bind"
  [[ "$readonly" == "true" ]] && mount_str="${mount_str},readonly"

  local updated
  updated=$(jq --arg target "$container_path" --arg mount "$mount_str" '
    .mounts = (
      ((.mounts // []) | map(select(contains("target=" + $target + ",") or endswith("target=" + $target) | not)))
      + [$mount]
    )
  ' "$devcontainer_json")

  echo "$updated" >"$devcontainer_json"
}

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

# Detect the platform-specific SSH agent socket path.
# Sets SSH_SOCKET_SOURCE on success.
# Returns 1 with diagnostic guidance on failure.
detect_ssh_socket() {
  SSH_SOCKET_SOURCE=""
  local os
  os="$(uname -s)"

  # macOS + Docker Desktop: uses a built-in socket
  # Positively identify Docker Desktop by its OS string to avoid false
  # matches with OrbStack, Colima, or other Docker-compatible engines.
  if [[ "$os" == "Darwin" && "$CONTAINER_RUNTIME" == "docker" ]]; then
    local docker_os
    docker_os=$(docker info -f '{{.OperatingSystem}}' 2>/dev/null || true)
    if [[ "$docker_os" == *"Docker Desktop"* ]]; then
      SSH_SOCKET_SOURCE="$DOCKER_DESKTOP_SSH_SOCK"
      return 0
    fi
  fi

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
  # ssh-add -l exits 1 = no keys, 2 = agent unreachable
  local rc=0
  ssh-add -l &>/dev/null || rc=$?
  if [[ $rc -eq 1 ]]; then
    log_warn "SSH agent is running but has no keys loaded. Run 'ssh-add' to add your keys."
  elif [[ $rc -eq 2 ]]; then
    log_error "SSH agent socket exists but agent is not responding."
    log_info "Restart with: eval \$(ssh-agent -s) && ssh-add"
    return 1
  fi

  SSH_SOCKET_SOURCE="$SSH_AUTH_SOCK"
  return 0
}

cmd_template() {
  local target_dir="${1:-.}"
  target_dir="$(cd "$target_dir" 2>/dev/null && pwd)" || {
    log_error "Directory does not exist: $1"
    exit 1
  }

  local devcontainer_dir="$target_dir/.devcontainer"
  local devcontainer_json="$devcontainer_dir/devcontainer.json"
  local preserved_mounts=""

  if [[ -d "$devcontainer_dir" ]]; then
    log_warn "Devcontainer already exists at $devcontainer_dir"
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      exit 0
    fi

    # Preserve custom mounts before overwriting
    preserved_mounts=$(extract_mounts_to_file "$devcontainer_json")
    if [[ -n "$preserved_mounts" ]]; then
      log_info "Preserving custom mounts..."
    fi
  fi

  mkdir -p "$devcontainer_dir"

  # Copy template files
  cp "$SCRIPT_DIR/Dockerfile" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/devcontainer.json" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/post_install.py" "$devcontainer_dir/"
  cp "$SCRIPT_DIR/.zshrc" "$devcontainer_dir/"
  cp -r "$SCRIPT_DIR/completions" "$devcontainer_dir/"

  # Restore preserved mounts
  if [[ -n "$preserved_mounts" ]]; then
    merge_mounts_from_file "$devcontainer_json" "$preserved_mounts"
    rm -f "$preserved_mounts"
    log_info "Custom mounts restored"
  fi

  log_success "Template installed to $devcontainer_dir"
}

cmd_up() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  check_no_sys_admin "$workspace_folder"
  log_info "Starting devcontainer in $workspace_folder..."

  "${DEVCONTAINER_CMD[@]}" up ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} --workspace-folder "$workspace_folder"
  log_success "Devcontainer started"
}

cmd_rebuild() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  check_no_sys_admin "$workspace_folder"
  log_info "Rebuilding devcontainer in $workspace_folder..."

  "${DEVCONTAINER_CMD[@]}" up ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} --workspace-folder "$workspace_folder" --remove-existing-container
  log_success "Devcontainer rebuilt"
}

cmd_down() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  check_devcontainer_cli
  log_info "Stopping devcontainer..."

  # Get container ID and stop it
  local label="devcontainer.local_folder=$workspace_folder"
  local container_id
  container_id=$("$CONTAINER_RUNTIME" ps -q --filter "label=$label" 2>/dev/null || true)

  if [[ -n "$container_id" ]]; then
    "$CONTAINER_RUNTIME" stop "$container_id"
    log_success "Devcontainer stopped"
  else
    log_warn "No running devcontainer found for $workspace_folder"
  fi
}

cmd_shell() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  log_info "Opening shell in devcontainer..."

  "${DEVCONTAINER_CMD[@]}" exec ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} --workspace-folder "$workspace_folder" zsh
}

cmd_exec() {
  if [[ $# -eq 0 ]]; then
    log_error "Usage: devc exec <command> [args...]"
    exit 1
  fi

  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  "${DEVCONTAINER_CMD[@]}" exec ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} --workspace-folder "$workspace_folder" "$@"
}

cmd_upgrade() {
  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  check_devcontainer_cli
  log_info "Upgrading Claude Code..."

  "${DEVCONTAINER_CMD[@]}" exec ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} --workspace-folder "$workspace_folder" claude update

  log_success "Claude Code upgraded"
}

cmd_mount() {
  local host_path="${1:-}"
  local container_path="${2:-}"
  local readonly="false"

  if [[ -z "$host_path" ]] || [[ -z "$container_path" ]]; then
    log_error "Usage: devc mount <host_path> <container_path> [--readonly]"
    exit 1
  fi

  [[ "${3:-}" == "--readonly" ]] && readonly="true"

  # Block mounts to security-sensitive container paths
  local -a protected_paths=(
    "/workspace/.devcontainer"
    "/home/vscode/.claude"
    "/home/vscode/.local"
  )
  for p in "${protected_paths[@]}"; do
    if [[ "$container_path" == "$p" || "$container_path" == "$p/"* ]]; then
      log_error "Cannot mount to protected path: $container_path"
      exit 1
    fi
  done

  # Expand and validate host path
  host_path="$(cd "$host_path" 2>/dev/null && pwd)" || {
    log_error "Host path does not exist: $1"
    exit 1
  }

  local workspace_folder
  workspace_folder="$(get_workspace_folder)"
  local devcontainer_json="$workspace_folder/.devcontainer/devcontainer.json"

  if [[ ! -f "$devcontainer_json" ]]; then
    log_error "No devcontainer.json found. Run 'devc template' first."
    exit 1
  fi

  check_devcontainer_cli

  log_info "Adding mount: $host_path → $container_path"
  update_devcontainer_mounts "$devcontainer_json" "$host_path" "$container_path" "$readonly"

  log_info "Recreating container with new mount..."
  "${DEVCONTAINER_CMD[@]}" up ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} --workspace-folder "$workspace_folder" --remove-existing-container

  log_success "Mount added: $host_path → $container_path"
}

SSH_CONTAINER_TARGET="/tmp/ssh-agent.sock"
DOCKER_DESKTOP_SSH_SOCK="/run/host-services/ssh-auth.sock"
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

# Verify SSH agent forwarding works inside the container
# Requires: SSH_SOCKET_SOURCE set by detect_ssh_socket()
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
  if ! "${DEVCONTAINER_CMD[@]}" exec ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} --workspace-folder "$workspace_folder" \
    test -e "$SSH_CONTAINER_TARGET" 2>/dev/null; then
    log_error "Socket not mounted at $SSH_CONTAINER_TARGET inside container."
    log_info "Try 'devc ssh' again or 'devc rebuild'."
    return 1
  fi

  # Check SSH agent responds
  local ssh_output
  ssh_output=$("${DEVCONTAINER_CMD[@]}" exec ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} --workspace-folder "$workspace_folder" \
    env "SSH_AUTH_SOCK=$SSH_CONTAINER_TARGET" ssh-add -l 2>&1) || true

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

  if echo "$ssh_output" | grep -q "The agent has no identities"; then
    log_warn "SSH agent is reachable but no keys loaded. Run 'ssh-add' on the host."
    return 0
  fi

  log_success "SSH agent forwarding is working"
  while IFS= read -r line; do
    [[ -n "$line" ]] && log_info "  $line"
  done <<< "$ssh_output"
}

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

  # Check existing state in devcontainer.json (single jq read)
  local current_mount_source=""
  local current_env=""
  local needs_changes="false"
  local state_json
  state_json=$(jq -r --arg target "$SSH_CONTAINER_TARGET" '{
    mount: ((.mounts // []) | map(select(contains("target=" + $target))) | .[0] // ""),
    env: (.containerEnv.SSH_AUTH_SOCK // "")
  }' "$devcontainer_json")
  current_mount_source=$(echo "$state_json" | jq -r '.mount')
  current_env=$(echo "$state_json" | jq -r '.env')

  # Determine what needs to change
  if [[ -z "$current_mount_source" ]]; then
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

  if [[ "$current_env" != "$SSH_CONTAINER_TARGET" ]]; then
    needs_changes="true"
    log_info "Setting SSH_AUTH_SOCK=$SSH_CONTAINER_TARGET in containerEnv"
    update_devcontainer_env "$devcontainer_json" "SSH_AUTH_SOCK" "$SSH_CONTAINER_TARGET"
  else
    log_info "SSH_AUTH_SOCK already set in containerEnv"
  fi

  # Recreate container if changes were made
  if [[ "$needs_changes" == "true" ]]; then
    log_info "Recreating container with SSH agent forwarding..."
    "${DEVCONTAINER_CMD[@]}" up ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} --workspace-folder "$workspace_folder" --remove-existing-container
  fi

  # Verify SSH agent inside container
  verify_ssh_agent "$workspace_folder"
}

cmd_ssh_stop() {
  stop_ssh_tunnel
}

cmd_sync() {
  local filter=""
  local trusted=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --trusted)
      trusted=true
      shift
      ;;
    *)
      filter="$1"
      shift
      ;;
    esac
  done

  local host_projects="${HOME}/.claude/projects"

  if [[ "$trusted" == false ]]; then
    log_warn "This copies files from devcontainers to your host filesystem."
    log_warn "Only proceed if you trust the container contents."
    log_info "Use --trusted to skip this prompt."
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      exit 0
    fi
  fi

  detect_container_runtime

  # Discover all devcontainers (running + stopped) by label.
  local container_ids
  container_ids=$("$CONTAINER_RUNTIME" ps -a -q \
    --filter "label=devcontainer.local_folder" 2>/dev/null || true)

  if [[ -z "$container_ids" ]]; then
    log_error "No devcontainers found (running or stopped)."
    exit 1
  fi

  # List discovered devcontainers.
  log_info "Discovered devcontainers:"
  local matched_any=false
  local name folder status
  while IFS= read -r cid; do
    name=$(sync_get_project_name "$cid")
    folder=$("$CONTAINER_RUNTIME" inspect --format \
      '{{index .Config.Labels "devcontainer.local_folder"}}' "$cid")
    status=$("$CONTAINER_RUNTIME" inspect --format '{{.State.Status}}' "$cid")

    if [[ -n "$filter" ]]; then
      if ! echo "$name" | grep -qi "$filter"; then
        continue
      fi
    fi

    matched_any=true
    echo "  - ${name} (${status}) ${folder}"
  done <<< "$container_ids"

  if [[ "$matched_any" == false ]]; then
    log_error "No devcontainers matching '${filter}'."
    echo ""
    echo "Available:"
    local name2 status2
    while IFS= read -r cid; do
      name2=$(sync_get_project_name "$cid")
      status2=$("$CONTAINER_RUNTIME" inspect --format '{{.State.Status}}' "$cid")
      echo "  - ${name2} (${status2})"
    done <<< "$container_ids"
    exit 1
  fi

  echo ""

  # Sync matching containers.
  while IFS= read -r cid; do
    name=$(sync_get_project_name "$cid")

    if [[ -n "$filter" ]]; then
      if ! echo "$name" | grep -qi "$filter"; then
        continue
      fi
    fi

    sync_one_container "$cid" "$host_projects"
    echo ""
  done <<< "$container_ids"

  log_success "Run '/insights' in Claude Code to include these sessions."
}

# Extract project name from devcontainer.local_folder label.
sync_get_project_name() {
  local folder
  folder=$("$CONTAINER_RUNTIME" inspect --format \
    '{{index .Config.Labels "devcontainer.local_folder"}}' "$1")
  basename "$folder"
}

# Resolve the Claude projects dir inside a container without
# container exec (works on stopped containers too).
# Reads CLAUDE_CONFIG_DIR from container env, falls back to
# /home/<user>/.claude.
sync_get_claude_projects_dir() {
  local cid="$1"
  local claude_dir

  claude_dir=$("$CONTAINER_RUNTIME" inspect --format '{{json .Config.Env}}' "$cid" \
    | tr ',' '\n' | tr -d '[]"' \
    | grep '^CLAUDE_CONFIG_DIR=' \
    | cut -d= -f2- || true)

  if [[ -n "$claude_dir" ]]; then
    echo "${claude_dir}/projects"
    return
  fi

  local user
  user=$("$CONTAINER_RUNTIME" inspect --format '{{.Config.User}}' "$cid")
  if [[ -z "$user" || "$user" == "root" ]]; then
    echo "/root/.claude/projects"
  else
    echo "/home/${user}/.claude/projects"
  fi
}

sync_one_container() {
  local cid="$1"
  local host_projects="$2"
  local project_name status claude_dir folder

  project_name=$(sync_get_project_name "$cid")
  folder=$("$CONTAINER_RUNTIME" inspect --format \
    '{{index .Config.Labels "devcontainer.local_folder"}}' "$cid")
  status=$("$CONTAINER_RUNTIME" inspect --format '{{.State.Status}}' "$cid")
  claude_dir=$(sync_get_claude_projects_dir "$cid")

  log_info "=== ${project_name} (${status}) ==="
  echo "  Host path:  ${folder}"
  echo "  Container:  ${cid:0:12}"

  # Container cp works on both running and stopped containers.
  local tmpdir
  tmpdir=$(mktemp -d)

  if ! "$CONTAINER_RUNTIME" cp "${cid}:${claude_dir}/." "$tmpdir/" 2>/dev/null; then
    echo "  No sessions found, skipping."
    rm -rf "$tmpdir"
    return 0
  fi

  local session_count
  session_count=$(find "$tmpdir" -name '*.jsonl' | wc -l | tr -d ' ')

  if [[ "$session_count" -eq 0 ]]; then
    echo "  No sessions found, skipping."
    rm -rf "$tmpdir"
    return 0
  fi

  echo "  Sessions:   ${session_count}"

  local total_copied=0

  # Sync each project key subdirectory.
  for key_path in "$tmpdir"/*/; do
    [[ ! -d "$key_path" ]] && continue
    local key dest_key
    key=$(basename "$key_path")

    if [[ "$key" == "-workspace" ]]; then
      dest_key="-devcontainer-${project_name}"
    else
      dest_key="${key}"
    fi

    local dest_dir="${host_projects}/${dest_key}"
    mkdir -p "$dest_dir"

    local copied=0
    while IFS= read -r -d '' file; do
      local rel="${file#"$key_path"}"
      local dest_file="${dest_dir}/${rel}"
      mkdir -p "$(dirname "$dest_file")"

      if [[ ! -e "$dest_file" ]] \
          || [[ "$file" -nt "$dest_file" ]]; then
        cp -p "$file" "$dest_file"
        copied=$((copied + 1))
      fi
    done < <(find "$key_path" -type f -print0)

    if [[ "$copied" -gt 0 ]]; then
      echo "  Synced ${copied} file(s) -> ${dest_key}"
    fi
    total_copied=$((total_copied + copied))
  done

  # Handle .jsonl files directly in projects/ (no subdirectory).
  local orphan_copied=0
  local dest_dir="${host_projects}/-devcontainer-${project_name}"
  mkdir -p "$dest_dir"

  while IFS= read -r -d '' file; do
    local name
    name=$(basename "$file")
    local dest_file="${dest_dir}/${name}"

    if [[ ! -e "$dest_file" ]] \
        || [[ "$file" -nt "$dest_file" ]]; then
      cp -p "$file" "$dest_file"
      orphan_copied=$((orphan_copied + 1))
    fi
  done < <(find "$tmpdir" -maxdepth 1 -name '*.jsonl' -print0)

  if [[ "$orphan_copied" -gt 0 ]]; then
    echo "  Synced ${orphan_copied} file(s) -> -devcontainer-${project_name}"
    total_copied=$((total_copied + orphan_copied))
  fi

  rm -rf "$tmpdir"

  echo "  Total: ${total_copied} file(s) synced."
}

cmd_cp() {
  local container_path="${1:-}"
  local host_path="${2:-}"

  if [[ -z "$container_path" ]] || [[ -z "$host_path" ]]; then
    log_error "Usage: devc cp <container_path> <host_path>"
    exit 1
  fi

  local workspace_folder
  workspace_folder="$(get_workspace_folder)"

  detect_container_runtime

  # Find the running container
  local label="devcontainer.local_folder=$workspace_folder"
  local container_id
  container_id=$("$CONTAINER_RUNTIME" ps -q --filter "label=$label" 2>/dev/null || true)

  if [[ -z "$container_id" ]]; then
    log_error "No running devcontainer found for $workspace_folder"
    exit 1
  fi

  log_info "Copying $container_path → $host_path"
  "$CONTAINER_RUNTIME" cp "$container_id:$container_path" "$host_path"
  log_success "Copied $container_path → $host_path"
}

cmd_self_install() {
  local install_dir="$HOME/.local/bin"
  local install_path="$install_dir/devc"

  mkdir -p "$install_dir"

  # Create a symlink to the original script
  ln -sf "$SCRIPT_DIR/$SCRIPT_NAME" "$install_path"

  log_success "Installed 'devc' to $install_path"

  # Check if in PATH
  if [[ ":$PATH:" != *":$install_dir:"* ]]; then
    log_warn "$install_dir is not in your PATH"
    log_info "Add this to your shell profile:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

cmd_update() {
  log_info "Updating devc..."

  if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    log_error "Not a git repository: $SCRIPT_DIR"
    log_info "Re-clone with: rm -rf ~/.claude-devcontainer && git clone https://github.com/jason-hchsieh/claude-code-devcontainer ~/.claude-devcontainer"
    exit 1
  fi

  local before_sha after_sha
  before_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

  if ! git -C "$SCRIPT_DIR" pull --ff-only; then
    log_error "Update failed. Try: cd $SCRIPT_DIR && git pull"
    exit 1
  fi

  after_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD)

  if [[ "$before_sha" == "$after_sha" ]]; then
    log_success "Already up to date"
  else
    log_success "Updated from ${before_sha:0:7} to ${after_sha:0:7}"
  fi
}

cmd_self_update() {
  cmd_update
  cmd_self_install
}

cmd_completion() {
  local shell_name
  shell_name="$(basename "${SHELL:-/bin/bash}")"

  case "$shell_name" in
  zsh)
    cat <<'COMP'
#compdef devc

_devc() {
  local -a commands
  commands=(
    '.:Install template and start container'
    'up:Start the devcontainer'
    'rebuild:Rebuild the devcontainer'
    'down:Stop the devcontainer'
    'shell:Open a shell in the container'
    'exec:Execute a command in the container'
    'upgrade:Upgrade Claude Code'
    'mount:Add a bind mount'
    'ssh:Configure SSH agent forwarding'
    'ssh-stop:Stop SSH agent tunnel'
    'sync:Sync sessions from devcontainers to host'
    'cp:Copy files from container to host'
    'destroy:Remove container, volumes, and image'
    'template:Copy devcontainer template'
    'self-install:Install devc to PATH'
    'self-update:Pull latest and re-install devc'
    'update:Update devc to latest version'
    'completion:Output shell completion script'
    'help:Show help message'
  )

  if (( CURRENT == 2 )); then
    _describe 'command' commands
  else
    case "${words[2]}" in
    exec)
      _normal
      ;;
    mount)
      _files -/
      ;;
    template)
      _files -/
      ;;
    esac
  fi
}

compdef _devc devc
COMP
    ;;
  *)
    cat <<'COMP'
_devc_completions() {
  local commands=". up rebuild down shell exec upgrade mount ssh ssh-stop sync cp destroy template self-install self-update update completion help"
  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$commands" -- "${COMP_WORDS[1]}"))
  fi
}

complete -F _devc_completions devc
COMP
    ;;
  esac

  # Only show setup hint when run directly (not via eval in shell profile)
  if [[ -t 1 ]]; then
    log_info "Add to your shell profile:" >&2
    echo "  eval \"\$(devc completion)\"" >&2
  fi
}

cmd_dot() {
  # Install template and start container in one command
  cmd_template "."
  cmd_up "."
}

# Discovers all Docker resources associated with the current workspace.
# Sets global variables: CONTAINER_ID, CONTAINER_STATUS, VOLUMES (array), IMAGE, IMAGE_UID
discover_resources() {
  local workspace_folder="$1"
  local label="devcontainer.local_folder=$workspace_folder"

  CONTAINER_ID=""
  CONTAINER_STATUS=""
  VOLUMES=()
  IMAGE=""
  IMAGE_UID=""

  # Find container (any state: running, stopped, created, etc.)
  CONTAINER_ID=$("$CONTAINER_RUNTIME" ps -aq --filter "label=$label" 2>/dev/null | head -1)

  if [[ -z "$CONTAINER_ID" ]]; then
    return 0
  fi

  # Get container status
  CONTAINER_STATUS=$("$CONTAINER_RUNTIME" inspect "$CONTAINER_ID" --format '{{.State.Status}}' 2>/dev/null || true)

  # Get volumes (named volumes only, not bind mounts)
  while IFS= read -r vol; do
    [[ -n "$vol" ]] && VOLUMES+=("$vol")
  done < <("$CONTAINER_RUNTIME" inspect "$CONTAINER_ID" --format '{{json .Mounts}}' 2>/dev/null \
    | jq -r '.[] | select(.Type == "volume") | .Name' 2>/dev/null)

  # Get image and its -uid variant
  IMAGE=$("$CONTAINER_RUNTIME" inspect "$CONTAINER_ID" --format '{{.Config.Image}}' 2>/dev/null || true)
  if [[ -n "$IMAGE" ]]; then
    if [[ "$IMAGE" == *-uid ]]; then
      IMAGE_UID="$IMAGE"
      IMAGE="${IMAGE%-uid}"
    else
      IMAGE_UID="${IMAGE}-uid"
    fi
  fi
}

print_destroy_summary() {
  echo ""
  log_warn "The following resources will be permanently removed:"
  echo ""

  if [[ -n "$CONTAINER_ID" ]]; then
    local container_name
    container_name=$("$CONTAINER_RUNTIME" inspect "$CONTAINER_ID" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')
    echo "  Container:  ${container_name:-$CONTAINER_ID}"
    if [[ "$CONTAINER_STATUS" == "running" ]]; then
      echo "              (currently running -- will be force-stopped)"
    fi
  fi

  if [[ ${#VOLUMES[@]} -gt 0 ]]; then
    echo "  Volumes:"
    for vol in "${VOLUMES[@]}"; do
      echo "              $vol"
    done
  fi

  if [[ -n "$IMAGE" ]]; then
    echo "  Image:      $IMAGE"
    if "$CONTAINER_RUNTIME" image inspect "$IMAGE_UID" &>/dev/null; then
      echo "              $IMAGE_UID"
    fi
  fi

  echo ""
}

cmd_destroy() {
  local force=false

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        force=true
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  local workspace_folder
  workspace_folder="$(get_workspace_folder "${1:-}")"

  detect_container_runtime
  discover_resources "$workspace_folder"

  # No resources found (idempotent behavior)
  if [[ -z "$CONTAINER_ID" ]]; then
    log_info "No devcontainer found for $workspace_folder"
    return 0
  fi

  print_destroy_summary

  # Running container warning
  if [[ "$CONTAINER_STATUS" == "running" && "$force" != true ]]; then
    log_warn "Container is currently running!"
    read -p "Force-stop the running container? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      return 0
    fi
  fi

  # Main confirmation prompt
  if [[ "$force" != true ]]; then
    read -p "Destroy these resources? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Aborted."
      return 0
    fi
  fi

  # Deletion, in order: stop, remove container, volumes, images
  if [[ -n "$CONTAINER_ID" && "$CONTAINER_STATUS" == "running" ]]; then
    log_info "Stopping container..."
    "$CONTAINER_RUNTIME" stop "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$CONTAINER_ID" ]]; then
    log_info "Removing container..."
    "$CONTAINER_RUNTIME" rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
  fi

  for vol in ${VOLUMES[@]+"${VOLUMES[@]}"}; do
    log_info "Removing volume: $vol"
    "$CONTAINER_RUNTIME" volume rm -f "$vol" >/dev/null 2>&1 || true
  done

  if [[ -n "$IMAGE" ]]; then
    log_info "Removing image: $IMAGE"
    "$CONTAINER_RUNTIME" rmi -f "$IMAGE" >/dev/null 2>&1 || true
    if "$CONTAINER_RUNTIME" image inspect "$IMAGE_UID" &>/dev/null 2>&1; then
      log_info "Removing image: $IMAGE_UID"
      "$CONTAINER_RUNTIME" rmi -f "$IMAGE_UID" >/dev/null 2>&1 || true
    fi
  fi

  # Clean up SSH tunnel if running (Podman Machine only)
  stop_ssh_tunnel 2>/dev/null

  log_success "All resources destroyed for $workspace_folder"
}

# Main command dispatcher
main() {
  if [[ $# -eq 0 ]]; then
    print_usage
    exit 1
  fi

  local command="$1"
  shift

  case "$command" in
  .)
    if [[ $# -gt 0 ]]; then
      log_error "'devc .' does not accept arguments (it always targets the current directory)"
      exit 1
    fi
    cmd_dot
    ;;
  up)
    cmd_up "$@"
    ;;
  rebuild)
    cmd_rebuild "$@"
    ;;
  down)
    cmd_down "$@"
    ;;
  destroy)
    cmd_destroy "$@"
    ;;
  shell)
    cmd_shell
    ;;
  exec)
    [[ "${1:-}" == "--" ]] && shift
    cmd_exec "$@"
    ;;
  upgrade)
    cmd_upgrade
    ;;
  mount)
    cmd_mount "$@"
    ;;
  ssh)
    cmd_ssh
    ;;
  ssh-stop)
    cmd_ssh_stop
    ;;
  sync)
    cmd_sync "$@"
    ;;
  cp)
    cmd_cp "$@"
    ;;
  self-install)
    cmd_self_install
    ;;
  self-update | update)
    cmd_self_update
    ;;
  completion)
    cmd_completion
    ;;
  template)
    cmd_template "$@"
    ;;
  help | --help | -h)
    print_usage
    ;;
  *)
    log_error "Unknown command: $command"
    print_usage
    exit 1
    ;;
  esac
}

main "$@"
