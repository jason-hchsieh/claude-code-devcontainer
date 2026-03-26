# Version Update Check Design

## Summary

Add a synchronous version check to `devc` that notifies users when a newer version is available on the remote.

## Trigger Commands

`devc up`, `devc rebuild`, `devc shell` — the primary container interaction entry points.

Not triggered by: `exec`, `destroy`, `ssh`, `ssh-stop`, `sync`, `cp`, `mount`, `template`, `init`, `down`, `claude-update`, `update`, `self-install`, `completion`, `help`.

## Mechanism

1. Run `git -C "$SCRIPT_DIR" fetch origin --quiet` synchronously.
2. Count commits local is behind: `git -C "$SCRIPT_DIR" rev-list HEAD..origin/main --count`.
3. If behind > 0, print a single-line yellow warning before the command's normal output.
4. If fetch fails (no network, etc.), skip silently — never block the main command.

## Output Format

```
[devc] New version available (N commits behind). Run 'devc update' to upgrade.
```

Uses `$YELLOW` color, consistent with `log_warn`.

## Implementation

A single `check_for_updates()` function called at the top of `cmd_up`, `cmd_rebuild`, and `cmd_shell`.

## Non-goals

- No cooldown / caching — check runs every time on the trigger commands.
- No changelog display.
- No auto-update prompt.
