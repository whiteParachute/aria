---
name: memory-wrapup
description: |
  Manually trigger session wrapup to process the current conversation into long-term memory.
  Use before ending a long or important session to ensure key information is captured.
  TRIGGER when: user says "save this session", "wrap up memory", or before ending an
  important conversation.
allowed-tools: [Agent, Read, Bash]
---

Trigger a manual session wrapup:

1. First check for already-recorded pending wrapups:

```bash
python3 - <<'PY'
import json, os
path = os.path.expanduser("~/.aria-memory/meta.json")
pending = []
if os.path.isfile(path):
    pending = json.load(open(path)).get("pendingWrapups", [])
print(len(pending))
PY
```

2. If the pending count is greater than 0, pass a process-pending request to
   the memory-agent subagent. This is the normal SessionEnd/cron drain path:

```json
{
  "type": "session_wrapup",
  "memoryDir": "!`echo $HOME/.aria-memory`",
  "processPending": true
}
```

3. If there are no pending wrapups, find the current session's transcript file.
   Check for recent JSONL files:

```bash
ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -5
```

4. Select the most recent transcript file that matches the current session.

5. Pass to memory-agent subagent:

```json
{
  "type": "session_wrapup",
  "memoryDir": "!`echo $HOME/.aria-memory`",
  "transcriptFile": "<path to the most recent transcript>",
  "sessionDate": "!`date +%Y-%m-%d`"
}
```

Report what was captured and stored.

Note: The memory-agent will produce impression files with YAML frontmatter and `[[wikilink]]` references,
update index.md using wikilink format, and append a changelog entry to changelog.md.
