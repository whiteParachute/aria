---
name: memory-status
description: Show the current status of the shared Aria memory store from Codex.
---

Report status for `~/.aria-memory`.

## Prerequisite

This skill does not need the canonical spec — it only reads inventory. But familiarity with the spec helps interpret values (`pendingWrapups`, `lastGlobalSleepAt`, `.role`).

## Operation

1. Run `aria-memory/scripts/memory-status.sh` if available (under `${CODEX_PLUGIN_ROOT:-aria-memory}/scripts/memory-status.sh` or the local plugin checkout).
2. Otherwise inspect the store directly:

```bash
MEM=$HOME/.aria-memory
echo "=== Aria Memory Status ==="
echo "Role (claude):     $(cat $MEM/.role.claude 2>/dev/null || echo 'unset (treated as secondary)')"
echo "Role (codex):      $(cat $MEM/.role.codex 2>/dev/null || echo 'unset (treated as secondary)')"
echo "Index entries:     $(wc -l < $MEM/index.md 2>/dev/null || echo 0) lines"
echo "Knowledge files:   $(find $MEM/knowledge -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)"
echo "Pending merges:    $(find $MEM/knowledge/.pending -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)"
echo "Impressions:       $(find $MEM/impressions -maxdepth 1 -name '*.md' 2>/dev/null | wc -l) active / $(find $MEM/impressions/archived -maxdepth 1 -name '*.md' 2>/dev/null | wc -l) archived"
echo "Daily files:       $(find $MEM/daily -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)"
echo "Pending wrapups:   $(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("pendingWrapups",[])))' $MEM/meta.json 2>/dev/null || echo 0)"
echo "Last sleep:        $(cat $MEM/.last-sleep-at 2>/dev/null || python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("lastGlobalSleepAt") or "never")' $MEM/meta.json 2>/dev/null || echo 'never')"
echo "Index version:     $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("indexVersion",0))' $MEM/meta.json 2>/dev/null || echo 0)"
```

Present the output as a compact dashboard.

This workflow is Codex-supported and does not require transcript discovery.
