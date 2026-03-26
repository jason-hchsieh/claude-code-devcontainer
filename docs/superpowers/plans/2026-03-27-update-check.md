# Version Update Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notify users when a newer version of devc is available on the remote, on `devc up`, `devc rebuild`, and `devc shell`.

**Architecture:** A single `check_for_updates()` function that runs `git fetch` + `rev-list --count` to detect how many commits local is behind remote. Called at the top of the three trigger commands. Fetch failures are silently ignored.

**Tech Stack:** Bash, git

---

### Task 1: Add `check_for_updates` and wire it into trigger commands

**Files:**
- Modify: `install.sh:407-459` (add function before `cmd_up`, add calls to `cmd_up`, `cmd_rebuild`, `cmd_shell`)

- [ ] **Step 1: Add `check_for_updates()` function**

Insert before `cmd_up()` (line 407):

```bash
check_for_updates() {
  git -C "$SCRIPT_DIR" fetch origin --quiet 2>/dev/null || return 0
  local behind
  behind=$(git -C "$SCRIPT_DIR" rev-list HEAD..origin/main --count 2>/dev/null) || return 0
  if (( behind > 0 )); then
    log_warn "New version available ($behind commits behind). Run 'devc update' to upgrade."
  fi
}
```

- [ ] **Step 2: Add call at top of `cmd_up`**

Add `check_for_updates` as the first line of `cmd_up()`, before the workspace_folder variable:

```bash
cmd_up() {
  check_for_updates
  local workspace_folder
  ...
```

- [ ] **Step 3: Add call at top of `cmd_rebuild`**

```bash
cmd_rebuild() {
  check_for_updates
  local workspace_folder
  ...
```

- [ ] **Step 4: Add call at top of `cmd_shell`**

```bash
cmd_shell() {
  check_for_updates
  local workspace_folder
  ...
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n install.sh`
Expected: no output (clean syntax)

- [ ] **Step 6: Manual smoke test**

Run: `bash install.sh help`
Expected: help output prints normally, no update check (help is not a trigger command).

- [ ] **Step 7: Commit**

```bash
git add install.sh
git commit -m "feat(devc): check for updates on up/rebuild/shell"
```
