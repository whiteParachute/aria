#!/bin/bash
# PreCompact hook: record compaction timestamp

set -euo pipefail

INPUT=$(cat)
MEMORY_DIR="$HOME/.aria-memory"

if [ ! -f "$MEMORY_DIR/meta.json" ]; then
  exit 0
fi

# Record compaction event in meta.json
python3 - "$MEMORY_DIR/meta.json" << 'PYEOF'
import json, sys, os, tempfile
from datetime import datetime, timezone

meta_path = sys.argv[1]
with open(meta_path) as f:
    meta = json.load(f)

compactions = meta.get('compactionEvents', [])
compactions.append(datetime.now(timezone.utc).isoformat())
# Keep only last 10 compaction timestamps
meta['compactionEvents'] = compactions[-10:]

# Atomic write
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(meta_path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
os.replace(tmp, meta_path)
PYEOF

exit 0
