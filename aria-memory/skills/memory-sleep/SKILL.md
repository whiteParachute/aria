---
name: memory-sleep
description: |
  Trigger global memory maintenance (global_sleep). This performs index compaction,
  knowledge file splitting, cross-reference maintenance, and cleanup.
  Only needed periodically or when memory feels cluttered. Only valid on the primary endpoint.
allowed-tools: [Agent, Bash]
---

## Primary/secondary check (do this FIRST)

```bash
ROLE=$(cat $HOME/.aria-memory/.role.claude 2>/dev/null || echo secondary)
echo "Current runtime role: claude=$ROLE"
```

If `$ROLE != primary`, **stop immediately** and tell the user:

> Claude Code on this machine is `<role>`. Global maintenance runs only on the (runtime, machine) pair elected as primary (current convention: SG devbox claude code = primary). To run maintenance, switch to that endpoint and run `/memory-sleep` there. Run `/memory-status` here to see pending merges and last sleep watermark.

Do NOT call the memory-agent subagent on a non-primary endpoint.

## Operation (primary only)

Pass this request to the memory-agent subagent:

```json
{
  "type": "global_sleep",
  "memoryDir": "!`echo $HOME/.aria-memory`"
}
```

The memory-agent runs the 12-step global_sleep flow (per `aria-memory/agents/memory-agent.md` §四):

1. Backup `index.md` → `index.md.bak`
2. `.pending/` bloat check (warn at 50, alert at 100)
3. Merge `.pending/*.md` into target knowledge files (idempotent by `wrapup_id`)
4. Compact `index.md` (per-section caps)
5. Rebuild `index.md` from full impressions/ + knowledge/ scan
6. Archive impressions older than 6 months
7. Split / merge knowledge files; update See Also bidirectional links
8. Update `personality.md`
9. Update `meta.json`
10. Write `.last-sleep-at` (cross-machine watermark)
11. Generate / merge `daily/YYYY-MM-DD.md` (preserve user notes)
12. Append `changelog.md`

Report a summary of what was done.

## Why primary-only

Steps 1, 4, 5, 6, 7, 11, 12 all rewrite or move shared files. Two endpoints running this concurrently would cause git conflicts on index.md / changelog.md / daily files, ENOENT failures on impression archival, inconsistent split/merge results, and overwritten user notes in daily files. `session_wrapup` is safe on any endpoint (only adds to impressions/ and `.pending/`); maintenance is not.
