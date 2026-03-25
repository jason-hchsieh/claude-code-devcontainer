# SSH Commit Signing in Devcontainer

**Date:** 2026-03-25
**Status:** Approved

## Problem

The host `~/.gitconfig` may have `commit.gpgsign=true` with `user.signingkey` pointing to a local file path (e.g. `/home/jasonhch/.ssh/id_ed25519.pub`). Inside the container, that path does not exist, so any `git commit` fails with:

```
error: Couldn't load public key /home/jasonhch/.ssh/id_ed25519.pub: No such file or directory
fatal: failed to write commit object
```

Not all users have signing configured, so the fix must be conditional.

## Goals

- Commits work (unsigned) in the container even when `devc ssh` has not been run
- Once `devc ssh` is run, commits are signed using the host SSH key via agent forwarding
- Users without signing configured are unaffected
- Private key never enters the container

## Non-Goals

- GPG (`gpg.format=openpgp`) signing support
- Signing without `devc ssh` (requires agent)

## Design

### Phase 1 — Container creation (`post_install.py`)

When generating `.gitconfig.local`, detect whether the host gitconfig has signing enabled with an unresolvable key path:

```
if commit.gpgsign == "true"
   AND user.signingkey looks like a file path
   AND that file does not exist in the container:
       append [commit] gpgsign = false to .gitconfig.local
```

This disables signing as a safe default, preventing the crash. Users without `commit.gpgsign=true` are untouched.

### Phase 2 — `devc ssh` (`install.sh`)

Add a `configure_git_signing` function called at the end of `cmd_ssh`, after `verify_ssh_agent` succeeds.

```
configure_git_signing():
    1. Read commit.gpgsign from host gitconfig
       → if not "true": return (user doesn't use signing)

    2. Read user.signingkey from host gitconfig
       → if empty: return

    3. Resolve public key string:
       → if value starts with "key::": use as-is
       → if value is a file path: read file content → prefix with "key::"

    4. Exec into container:
       git config --file ~/.gitconfig.local user.signingkey "key::ssh-ed25519 AAAA..."
       git config --file ~/.gitconfig.local commit.gpgsign true

    5. Log: "Git commit signing configured"
```

### Behavior Matrix

| Host config | `devc ssh` run? | Container behavior |
|---|---|---|
| No signing | — | Untouched |
| `gpgsign=true` | No | `gpgsign=false` override, unsigned commits |
| `gpgsign=true` | Yes | `key::` literal set, signed commits via agent |

## Security

- **Public key only** is written into `.gitconfig.local` (not sensitive)
- **Private key never enters the container** — signing operations go through `SSH_AUTH_SOCK` to the host agent
- **No new mounts** required in `devcontainer.json`
- **Idempotent** — re-running `devc ssh` safely overwrites the same config keys

## Files Changed

| File | Change |
|---|---|
| `post_install.py` | Conditionally add `[commit] gpgsign = false` when signing is enabled but key is unresolvable |
| `install.sh` | Add `configure_git_signing` function; call it at end of `cmd_ssh` |
