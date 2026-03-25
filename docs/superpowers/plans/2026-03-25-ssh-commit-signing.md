# SSH Commit Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable SSH commit signing inside the devcontainer via agent forwarding, with a safe unsigned-commit fallback when the agent isn't set up.

**Architecture:** Two-phase approach — `post_install.py` detects whether the host gitconfig uses SSH signing with a file-path key that can't be resolved inside the container and disables signing as a safe default; `devc ssh` re-enables signing by embedding the literal public key into `.gitconfig.local` via container exec, so the private key never enters the container.

**Tech Stack:** Python 3 (`post_install.py`), Bash (`install.sh`), `git config`, `devcontainer exec`

**Spec:** `docs/superpowers/specs/2026-03-25-ssh-commit-signing-design.md`

---

## File Map

| File | Change |
|---|---|
| `post_install.py` | In `setup_global_gitignore()`: detect host SSH signing config; conditionally append `[commit] gpgsign = false` to `.gitconfig.local` on first creation only |
| `install.sh` | Add `configure_git_signing()` function; call it inside `cmd_ssh()` only when `verify_ssh_agent` succeeds |

**Constraint:** `post_install.py` skips `.gitconfig.local` creation if the file already exists (line 260). The signing override is therefore only written on first container creation. Subsequent rebuilds without deleting the file will not update it — this is intentional: `configure_git_signing` (in `devc ssh`) handles re-enabling signing after the fact.

---

## Task 1: `post_install.py` — safe default for signing

**Files:**
- Modify: `post_install.py` (function `setup_global_gitignore`, around line 258)

The host gitconfig is mounted at `/home/vscode/.gitconfig`. If it has `commit.gpgsign=true` with a `user.signingkey` that is a file path not present in the container, commits will crash. We add `gpgsign = false` after the `[include]` to prevent that. This only runs on first container creation.

- [ ] **Step 1: Read the current `setup_global_gitignore` function**

  Open `post_install.py`, read lines 197–296. Note:
  - `host_gitconfig = home / ".gitconfig"` — the mounted host config
  - `local_gitconfig` is written once; skipped if exists (line 260)
  - `subprocess` is already imported at module level (line 14) — do **not** add another import
  - The template string ends with `[gpg "ssh"]\n    program = /usr/bin/ssh-keygen\n`

- [ ] **Step 2: Add helper `_host_signing_needs_override` immediately before `setup_global_gitignore`**

  ```python
  def _host_signing_needs_override(host_gitconfig: Path) -> bool:
      """Return True if host gitconfig uses SSH signing with a file-path key
      that won't be resolvable inside the container."""
      def git_cfg(key: str) -> str:
          result = subprocess.run(
              ["git", "config", "--file", str(host_gitconfig), key],
              capture_output=True, text=True
          )
          return result.stdout.strip()

      if git_cfg("commit.gpgsign").lower() != "true":
          return False
      signing_key = git_cfg("user.signingkey")
      if not signing_key:
          return False
      # key:: prefix means it's a literal — already resolvable, no override needed
      if signing_key.startswith("key::"):
          return False
      # Otherwise treat as a file path; check if it exists in the container
      return not Path(signing_key).exists()
  ```

- [ ] **Step 3: Update the `local_config` template to conditionally append the signing override**

  Replace the block that builds `local_config` and writes it (lines 264–293) with:

  ```python
      signing_override = ""
      if _host_signing_needs_override(host_gitconfig):
          signing_override = "\n[commit]\n    gpgsign = false\n"
          print(
              "[post_install] Host uses SSH signing with unresolvable key path — "
              "disabling gpgsign in container (run 'devc ssh' to re-enable)",
              file=sys.stderr,
          )

      local_config = f"""\
  # Container-local git config
  # Includes host config (mounted read-only) and adds container settings

  [include]
      path = {host_gitconfig}

  [core]
      excludesfile = {gitignore}
      pager = delta

  [interactive]
      diffFilter = delta --color-only

  [delta]
      navigate = true
      light = false
      line-numbers = true
      side-by-side = false

  [merge]
      conflictstyle = diff3

  [diff]
      colorMoved = default

  [gpg "ssh"]
      program = /usr/bin/ssh-keygen
  {signing_override}"""
      local_gitconfig.write_text(local_config, encoding="utf-8")
  ```

