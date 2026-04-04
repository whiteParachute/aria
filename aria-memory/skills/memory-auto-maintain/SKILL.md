---
name: memory-auto-maintain
description: |
  Set up automatic memory maintenance using /loop. Creates a recurring
  loop that triggers /memory-sleep periodically.
allowed-tools: [Bash]
---

Set up automatic memory maintenance using the /loop feature:

Run `/loop 6h /memory-sleep` to create a recurring loop that triggers global memory maintenance every 6 hours.

Check when the last global_sleep was run:

```bash
cat "$HOME/.aria-memory/meta.json" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('lastGlobalSleepAt','never'))" 2>/dev/null || echo "never"
```

Note: /loop is session-scoped — it will stop when the session ends. Next SessionStart will remind to set it up again if needed.
