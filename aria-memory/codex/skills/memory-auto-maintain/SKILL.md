---
name: memory-auto-maintain
description: Set up automatic Aria memory maintenance on Codex. Only valid on the primary endpoint.
---

Codex has no in-session `/loop` equivalent for indefinite recurring tasks, so this skill uses a system-level scheduler (cron or systemd-timer) plus `codex exec`.

## Primary/secondary check

```bash
ROLE=$(cat $HOME/.aria-memory/.role.codex 2>/dev/null || echo secondary)
echo "Current runtime role: codex=$ROLE"
```

If `$ROLE != primary`, stop and tell the user:

> Auto-maintenance is reserved for the (runtime, machine) pair elected as primary. Set this up only there. Other runtimes / machines should run `session_wrapup` only.

## Setup options (primary only)

### Option A: cron (simplest, recommended)

Add a crontab entry that runs `codex exec '/memory-sleep'` every 6 hours (offset minute to avoid `:00`):

```bash
( crontab -l 2>/dev/null | grep -v 'aria-memory.*memory-sleep'; \
  echo "37 */6 * * * /usr/bin/codex exec --skip-git-repo-check '/memory-sleep' >> $HOME/.aria-memory/.cron.log 2>&1" \
) | crontab -
```

Verify:

```bash
crontab -l | grep memory-sleep
```

### Option B: systemd user timer (if cron is unavailable)

Create `~/.config/systemd/user/aria-memory-sleep.{service,timer}` running `codex exec '/memory-sleep'` every 6 hours.

(Skip; cron is preferred unless the user explicitly requires systemd.)

### Option C: in-session `omx ralph` (foreground, dev only)

If the user wants in-session live maintenance during long working blocks, `omx ralph` can wrap a recurring task — but this consumes a Codex pane and is not durable across sessions. Recommend only for ad-hoc cases.

## What runs on each tick

`codex exec --skip-git-repo-check '/memory-sleep'` launches a non-interactive Codex session that:
1. Reads `aria-memory/codex/skills/memory-sleep/SKILL.md`
2. Performs the primary/secondary check
3. Reads the spec (`codex/references/memory-agent-spec.md`)
4. Executes the 12-step global_sleep flow
5. Exits

Output goes to `~/.aria-memory/.cron.log` (option A) or systemd journal (option B).

## Verifying it's running

```bash
tail -50 $HOME/.aria-memory/.cron.log
cat $HOME/.aria-memory/.last-sleep-at  # should be < 6h ago
```

## Caveat — codex routine availability

As of codex-cli 0.125.0 there is no first-party "routine" / in-runtime scheduler for plugins. If a future version adds one, prefer it over cron and update this skill.
