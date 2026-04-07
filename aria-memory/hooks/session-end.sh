#!/bin/bash
# SessionEnd hook: record transcript path for deferred wrapup at next SessionStart

set -euo pipefail

INPUT=$(cat)
MEMORY_DIR="$HOME/.aria-memory"

if [ ! -d "$MEMORY_DIR" ]; then
  exit 0
fi

# Extract transcript_path from hook input JSON
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null || echo "")

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# Skip subagent transcripts — only record user-facing sessions
# Subagent transcripts are typically short and located outside the main project directory pattern
BASENAME=$(basename "$TRANSCRIPT_PATH")
if echo "$TRANSCRIPT_PATH" | grep -qE '/(agent|subagent)/'; then
  exit 0
fi
# Heuristic: skip very small transcripts (< 5 lines) likely from subagent sessions
LINE_COUNT=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
if [ "$LINE_COUNT" -lt 5 ]; then
  exit 0
fi

# Add to pendingWrapups in meta.json
if [ -f "$MEMORY_DIR/meta.json" ]; then
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

# === Git sync: commit and push memory changes ===
if [ -d "$MEMORY_DIR/.git" ]; then
  (
    cd "$MEMORY_DIR"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git add -A
      git commit -m "sync: session wrapup $(date +%Y-%m-%d_%H:%M)" --quiet 2>/dev/null
      git push origin main --quiet 2>/dev/null
    fi
  ) || true
fi

exit 0
