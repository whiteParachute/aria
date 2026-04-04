---
name: remember
description: |
  Store information in long-term memory. Use when the user explicitly asks to remember
  something, or when important information is shared that should persist across sessions.
  TRIGGER when: user says "remember this", "store this", "save this for later", or shares
  critical project/personal information.
argument-hint: <content to remember>
allowed-tools: [Agent]
---

Use the memory-agent subagent to store this information.

Pass this request to the memory-agent:

```json
{
  "type": "remember",
  "memoryDir": "!`echo $HOME/.aria-memory`",
  "content": "$ARGUMENTS",
  "importance": "normal",
  "context": "Project: !`pwd`. Date: !`date +%Y-%m-%d`"
}
```

Confirm to the user that the information has been stored.
