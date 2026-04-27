#!/bin/bash
# SessionEnd hook: record transcript path for deferred wrapup at next SessionStart

set -euo pipefail

INPUT=$(cat)
MEMORY_DIR="$HOME/.aria-memory"
RUNTIME="${ARIA_MEMORY_RUNTIME:-}"
if [ -z "$RUNTIME" ]; then
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    RUNTIME="claude"
  elif [ -n "${CODEX_PLUGIN_ROOT:-}${CODEX_PLUGIN_DIR:-}${CODEX_PLUGIN_PATH:-}" ]; then
    RUNTIME="codex"
  else
    RUNTIME="unknown"
  fi
fi

if [ ! -d "$MEMORY_DIR" ]; then
  exit 0
fi

# Cron-driven /memory-sleep runs invoke claude -p, which would otherwise be
# recorded as a tiny "session" worth wrapping up. Skip transcript discovery
# and pendingWrapups recording for those, but still let the git sync block
# below push any state the sleep produced.
if [ -n "${ARIA_MEMORY_CRON_RUN:-}" ]; then
  TRANSCRIPT_PATH=""
else

# Resolve transcript path by runtime. Keep Claude and Codex contracts separate.
if [ "$RUNTIME" = "codex" ]; then
  TRANSCRIPT_PATH=$(ARIA_MEMORY_HOOK_INPUT="$INPUT" python3 - "$HOME" <<'PYEOF' 2>/dev/null || true
import json
import os
import sqlite3
import sys

home = sys.argv[1]
raw = os.environ.get("ARIA_MEMORY_HOOK_INPUT", "")
try:
    payload = json.loads(raw or "{}")
except Exception:
    payload = {}

direct_path_keys = {"rollout_path", "rolloutPath", "transcript_path", "transcriptPath"}
id_keys = {
    "session_id",
    "sessionId",
    "thread_id",
    "threadId",
    "conversation_id",
    "conversationId",
    "id",
}
cwd_keys = {"cwd", "working_directory", "workingDirectory"}

paths = []
ids = []
cwds = []

def walk(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key in direct_path_keys and isinstance(item, str):
                paths.append(item)
            elif key in id_keys and isinstance(item, str):
                ids.append(item)
            elif key in cwd_keys and isinstance(item, str):
                cwds.append(item)
            walk(item)
    elif isinstance(value, list):
        for item in value:
            walk(item)

walk(payload)

for env_key in (
    "CODEX_SESSION_ID",
    "CODEX_THREAD_ID",
    "CODEX_COMPANION_SESSION_ID",
):
    value = os.environ.get(env_key)
    if value:
        ids.append(value)

for path in paths:
    expanded = os.path.expanduser(path)
    if os.path.isfile(expanded):
        print(expanded)
        raise SystemExit(0)

codex_dir = os.environ.get("CODEX_HOME") or os.path.join(home, ".codex")
state_paths = [
    os.path.join(codex_dir, name)
    for name in sorted(os.listdir(codex_dir), reverse=True)
    if name.startswith("state_") and name.endswith(".sqlite")
] if os.path.isdir(codex_dir) else []

def query_one(sql, params=()):
    for db_path in state_paths:
        try:
            conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=0.2)
            try:
                row = conn.execute(sql, params).fetchone()
            finally:
                conn.close()
        except Exception:
            continue
        if row and row[0] and os.path.isfile(row[0]):
            return row[0]
    return None

for thread_id in ids:
    result = query_one("select rollout_path from threads where id = ? limit 1", (thread_id,))
    if result:
        print(result)
        raise SystemExit(0)

# Last-resort Codex fallback for hook payloads that include cwd but no thread id.
# Restrict to top-level CLI threads to avoid recording subagent rollout files.
for cwd in cwds:
    result = query_one(
        """
        select rollout_path
          from threads
         where cwd = ?
           and source = 'cli'
           and (agent_path is null or agent_path = '')
         order by updated_at_ms desc, updated_at desc
         limit 1
        """,
        (cwd,),
    )
    if result:
        print(result)
        raise SystemExit(0)
PYEOF
  )
elif [ "$RUNTIME" = "claude" ]; then
  TRANSCRIPT_PATH=$(ARIA_MEMORY_HOOK_INPUT="$INPUT" python3 - <<'PYEOF' 2>/dev/null || true
import json
import os

raw = os.environ.get("ARIA_MEMORY_HOOK_INPUT", "")
try:
    payload = json.loads(raw or "{}")
except Exception:
    payload = {}

path = ""
if isinstance(payload, dict):
    path = payload.get("transcript_path") or payload.get("transcriptPath") or ""
if isinstance(path, str):
    expanded = os.path.expanduser(path)
    if os.path.isfile(expanded):
        print(expanded)
PYEOF
  )
