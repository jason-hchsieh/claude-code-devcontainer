# Claude Code in a devcontainer

A sandboxed development environment for running Claude Code with `bypassPermissions` safely enabled.

## Why Use This?

Running Claude with `bypassPermissions` on your host machine is risky—it can execute any command without confirmation. This devcontainer provides **filesystem isolation** so you get the productivity benefits of unrestricted Claude without risking your host system.

**Designed for:**

- **Security audits**: Review client code without risking your host
- **Untrusted repositories**: Explore unknown codebases safely
- **Experimental work**: Let Claude modify code freely in isolation
- **Multi-repo engagements**: Work on multiple related repositories

## Prerequisites

- **Container runtime** (one of):
  - [Docker Desktop](https://docker.com/products/docker-desktop) - ensure it's running
  - [OrbStack](https://orbstack.dev/)
  - [Podman](https://podman.io/): `brew install podman && podman machine init && podman machine start`
    - Set `CONTAINER_RUNTIME=podman` when calling `devc` (see [Using Podman](#using-podman))
  - [Colima](https://github.com/abiosoft/colima): `brew install colima docker && colima start`

- **For terminal workflows** (one-time install):

  ```bash
  git clone https://github.com/jason-hchsieh/claude-code-devcontainer ~/.claude-devcontainer
  ~/.claude-devcontainer/install.sh self-install
  ```

  The `devc` CLI uses `npx @devcontainers/cli` automatically if the devcontainer CLI is not globally installed. If you prefer a global install: `npm install -g @devcontainers/cli`.

<details>
<summary><strong>Optimizing Colima for Apple Silicon</strong></summary>

Colima's defaults (QEMU + sshfs) are conservative. For better performance:

```bash
# Stop and delete current VM (removes containers/images)
colima stop && colima delete

# Start with optimized settings
colima start \
  --cpu 4 \
  --memory 8 \
  --disk 100 \
  --vm-type vz \
  --vz-rosetta \
  --mount-type virtiofs
```

Adjust `--cpu` and `--memory` based on your Mac (e.g., 6/16 for Pro, 8/32 for Max).

| Option | Benefit |
|--------|---------|
| `--vm-type vz` | Apple Virtualization.framework (faster than QEMU) |
| `--mount-type virtiofs` | 5-10x faster file I/O than sshfs |
| `--vz-rosetta` | Run x86 containers via Rosetta |

Verify with `colima status` - should show "macOS Virtualization.Framework" and "virtiofs".

</details>

## Quick Start

Choose the pattern that fits your workflow:

### Pattern A: Per-Project Container (Isolated)

Each project gets its own container with independent volumes. Best for one-off reviews, untrusted repos, or when you need isolation between projects.

**Terminal:**

```bash
git clone <untrusted-repo>
cd untrusted-repo
devc init          # Installs template + starts container
devc shell      # Opens shell in container
```

**VS Code / Cursor:**

1. Install the Dev Containers extension:
   - VS Code: `ms-vscode-remote.remote-containers`
   - Cursor: `anysphere.remote-containers`

2. Set up the devcontainer (choose one):

   ```bash
   # Option A: Use devc (recommended)
   devc init

   # Option B: Clone manually
   git clone https://github.com/jason-hchsieh/claude-code-devcontainer .devcontainer/
   ```

3. Open **your project folder** in VS Code, then:
   - Press `Cmd+Shift+P` (Mac) or `Ctrl+Shift+P` (Windows/Linux)
   - Type "Reopen in Container" and select **Dev Containers: Reopen in Container**

### Pattern B: Shared Workspace Container (Grouped)

A parent directory contains the devcontainer config, and you clone multiple repos inside. Shared volumes across all repos. Best for client engagements, related repositories, or ongoing work.

```bash
# Create workspace for a client engagement
mkdir -p ~/sandbox/client-name
cd ~/sandbox/client-name
devc init          # Install template + start container
devc shell      # Opens shell in container

# Inside container:
git clone <client-repo-1>
git clone <client-repo-2>
cd client-repo-1
claude          # Ready to work
```

## Token-Based Auth (Headless)

For headless servers or to skip the interactive login wizard:

```bash
claude setup-token                          # run on host, one-time
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
devc rebuild                                # rebuilds with token
```

The token is forwarded into the container. On each container creation, `post_install.py` runs a one-shot auth handshake so `claude` starts without the login wizard.

This works around Claude Code's interactive onboarding wizard always showing in containers, even with valid credentials ([#8938](https://github.com/anthropics/claude-code/issues/8938)).

If you don't set a token, the interactive login flow works as before.

## CLI Helper Commands

```
devc init              Install template + start container in current directory
devc up             Start the devcontainer
devc rebuild        Rebuild container (preserves persistent volumes)
devc destroy [-f]   Remove container, volumes, and image for current project
devc down           Stop the container
devc shell          Open zsh shell in container
devc exec CMD       Execute command inside the container
devc upgrade        Upgrade Claude Code in the container
devc mount SRC DST  Add a bind mount (host → container)
devc sync [NAME]    Sync Claude Code sessions from devcontainers to host
devc template DIR   Copy devcontainer files to directory
devc self-install   Install devc to ~/.local/bin
devc self-update    Pull latest code and re-install devc
devc completion     Output shell completion script
```

> **Note:** Use `devc destroy` to clean up a project's Docker resources. Removing containers manually (e.g., `docker rm`) will leave orphaned volumes and images behind that `devc destroy` won't be able to find.

## Session Sync for `/insights`

Claude Code's `/insights` command analyzes your session history, but it only reads from `~/.claude/projects/` on the host. Sessions inside devcontainer volumes are invisible to it.

`devc sync` copies session logs from all devcontainers (running and stopped) to the host so `/insights` can include them:

```bash
devc sync              # Sync all devcontainers
devc sync crypto       # Filter by project name (substring match)
```

Devcontainers are auto-discovered via Docker labels — no need to know container names or IDs. The sync is incremental, so it's safe to run repeatedly.

## File Sharing

### VS Code / Cursor

Drag files from your host into the VS Code Explorer panel — they are copied into `/workspace/` automatically. No configuration needed.

### Terminal: `devc mount`

To make a host directory available inside the container:

```bash
devc mount ~/drop /drop           # Read-write
devc mount ~/secrets /secrets --readonly
```

This adds a bind mount to `devcontainer.json` and recreates the container. Existing mounts are preserved across `devc template` updates.

**Tip:** A shared "drop folder" is useful for passing files in without mounting your entire home directory.

> **Security note:** Avoid mounting large host directories (e.g., `$HOME`). Every mounted path is writable from inside the container unless `--readonly` is specified, which undermines the filesystem isolation this project provides.

## Network Isolation

By default, containers have full outbound network access. For stricter security, use iptables to restrict network access.

### When to Enable Network Isolation

- Reviewing code that may contain malicious dependencies
- Auditing software with telemetry or phone-home behavior
- Maximum isolation for highly sensitive reviews

### Example: Claude + GitHub + Package Registries

```bash
sudo iptables -A OUTPUT -d api.anthropic.com -j ACCEPT
sudo iptables -A OUTPUT -d github.com -j ACCEPT
sudo iptables -A OUTPUT -d raw.githubusercontent.com -j ACCEPT
sudo iptables -A OUTPUT -d registry.npmjs.org -j ACCEPT
sudo iptables -A OUTPUT -d pypi.org -j ACCEPT
sudo iptables -A OUTPUT -d files.pythonhosted.org -j ACCEPT
sudo iptables -A OUTPUT -o lo -j ACCEPT
sudo iptables -A OUTPUT -j DROP
```

### Trade-offs

- Blocks package managers unless you allowlist registries
- May break tools that require network access
- DNS resolution still works (consider blocking if paranoid)

## Security Model

This devcontainer provides **filesystem isolation** but not complete sandboxing.

**Sandboxed:** Filesystem (host files inaccessible), processes (isolated from host), package installations (stay in container)

**Not sandboxed:** Network (full outbound by default—see [Network Isolation](#network-isolation)), git identity (`~/.gitconfig` mounted read-only), Docker socket (not mounted by default)

The container auto-configures `bypassPermissions` mode—Claude runs commands without confirmation. This would be risky on a host machine, but the container itself is the sandbox.

## Container Details

| Component | Details |
|-----------|---------|
| Base | Ubuntu 24.04, Node.js 22, Python 3.13 + uv, zsh |
| User | `vscode` (passwordless sudo), working dir `/workspace` |
| Tools | `rg`, `fd`, `tmux`, `fzf`, `delta`, `iptables`, `ipset` |
| Volumes (survive rebuilds) | Command history (`/commandhistory`), Claude config (`~/.claude`), GitHub CLI auth (`~/.config/gh`) |
| Host mounts | `~/.gitconfig` (read-only), `.devcontainer/` (read-only) |
| Auto-configured | [anthropics](https://github.com/anthropics/claude-code-plugins) + [trailofbits](https://github.com/trailofbits/claude-code-plugins) skills, git-delta |

Volumes are stored outside the container, so your shell history, Claude settings, and `gh` login persist even after `devc rebuild`. Host `~/.gitconfig` is mounted read-only for git identity.

## Container Runtime

`devc` automatically detects available runtimes (Docker Desktop, OrbStack, Colima, Podman). When multiple runtimes are found, it prompts you to choose. If Docker is installed but requires `sudo`, it will be skipped with a helpful message.

To skip the prompt, set `CONTAINER_RUNTIME` explicitly:

```bash
export CONTAINER_RUNTIME=podman   # or: docker
```

### Using Podman

When Podman is selected, `devc` will automatically set `--docker-path podman` for the devcontainer CLI and configure `DOCKER_HOST` to point to the Podman socket (`unix:///run/user/<uid>/podman/podman.sock`) if it isn't already set.

## Troubleshooting

### "devcontainer CLI not found"

The `devc` CLI falls back to `npx @devcontainers/cli` automatically. If you don't have `npx`, install Node.js or install the CLI globally:

```bash
npm install -g @devcontainers/cli
```

### Container won't start

1. Check your container runtime is running (Docker, Podman, OrbStack, or Colima)
2. Try rebuilding: `devc rebuild`
3. Check logs: `docker logs $(docker ps -lq)` (or `podman logs $(podman ps -lq)`)

### GitHub CLI auth not persisting

The gh volume may need ownership fix:

```bash
sudo chown -R $(id -u):$(id -g) ~/.config/gh
```

### Python/uv not working

Python is managed via uv:

```bash
uv run script.py              # Run a script
uv add package                # Add project dependency
uv run --with requests py.py  # Ad-hoc dependency
```

## Development

Build the image manually:

```bash
npx @devcontainers/cli build --workspace-folder .
```

Test the container:

```bash
npx @devcontainers/cli up --workspace-folder .
npx @devcontainers/cli exec --workspace-folder . zsh
```
