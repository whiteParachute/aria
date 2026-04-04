---
name: memory-status
description: |
  Show the current status of the memory system: file counts, index size,
  last maintenance time, pending wrapups, etc.
allowed-tools: [Read, Glob, Bash]
---

Read and report memory system status:

1. Read meta.json:

```bash
cat "$HOME/.aria-memory/meta.json" 2>/dev/null || echo '{"error": "meta.json not found"}'
```

2. Count knowledge files:

```bash
find "$HOME/.aria-memory/knowledge" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l
```

3. Count impression files (active and archived):

```bash
echo "Active: $(find "$HOME/.aria-memory/impressions" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l)"
echo "Archived: $(find "$HOME/.aria-memory/impressions/archived" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l)"
```

4. Index size:

```bash
wc -l "$HOME/.aria-memory/index.md" 2>/dev/null
```

5. Read meta.json for last maintenance time and pending wrapups count.

Present a concise status dashboard like:

```
=== Aria Memory Status ===
Index entries:     XX lines
Knowledge files:   XX
Impressions:       XX active / XX archived
Pending wrapups:   XX
Last maintenance:  YYYY-MM-DD HH:MM (XX hours ago)
Index version:     XX
```