else
  TRANSCRIPT_PATH=$(ARIA_MEMORY_HOOK_INPUT="$INPUT" python3 - <<'PYEOF' 2>/dev/null || true
import json
import os

raw = os.environ.get("ARIA_MEMORY_HOOK_INPUT", "")
try:
    payload = json.loads(raw or "{}")
except Exception:
    payload = {}

path = ""
if isinstance(payload, dict):
    path = payload.get("transcript_path") or payload.get("transcriptPath") or ""
if isinstance(path, str):
    expanded = os.path.expanduser(path)
    if os.path.isfile(expanded):
        print(expanded)
PYEOF
  )
fi
fi  # end ARIA_MEMORY_CRON_RUN guard (TRANSCRIPT_PATH=""for cron, otherwise resolve normally)

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Skip subagent transcripts — only record user-facing sessions
  if echo "$TRANSCRIPT_PATH" | grep -qE '/(agent|subagent)/'; then
    TRANSCRIPT_PATH=""
  fi
fi

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Heuristic: skip very small transcripts (< 5 lines) likely from subagent sessions
  LINE_COUNT=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
  if [ "$LINE_COUNT" -lt 5 ]; then
    TRANSCRIPT_PATH=""
  fi
fi

# Add to pendingWrapups in meta.json when a transcript can be resolved.
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] && [ -f "$MEMORY_DIR/meta.json" ]; then
  python3 - "$MEMORY_DIR/meta.json" "$TRANSCRIPT_PATH" << 'PYEOF'
import json, sys, os, tempfile
from datetime import datetime, timezone

meta_path = sys.argv[1]
transcript_path = sys.argv[2]

with open(meta_path) as f:
    meta = json.load(f)

pending = meta.get('pendingWrapups', [])
entry = {
    'transcriptPath': transcript_path,
    'recordedAt': datetime.now(timezone.utc).isoformat(),
    'trigger': 'session_end'
}

# Avoid duplicates (same transcript path)
if not any(p.get('transcriptPath') == transcript_path for p in pending):
    pending.append(entry)
    meta['pendingWrapups'] = pending
    # Atomic write: write to temp file then rename
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(meta_path), suffix='.tmp')
    with os.fdopen(fd, 'w') as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
    os.replace(tmp, meta_path)
PYEOF
fi

# === Git sync: commit and push with retry (max 3 attempts) ===
if [ -d "$MEMORY_DIR/.git" ]; then
  (
    cd "$MEMORY_DIR"
    # Do NOT clear the failure marker up-front: if working tree is clean and we
    # never even try a sync, the previous failure is still unresolved and the
    # marker is the only signal the next SessionStart shows the user. The marker
    # is cleared only after a successful push below.
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git add -A
      COMMIT_ERR=$(git commit -m "sync: session wrapup $(date +%Y-%m-%d_%H:%M)" 2>&1) || {
        # Commit itself failed — record the real error, don't mask as push failure
        echo "Failed at: $(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > "$MEMORY_DIR/.git-push-failed"
        echo "Stage: git commit" >> "$MEMORY_DIR/.git-push-failed"
        echo "Error: $COMMIT_ERR" >> "$MEMORY_DIR/.git-push-failed"
        exit 0
      }

      # Push with retry: pull --rebase on failure, max 3 attempts
      PUSH_OK=0
      LAST_ERR=""
      for ATTEMPT in 1 2 3; do
        LAST_ERR=$(git push origin main 2>&1) && { PUSH_OK=1; break; }
        # Pull with rebase before retry
        REBASE_ERR=$(git pull --rebase origin main 2>&1) || {
          # Rebase failed (conflict) — abort and record
          git rebase --abort 2>/dev/null || true
          LAST_ERR="pull --rebase failed: $REBASE_ERR"
          break
        }
      done

      if [ "$PUSH_OK" -eq 1 ]; then
        # Clear any previous failure marker on success
        rm -f "$MEMORY_DIR/.git-push-failed"
      else
        # Write marker file with accurate stage info
        echo "Failed at: $(date -u +%Y-%m-%dT%H:%M:%S+00:00)" > "$MEMORY_DIR/.git-push-failed"
        echo "Stage: git push (after $ATTEMPT attempts)" >> "$MEMORY_DIR/.git-push-failed"
        echo "Last error: $LAST_ERR" >> "$MEMORY_DIR/.git-push-failed"
        echo "Working dir: $(pwd)" >> "$MEMORY_DIR/.git-push-failed"
        echo "Git status:" >> "$MEMORY_DIR/.git-push-failed"
        git status --short >> "$MEMORY_DIR/.git-push-failed" 2>/dev/null
      fi
    fi
  ) || true
fi

exit 0
