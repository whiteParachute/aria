---
name: remember
description: Store important user-provided information in the shared Aria long-term memory store from Codex.
argument-hint: <content to remember>
---

Store the content in `~/.aria-memory`.

## Prerequisite

**Before executing**, Read `aria-memory/codex/references/memory-agent-spec.md` (canonical Aria memory operation spec). It defines:
- knowledge file frontmatter template
- index.md partition rules and entry format (`- [YYYY-MM-DD] desc → [[file]]`)
- meta.json atomic update rules
- 11 hard rules (timestamps, format, etc.)

Codex has no plugin agent; you (the main model) execute the spec inline using Read / Write / Edit / Grep / Glob / Bash.

## Operation

After Reading the spec, execute a `remember` request:

```json
{
  "type": "remember",
  "memoryDir": "$HOME/.aria-memory",
  "content": "$ARGUMENTS",
  "importance": "normal",
  "context": "Project: $(pwd). Date: $(date +%Y-%m-%d)"
}
```

Steps (per spec §二 remember):

1. Classify content into a knowledge domain.
2. Choose or create a focused file under `~/.aria-memory/knowledge/`.
3. Preserve / add YAML frontmatter (`title`, `type: knowledge`, `created`, `updated`, `tags`, `confidence`).
4. Add or update one concise index entry in `~/.aria-memory/index.md`:

   ```text
   - [YYYY-MM-DD] short description → [[file-name]]
   ```

5. Update `meta.json` atomically (read full content, modify, write back).

Confirm what was stored and where.
