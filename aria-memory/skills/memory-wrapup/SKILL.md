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

1. Find the current session's transcript file. Check for recent JSONL files:

```bash
ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -5
```

2. Select the most recent transcript file that matches the current session.

3. Pass to memory-agent subagent:

```json
{
  "type": "session_wrapup",
  "memoryDir": "!`echo $HOME/.aria-memory`",
  "transcriptFile": "<path to the most recent transcript>",
  "sessionDate": "!`date +%Y-%m-%d`"
}
```

Report what was captured and stored.
