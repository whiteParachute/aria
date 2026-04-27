---
name: memory-auto-maintain
description: |
  Set up automatic memory maintenance. Recommended for the primary endpoint:
  install a system cron entry that runs /memory-sleep every 6 hours via the
  bundled cron-memory-sleep.sh wrapper. Falls back to in-session /loop for
  ad-hoc cases.
allowed-tools: [Bash]
---

## Primary/secondary check (do this FIRST)

```bash
ROLE=$(cat $HOME/.aria-memory/.role.claude 2>/dev/null || echo secondary)
echo "Current runtime role: claude=$ROLE"
```

If `$ROLE != primary`, stop and tell the user:

> Auto-maintenance is reserved for the (runtime, machine) pair elected as primary. Set this up only there. Other runtimes / machines should run `session_wrapup` only.

## Recommended: system cron + bundled wrapper (durable, primary only)

The plugin ships `aria-memory/scripts/cron-memory-sleep.sh`. It self-disables when `.role.claude != primary`, holds a flock to prevent overlapping runs, sets `ARIA_MEMORY_CRON_RUN=1` so SessionEnd skips wrapup recording, redirects stdin from /dev/null so `claude -p` doesn't wait, and timeouts at 10 minutes.

Install (idempotent — replaces any prior aria-memory entry):

```bash
WRAPPER="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/aria-local/aria-memory}/scripts/cron-memory-sleep.sh"
test -x "$WRAPPER" || { echo "wrapper not found: $WRAPPER"; exit 1; }
( crontab -l 2>/dev/null | grep -v 'aria-memory.*memory-sleep'; \
  echo "37 */6 * * * $WRAPPER" ) | crontab -
crontab -l | grep memory-sleep
```

Verify it ran (after the next firing):

```bash
tail -30 $HOME/.aria-memory/.cron.log
cat $HOME/.aria-memory/.last-sleep-at
```

The wrapper logs to `~/.aria-memory/.cron.log` with 1MB rotation (`*.1`).

## Fallback: in-session /loop (session-scoped, ad-hoc)

For the duration of an interactive session you can also run `/loop 6h /memory-sleep`. This stops when the session ends and is mostly useful when you want maintenance to keep happening during a long working block without leaving cron behind.

## Removing auto-maintenance

```bash
crontab -l | grep -v 'aria-memory.*memory-sleep' | crontab -
```

Or set `.role.claude=secondary` — the wrapper will then exit silently every tick, leaving the cron entry harmless.
