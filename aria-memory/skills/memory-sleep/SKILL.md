---
name: memory-sleep
description: |
  Trigger global memory maintenance (global_sleep). This performs index compaction,
  knowledge file splitting, cross-reference maintenance, and cleanup.
  Only needed periodically or when memory feels cluttered.
allowed-tools: [Agent]
---

Trigger global memory maintenance:

Pass this request to the memory-agent subagent:

```json
{
  "type": "global_sleep",
  "memoryDir": "!`echo $HOME/.aria-memory`"
}
```

This will perform the 9-step maintenance process:
1. Backup index.md
2. Compact index.md (capacity-based cleanup)
3. Expire old reminders and archive old impressions
4. Split/merge knowledge files
5. Self-audit index quality
6. Update personality.md
7. Update meta.json
8. Generate missing daily summaries (scan impressions by date, create missing daily/YYYY-MM-DD.md)
9. Append changelog.md

Report a summary of what was done.
