---
name: memory-wrapup
description: Process Codex session transcripts into Aria long-term memory. Auto-discovery is supported via the SessionEnd hook.
argument-hint: <optional transcript path>
---

Codex stores full rollout transcripts as JSONL under `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl` and indexes them in `~/.codex/state_*.sqlite` (`threads.rollout_path`).

The SessionEnd hook in this plugin (`hooks/session-end.sh`) **already resolves** rollout paths through:
- direct hook payload fields (`rollout_path`, `transcript_path`)
- session/thread id keys (`session_id`, `thread_id`, `conversation_id`)
- `CODEX_SESSION_ID` / `CODEX_THREAD_ID` / `CODEX_COMPANION_SESSION_ID` env
- `cwd`-based fallback against the state SQLite

Resolved paths are written to `meta.json.pendingWrapups`. **You usually do not need to find a transcript path manually.**

## Prerequisite

**Before executing**, Read `aria-memory/codex/references/memory-agent-spec.md` (canonical Aria memory operation spec). It defines:
- transcript JSONL parsing (Claude / Codex / dbclaw IM formats)
- impression file frontmatter and structure
- multi-source write architecture (`knowledge/.pending/{target}_{source_id}_{wrapup_id}_{ts}.md`)
- cross-fix rules and meta.json updates
- 11 hard rules (timestamps, format, multi-source safety, primary/secondary)

Codex has no plugin agent; you (the main model) execute the spec inline.

## Operation — pick the path

### A. Process pending wrapups (most common)

If startup context, `memory-status`, or the user reports pending wrapups:

```json
{
  "type": "session_wrapup",
  "memoryDir": "$HOME/.aria-memory",
  "processPending": true
}
```

Per spec §三 session_wrapup:

1. Read `~/.aria-memory/meta.json` → iterate `pendingWrapups[]` in recorded order.
2. For each entry, read `transcriptPath`. Skip and remove entries whose file no longer exists.
3. Run the single-wrapup flow (steps 1–7 in spec): parse transcript → build impression → write to `knowledge/.pending/` for existing knowledge files (multi-source write) → cross-fix old impressions → update meta.json → git commit.
4. Atomically write `meta.json` after each successful entry.

### B. User-supplied transcript path

If the user provides a rollout path (or you find one in `~/.codex/sessions/...`):

```json
{
  "type": "session_wrapup",
  "memoryDir": "$HOME/.aria-memory",
  "transcriptFile": "<verified rollout path>",
  "sessionDate": "$(date +%Y-%m-%d)"
}
```

Run the single-wrapup flow on that file.

### C. No transcript anywhere

Only if both `pendingWrapups` is empty AND you cannot resolve a rollout path:

Tell the user "Codex transcript discovery did not yield a rollout path for this session. If you want specific facts saved, use `/remember`." Do not invent transcripts.

## Multi-source safety

This skill writes to `knowledge/.pending/` (not directly to main knowledge files) when the target file already exists. The `source_id` for codex on this machine should be `sg-codex` (or your local convention). The next `global_sleep` on the primary endpoint will merge `.pending/` into main files using `wrapup_id` as the idempotency key.
