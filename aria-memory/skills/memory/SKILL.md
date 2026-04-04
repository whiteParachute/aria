---
name: memory
description: |
  Query the long-term memory system. Use when the user asks about past conversations,
  previously discussed topics, stored preferences, or project knowledge from earlier sessions.
  TRIGGER when: user references past conversations, asks "do you remember", wants to recall
  something discussed before, or needs context from previous sessions.
argument-hint: <query>
allowed-tools: [Agent]
---

Use the memory-agent subagent to query long-term memory.

Pass this request to the memory-agent:

```json
{
  "type": "query",
  "memoryDir": "!`echo $HOME/.aria-memory`",
  "query": "$ARGUMENTS",
  "context": "User is in project: !`pwd`. Current date: !`date +%Y-%m-%d`"
}
```

Report the memory-agent's findings to the user concisely. If nothing was found, say so.
