#!/bin/bash
# Read and display memory system status

MEMORY_DIR="$HOME/.aria-memory"

if [ ! -d "$MEMORY_DIR" ]; then
  echo "Memory directory not found: $MEMORY_DIR"
  echo "Run init-memory-dir.sh to initialize."
  exit 1
fi

echo "=== Aria Memory Status ==="
echo ""

# Index size
if [ -f "$MEMORY_DIR/index.md" ]; then
  INDEX_LINES=$(wc -l < "$MEMORY_DIR/index.md")
  echo "Index entries:     $INDEX_LINES lines"
else
  echo "Index entries:     (not found)"
fi

# Knowledge files
KNOWLEDGE_COUNT=$(find "$MEMORY_DIR/knowledge" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
echo "Knowledge files:   $KNOWLEDGE_COUNT"

# Impressions
ACTIVE_COUNT=$(find "$MEMORY_DIR/impressions" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
ARCHIVED_COUNT=$(find "$MEMORY_DIR/impressions/archived" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
echo "Impressions:       $ACTIVE_COUNT active / $ARCHIVED_COUNT archived"

# Meta info
if [ -f "$MEMORY_DIR/meta.json" ]; then
  python3 - "$MEMORY_DIR/meta.json" << 'PYEOF'
import json, sys, time
from datetime import datetime

meta = json.load(open(sys.argv[1]))

pending = len(meta.get('pendingWrapups', []))
print(f"Pending wrapups:   {pending}")

last = meta.get('lastGlobalSleepAt')
if last:
    diff = time.time() - datetime.fromisoformat(last).timestamp()
    hours = int(diff / 3600)
    print(f"Last maintenance:  {last} ({hours} hours ago)")
else:
    print("Last maintenance:  never")

print(f"Index version:     {meta.get('indexVersion', 0)}")
PYEOF
else
  echo "Pending wrapups:   (meta.json not found)"
  echo "Last maintenance:  unknown"
  echo "Index version:     unknown"
fi
