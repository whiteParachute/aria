---
name: memory-auto-maintain
description: |
  Set up automatic memory maintenance using /loop. Creates a recurring
  loop that triggers /memory-sleep periodically. Only valid on the primary endpoint.
allowed-tools: [Bash]
---

## Primary/secondary check (do this FIRST)

```bash
ROLE=$(cat $HOME/.aria-memory/.role.claude 2>/dev/null || echo secondary)
echo "Current runtime role: claude=$ROLE"
```

If `$ROLE != primary`, stop and tell the user:

> Auto-maintenance is reserved for the (runtime, machine) pair elected as primary. Set this up only there. Other runtimes / machines should run `session_wrapup` only (which is safe across all endpoints by multi-source write architecture).

## Setup (primary only)

Run `/loop 6h /memory-sleep` to create a recurring loop that triggers global memory maintenance every 6 hours.

Check when the last global_sleep was run:

```bash
cat "$HOME/.aria-memory/.last-sleep-at" 2>/dev/null \
  || python3 -c "import sys,json; print(json.load(open('$HOME/.aria-memory/meta.json')).get('lastGlobalSleepAt','never'))" 2>/dev/null \
  || echo "never"
```

Note: `/loop` is session-scoped — it stops when the session ends. The SessionStart hook will remind you to set it up again on the primary endpoint if maintenance falls behind. For durable scheduling across sessions / machine reboots, use a system cron entry on the primary side instead:

```bash
( crontab -l 2>/dev/null | grep -v 'aria-memory.*memory-sleep'; \
  echo '37 */6 * * * /usr/local/bin/claude code -p "/memory-sleep" >> $HOME/.aria-memory/.cron.log 2>&1' \
) | crontab -
```

(Adjust the `claude` binary path for your install.)
