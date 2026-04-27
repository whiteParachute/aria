---
name: memory
description: Query the shared Aria long-term memory store from Codex. Use when the user asks about past conversations, stored preferences, project knowledge, or says "do you remember".
argument-hint: <query>
---

Query `~/.aria-memory` for the user's request.

## Prerequisite

**Before executing**, Read `aria-memory/codex/references/memory-agent-spec.md` (canonical Aria memory operation spec). It defines:
- memory directory layout, frontmatter rules
- query / remember / session_wrapup / global_sleep procedures
- index.md partition limits and self-repair rules
- 11 hard rules (timestamps, format, partition caps, primary/secondary)

Codex has no plugin agent; you (the main model) execute the spec inline using Read / Grep / Glob / Bash.

## Operation

After Reading the spec, execute a `query` request:

```json
{
  "type": "query",
  "memoryDir": "$HOME/.aria-memory",
  "query": "$ARGUMENTS",
  "context": "Project: $(pwd). Current date: $(date +%Y-%m-%d)"
}
```

Steps (per spec §一 query):

1. Read `~/.aria-memory/index.md` for quick references.
2. Search `~/.aria-memory/impressions/*.md`, then `~/.aria-memory/knowledge/*.md`, expand to `~/.aria-memory/impressions/archived/*.md` if nothing found.
3. Ignore `.git/` and `.obsidian/` in all searches.
4. Skip YAML frontmatter when interpreting facts.
5. Cite source filenames and dates. If no matching memory was found, say so directly.

Report concise findings to the user.