- [ ] **Step 4: Manual smoke test**

  Trace through `_host_signing_needs_override` mentally (or in a Python shell with `host_gitconfig` pointing to `~/.gitconfig`):
  - Host has `commit.gpgsign=true`, `user.signingkey=/home/jasonhch/.ssh/id_ed25519.pub` → returns `True` (path doesn't exist in container)
  - Host has no signing config → returns `False`
  - Host has `user.signingkey=key::ssh-ed25519 AAAA...` → returns `False`

- [ ] **Step 5: Commit**

  ```bash
  git add post_install.py
  git commit -m "fix(post_install): disable gpgsign when SSH signing key path unresolvable in container"
  ```

---

## Task 2: `install.sh` — `configure_git_signing` function

**Files:**
- Modify: `install.sh` (add new function after `verify_ssh_agent`, ~line 651; update `cmd_ssh` tail, ~line 728)

This function runs on the **host**. It reads the signing key from the host gitconfig, validates it is a public key, resolves the content, and uses `devcontainer exec` to write it into `.gitconfig.local` inside the container. It uses the same exec pattern as `verify_ssh_agent`.

- [ ] **Step 1: Read `verify_ssh_agent` (lines 601–651) and `cmd_ssh` (lines 653–729)**

  Note the exec pattern:
  ```bash
  "${DEVCONTAINER_CMD[@]}" exec ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} \
    --workspace-folder "$workspace_folder" \
    <command>
  ```
  Also note `verify_ssh_agent` returns `0` early when the container isn't running — `configure_git_signing` does the same.

- [ ] **Step 2: Add `configure_git_signing` after `verify_ssh_agent` (after line 651)**

  ```bash
  # Configure git commit signing inside the container using the host SSH key.
  # Reads the host gitconfig's signingkey, resolves the public key content,
  # and writes user.signingkey + commit.gpgsign into .gitconfig.local via exec.
  # No-ops silently if the host does not have SSH signing configured.
  configure_git_signing() {
    local workspace_folder="$1"

    # Skip if host does not have commit signing enabled
    local gpgsign
    gpgsign=$(git config --global commit.gpgsign 2>/dev/null || true)
    if [[ "${gpgsign,,}" != "true" ]]; then
      return 0
    fi

    # Skip if no signing key configured
    local signing_key
    signing_key=$(git config --global user.signingkey 2>/dev/null || true)
    if [[ -z "$signing_key" ]]; then
      return 0
    fi

    # Resolve public key content
    local key_literal
    if [[ "$signing_key" == key::* ]]; then
      # Already a literal key
      key_literal="$signing_key"
    elif [[ -f "$signing_key" ]]; then
      # Validate it looks like a public key before reading
      # (guards against user.signingkey accidentally pointing to a private key)
      local first_line
      first_line=$(head -1 "$signing_key")
      if ! echo "$first_line" | grep -qE '^(ssh-|ecdsa-|sk-)'; then
        log_warn "Signing key $signing_key does not appear to be a public key — skipping signing config"
        return 0
      fi
      key_literal="key::${first_line}"
    else
      log_warn "SSH signing key not found: $signing_key — skipping signing config"
      return 0
    fi

    # Check container is running
    local label="devcontainer.local_folder=$workspace_folder"
    local container_id
    container_id=$($CONTAINER_RUNTIME ps -q --filter "label=$label" 2>/dev/null || true)
    if [[ -z "$container_id" ]]; then
      return 0
    fi

    # Resolve container home directory dynamically (container user may not be vscode)
    local container_home
    container_home=$("${DEVCONTAINER_CMD[@]}" exec ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} \
      --workspace-folder "$workspace_folder" \
      sh -c 'echo $HOME' 2>/dev/null || echo "/home/vscode")

    local gitconfig_local="${container_home}/.gitconfig.local"

    # Write signing key and re-enable gpgsign in .gitconfig.local
    "${DEVCONTAINER_CMD[@]}" exec ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} \
      --workspace-folder "$workspace_folder" \
      git config --file "$gitconfig_local" user.signingkey "$key_literal" 2>/dev/null

    "${DEVCONTAINER_CMD[@]}" exec ${DOCKER_PATH_ARGS[@]+"${DOCKER_PATH_ARGS[@]}"} \
      --workspace-folder "$workspace_folder" \
      git config --file "$gitconfig_local" commit.gpgsign true 2>/dev/null

    log_success "Git commit signing configured (key: ${signing_key##*/})"
  }
  ```

- [ ] **Step 3: Call `configure_git_signing` in `cmd_ssh` only when `verify_ssh_agent` succeeds**

  Locate the end of `cmd_ssh` (lines 727–729):
  ```bash
    # Verify SSH agent inside container
    verify_ssh_agent "$workspace_folder"
  }
  ```

  Replace with:
  ```bash
    # Verify SSH agent inside container; configure signing only if agent is reachable
    if verify_ssh_agent "$workspace_folder"; then
      configure_git_signing "$workspace_folder"
    fi
  }
  ```

- [ ] **Step 4: Manual tests**

  a. Happy path — run `devc ssh` with SSH agent loaded:
  ```bash
  # In container after devc ssh:
  git config --global user.signingkey   # expect: key::ssh-ed25519 AAAA...
  git config --global commit.gpgsign    # expect: true
  git commit --allow-empty -m "test: signed commit"
  git log --show-signature -1           # expect: Good "git" signature
  ```

  b. No signing config — on a machine without `commit.gpgsign=true`, run `devc ssh`:
  ```bash
  # In container after devc ssh:
  git config --global user.signingkey   # expect: (empty or host value unchanged)
  git config --global commit.gpgsign    # expect: (empty or false, unchanged)
  ```

  c. Agent unreachable — simulate by killing the SSH agent, then running `devc ssh`:
  ```bash
  # Expect: verify_ssh_agent fails, configure_git_signing is NOT called,
  # .gitconfig.local is NOT modified (gpgsign stays false)
  cat ~/.gitconfig.local | grep gpgsign  # expect: gpgsign = false (unchanged)
  ```

- [ ] **Step 5: Commit**

  ```bash
  git add install.sh
  git commit -m "feat(ssh): configure git commit signing via SSH agent forwarding"
  ```

---

## Task 3: End-to-end verification

- [ ] **Step 1: Rebuild container from scratch**

  Delete `.gitconfig.local` inside the container (or rebuild), then check:
  ```bash
  cat ~/.gitconfig.local
  ```
  Expect: `[commit]\n    gpgsign = false` present (if host has signing); absent otherwise.

- [ ] **Step 2: Commit before `devc ssh` — unsigned**

  ```bash
  git commit --allow-empty -m "test: unsigned commit"
  git log --show-signature -1   # expect: no signature, commit succeeds
  ```

- [ ] **Step 3: Run `devc ssh`, then commit — signed**

  ```bash
  # On host:
  devc ssh

  # In container:
  git commit --allow-empty -m "test: signed commit"
  git log --show-signature -1   # expect: Good "git" signature for ...
  ```

- [ ] **Step 4: Final cleanup commit if needed**

  ```bash
  git status
  # Commit any stray changes
  ```
