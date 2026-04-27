---
name: memory-sleep
description: Run global Aria memory maintenance (12-step rebuild) from Codex. Only valid on the primary endpoint.
---

Trigger global maintenance for `~/.aria-memory`.

## Primary/secondary check (do this FIRST)

Before any other step:

```bash
ROLE=$(cat $HOME/.aria-memory/.role.codex 2>/dev/null || echo secondary)
echo "Current runtime role: codex=$ROLE"
```

If `$ROLE != primary`, **stop immediately** and tell the user:

> Codex on this machine is `<role>`. Global maintenance runs only on the (runtime, machine) pair elected as primary (current convention: SG devbox claude code = primary; codex on the same machine is secondary). To run maintenance, switch to that endpoint and run `/memory-sleep` there. Run `/memory-status` here to see pending merges and last sleep watermark.

Do NOT run any of the steps below on a non-primary endpoint.

## Prerequisite (primary only)

**Before executing**, Read `aria-memory/codex/references/memory-agent-spec.md` (canonical Aria memory operation spec), specifically §四 global_sleep — the 12-step flow. It defines:
- `.pending/` merge with idempotency keys (`target` + `wrapup_id`)
- index.md backup, compaction, rebuild
- impression archival (>6 months)
- knowledge split/merge + See Also bidirectional links
- personality.md update
- `.last-sleep-at` cross-machine watermark
- daily file generation with `<!-- aria:user-start/end -->` user-handwritten preservation
- changelog quarterly archival (>500 lines)

Codex has no plugin agent; you (the main model) execute the spec inline.

## Operation

After Reading the spec, execute a `global_sleep` request:

```json
{
  "type": "global_sleep",
  "memoryDir": "$HOME/.aria-memory"
}
```

Run all 12 steps in order (do not skip — each step has dependencies on prior state):

1. Backup `index.md` → `index.md.bak`
2. `.pending/` bloat check (warn at 50, alert at 100)
3. Merge `.pending/*.md` into target knowledge files (idempotent by `wrapup_id`)
4. Compact `index.md` (per-section caps: 关于用户 30 / 活跃话题 50 / 重要提醒 20 / 近期上下文 50 / 备用 50)
5. Rebuild `index.md` from full impressions/ + knowledge/ scan (wikilink format)
6. Archive impressions older than 6 months to `impressions/archived/`
7. Split (>200 lines) / merge (<10 lines) knowledge files; update See Also bidirectional links
8. Update `personality.md` from impression sentiment markers
9. Update `meta.json` (lastGlobalSleepAt, indexVersion, totals)
10. Write `.last-sleep-at` (cross-machine watermark, git-tracked)
11. Generate / merge `daily/YYYY-MM-DD.md` files (preserve user notes between `<!-- aria:user-start -->` and `<!-- aria:user-end -->`)
12. Append changelog.md (archive to `changelog-YYYY-Qn.md` if main exceeds 500 lines)

Report a summary of what was done in each step.

## Why primary-only

Steps 1, 4, 5, 6, 7, 11, 12 all rewrite or move shared files. Two endpoints running this concurrently would cause:
- Git push conflicts on index.md / changelog.md / daily files
- ENOENT failures when both try to `mv` the same impression to archived/
- Inconsistent split/merge results when one side splits a file the other side has `.pending/` entries for
- Overwriting user notes in daily files

`session_wrapup` is safe to run on any endpoint (it only adds new impression files and writes to `.pending/`); maintenance is not.
