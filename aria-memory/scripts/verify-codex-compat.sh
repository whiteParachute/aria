#!/bin/bash
# Verify aria-memory Claude compatibility and Codex packaging surfaces.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

require_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

require_dir() {
  [ -d "$1" ] || fail "missing directory: $1"
}

require_grep() {
  local pattern="$1"
  local file="$2"
  grep -qE "$pattern" "$file" || fail "missing pattern '$pattern' in $file"
}

json_ok() {
  jq . "$1" >/dev/null || fail "invalid JSON: $1"
}

run_session_start() {
  local home_dir="$1"
  local output_file="$2"
  shift 2
  printf '{}' | HOME="$home_dir" "$@" bash "$PLUGIN_DIR/hooks/session-start.sh" > "$output_file"
  jq . "$output_file" >/dev/null || fail "SessionStart did not emit valid JSON"
}

run_codex_session_start_safe_downgrade() {
  local home_dir="$1"
  local output_file="$2"
  printf '{}' | HOME="$home_dir" ARIA_MEMORY_RUNTIME=codex CODEX_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PLUGIN_DIR/hooks/session-start.sh" > "$output_file"
  [ ! -s "$output_file" ] || fail "Codex SessionStart emitted output before context contract verification"
}

echo "Verifying aria-memory Codex compatibility in $PLUGIN_DIR"

require_file "$PLUGIN_DIR/.claude-plugin/plugin.json"
require_file "$PLUGIN_DIR/.codex-plugin/plugin.json"
require_file "$PLUGIN_DIR/hooks/hooks.json"
require_file "$PLUGIN_DIR/hooks.json"
json_ok "$PLUGIN_DIR/.claude-plugin/plugin.json"
json_ok "$PLUGIN_DIR/.codex-plugin/plugin.json"
json_ok "$PLUGIN_DIR/hooks/hooks.json"
json_ok "$PLUGIN_DIR/hooks.json"
pass "Claude and Codex manifests/hooks parse as JSON"

[ "$(jq -r '.name' "$PLUGIN_DIR/.claude-plugin/plugin.json")" = "aria-memory" ] || fail "Claude manifest name mismatch"
[ "$(jq -r '.name' "$PLUGIN_DIR/.codex-plugin/plugin.json")" = "aria-memory" ] || fail "Codex manifest name mismatch"
[ "$(jq -r '.skills' "$PLUGIN_DIR/.codex-plugin/plugin.json")" = "./codex/skills" ] || fail "Codex skills path mismatch"
[ "$(jq -r '.hooks' "$PLUGIN_DIR/.codex-plugin/plugin.json")" = "./hooks.json" ] || fail "Codex hooks path mismatch"
[ "$(jq -r '.agents // empty' "$PLUGIN_DIR/.codex-plugin/plugin.json")" = "" ] || fail "Codex manifest must not declare agents (codex CLI 0.125.0 has no plugin-agent loading; use references/ instead)"
[ "$(jq -r '.interface.sharedSpec // empty' "$PLUGIN_DIR/.codex-plugin/plugin.json")" = "./codex/references/memory-agent-spec.md" ] || fail "Codex manifest must point sharedSpec at the canonical memory-agent spec reference"
require_dir "$PLUGIN_DIR/codex/skills"
require_dir "$PLUGIN_DIR/codex/references"
[ ! -e "$PLUGIN_DIR/codex/agents" ] || fail "codex/agents must be removed (codex CLI does not load plugin agents in 0.125.0)"
pass "Codex manifest points to existing skills + spec reference, no dead agent surface"

for script in session-start.sh session-end.sh pre-compact.sh; do
  require_file "$PLUGIN_DIR/hooks/$script"
  require_grep "$script" "$PLUGIN_DIR/hooks.json"
done
pass "Codex root hooks config references existing hook scripts"

for skill in memory remember memory-status memory-wrapup memory-sleep memory-auto-maintain; do
  require_file "$PLUGIN_DIR/codex/skills/$skill/SKILL.md"
done
require_file "$PLUGIN_DIR/codex/references/memory-agent-spec.md"
pass "Codex skill and reference spec files exist"

if grep -R "allowed-tools: \\[Agent\\]" "$PLUGIN_DIR/codex/skills" >/dev/null; then
  fail "Codex skills contain Claude-only Agent tool frontmatter"
fi
SPEC="$PLUGIN_DIR/codex/references/memory-agent-spec.md"
require_grep "type.*query" "$SPEC"
require_grep "remember" "$SPEC"
require_grep "session_wrapup" "$SPEC"
require_grep "global_sleep" "$SPEC"
require_grep "primary" "$SPEC"
require_grep "rollout_path" "$PLUGIN_DIR/codex/skills/memory-wrapup/SKILL.md"
require_grep "\.role\.codex" "$PLUGIN_DIR/codex/skills/memory-sleep/SKILL.md"
require_grep "\.role\.codex" "$PLUGIN_DIR/codex/skills/memory-auto-maintain/SKILL.md"
require_grep "\.role\.claude" "$PLUGIN_DIR/skills/memory-sleep/SKILL.md"
require_grep "\.role\.claude" "$PLUGIN_DIR/skills/memory-auto-maintain/SKILL.md"
for skill in memory remember memory-wrapup memory-sleep; do
  require_grep "memory-agent-spec.md" "$PLUGIN_DIR/codex/skills/$skill/SKILL.md"
done
pass "Codex+Claude skills inline-read spec; sleep/auto-maintain gated by .role.<runtime> per (runtime, machine)"

home_with_env="$TMP_ROOT/home-with-env"
mkdir -p "$home_with_env"
run_session_start "$home_with_env" "$TMP_ROOT/session-start-env.json" env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
require_file "$home_with_env/.aria-memory/index.md"
require_file "$home_with_env/.aria-memory/meta.json"
require_file "$home_with_env/.aria-memory/personality.md"
require_dir "$home_with_env/.aria-memory/knowledge/.pending"
require_dir "$home_with_env/.aria-memory/daily"
pass "SessionStart initializes memory with CLAUDE_PLUGIN_ROOT"

home_no_env="$TMP_ROOT/home-no-env"
mkdir -p "$home_no_env"
run_session_start "$home_no_env" "$TMP_ROOT/session-start-no-env.json" env -u CLAUDE_PLUGIN_ROOT
require_file "$home_no_env/.aria-memory/index.md"
require_file "$home_no_env/.aria-memory/meta.json"
require_file "$home_no_env/.aria-memory/personality.md"
pass "SessionStart initializes memory without CLAUDE_PLUGIN_ROOT"

home_codex="$TMP_ROOT/home-codex"
mkdir -p "$home_codex"
run_codex_session_start_safe_downgrade "$home_codex" "$TMP_ROOT/session-start-codex.out"
require_file "$home_codex/.aria-memory/index.md"
require_file "$home_codex/.aria-memory/meta.json"
require_file "$home_codex/.aria-memory/personality.md"
pass "Codex SessionStart initializes memory and safely suppresses unverified context output"

home_codex_optin="$TMP_ROOT/home-codex-optin"
mkdir -p "$home_codex_optin"
printf '{}' | HOME="$home_codex_optin" ARIA_MEMORY_RUNTIME=codex ARIA_MEMORY_CODEX_CONTEXT_OUTPUT=claude-compatible CODEX_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PLUGIN_DIR/hooks/session-start.sh" > "$TMP_ROOT/session-start-codex-optin.json"
jq . "$TMP_ROOT/session-start-codex-optin.json" >/dev/null || fail "Codex opt-in SessionStart did not emit valid JSON"
pass "Codex SessionStart can opt in to Claude-compatible context output after local verification"

home_missing_transcript="$TMP_ROOT/home-missing-transcript"
mkdir -p "$home_missing_transcript"
HOME="$home_missing_transcript" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PLUGIN_DIR/scripts/init-memory-dir.sh"
before_meta="$TMP_ROOT/meta-before.json"
after_meta="$TMP_ROOT/meta-after.json"
cp "$home_missing_transcript/.aria-memory/meta.json" "$before_meta"
printf '{}' | HOME="$home_missing_transcript" bash "$PLUGIN_DIR/hooks/session-end.sh"
cp "$home_missing_transcript/.aria-memory/meta.json" "$after_meta"
cmp -s "$before_meta" "$after_meta" || fail "SessionEnd changed meta.json without transcript source"
pass "SessionEnd missing transcript exits safely without meta changes"

small_transcript="$home_missing_transcript/small.jsonl"
for i in 1 2 3 4; do
  printf '{"type":"user","message":{"content":"hello"}}\n' >> "$small_transcript"
done
cp "$home_missing_transcript/.aria-memory/meta.json" "$before_meta"
printf '{"transcript_path":"%s"}' "$small_transcript" | HOME="$home_missing_transcript" bash "$PLUGIN_DIR/hooks/session-end.sh"
cp "$home_missing_transcript/.aria-memory/meta.json" "$after_meta"
cmp -s "$before_meta" "$after_meta" || fail "SessionEnd changed meta.json for a small transcript"
pass "SessionEnd skips small transcripts without meta changes"

home_with_transcript="$TMP_ROOT/home-with-transcript"
mkdir -p "$home_with_transcript"
HOME="$home_with_transcript" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PLUGIN_DIR/scripts/init-memory-dir.sh"
transcript="$home_with_transcript/session.jsonl"
for i in 1 2 3 4 5; do
  printf '{"type":"user","message":{"content":"hello"}}\n' >> "$transcript"
done
printf '{"transcript_path":"%s"}' "$transcript" | HOME="$home_with_transcript" bash "$PLUGIN_DIR/hooks/session-end.sh"
printf '{"transcript_path":"%s"}' "$transcript" | HOME="$home_with_transcript" bash "$PLUGIN_DIR/hooks/session-end.sh"
python3 - "$home_with_transcript/.aria-memory/meta.json" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1]))
pending = meta.get("pendingWrapups", [])
assert len(pending) == 1, pending
PY
pass "SessionEnd records valid transcript once and deduplicates"

home_codex_transcript="$TMP_ROOT/home-codex-transcript"
mkdir -p "$home_codex_transcript/.codex"
HOME="$home_codex_transcript" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PLUGIN_DIR/scripts/init-memory-dir.sh"
codex_rollout="$home_codex_transcript/.codex/rollout-codex-thread-1.jsonl"
for i in 1 2 3 4 5; do
  printf '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}}\n' >> "$codex_rollout"
done
python3 - "$home_codex_transcript/.codex/state_5.sqlite" "$codex_rollout" <<'PY'
import sqlite3, sys
db_path, rollout_path = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db_path)
conn.execute(
    """
    create table threads (
      id text primary key,
      rollout_path text not null,
      cwd text not null,
      source text not null,
      agent_path text,
      updated_at integer not null,
      updated_at_ms integer
    )
    """
)
conn.execute(
    "insert into threads values (?, ?, ?, ?, ?, ?, ?)",
    ("codex-thread-1", rollout_path, "/tmp/codex-cwd", "cli", None, 1777273600, 1777273600000),
)
conn.commit()
conn.close()
PY
printf '{"session_id":"codex-thread-1"}' | HOME="$home_codex_transcript" ARIA_MEMORY_RUNTIME=codex bash "$PLUGIN_DIR/hooks/session-end.sh"
python3 - "$home_codex_transcript/.aria-memory/meta.json" "$codex_rollout" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1]))
rollout = sys.argv[2]
pending = meta.get("pendingWrapups", [])
assert len(pending) == 1, pending
assert pending[0].get("transcriptPath") == rollout, pending
PY
pass "Codex SessionEnd resolves rollout_path from state SQLite by session_id"

home_codex_env="$TMP_ROOT/home-codex-env"
mkdir -p "$home_codex_env/.codex"
HOME="$home_codex_env" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PLUGIN_DIR/scripts/init-memory-dir.sh"
codex_env_rollout="$home_codex_env/.codex/rollout-codex-env.jsonl"
for i in 1 2 3 4 5; do
  printf '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello env"}]}}\n' >> "$codex_env_rollout"
done
python3 - "$home_codex_env/.codex/state_5.sqlite" "$codex_env_rollout" <<'PY'
import sqlite3, sys
db_path, rollout_path = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db_path)
conn.execute(
    """
    create table threads (
      id text primary key,
      rollout_path text not null,
      cwd text not null,
      source text not null,
      agent_path text,
      updated_at integer not null,
      updated_at_ms integer
    )
    """
)
conn.execute(
    "insert into threads values (?, ?, ?, ?, ?, ?, ?)",
    ("codex-env-thread", rollout_path, "/tmp/codex-cwd", "cli", None, 1777273700, 1777273700000),
)
conn.commit()
conn.close()
PY
printf '{}' | HOME="$home_codex_env" ARIA_MEMORY_RUNTIME=codex CODEX_COMPANION_SESSION_ID=codex-env-thread bash "$PLUGIN_DIR/hooks/session-end.sh"
python3 - "$home_codex_env/.aria-memory/meta.json" "$codex_env_rollout" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1]))
rollout = sys.argv[2]
pending = meta.get("pendingWrapups", [])
assert len(pending) == 1, pending
assert pending[0].get("transcriptPath") == rollout, pending
PY
pass "Codex SessionEnd resolves rollout_path from state SQLite by session id env"

cp "$home_codex_transcript/.aria-memory/meta.json" "$before_meta"
printf '{"session_id":"codex-thread-1"}' | HOME="$home_codex_transcript" ARIA_MEMORY_RUNTIME=claude bash "$PLUGIN_DIR/hooks/session-end.sh"
cp "$home_codex_transcript/.aria-memory/meta.json" "$after_meta"
cmp -s "$before_meta" "$after_meta" || fail "Claude SessionEnd should not resolve Codex state SQLite by session_id"
pass "SessionEnd keeps Claude and Codex transcript resolution separated by runtime"

home_pending="$TMP_ROOT/home-pending"
mkdir -p "$home_pending"
HOME="$home_pending" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PLUGIN_DIR/scripts/init-memory-dir.sh"
python3 - "$home_pending/.aria-memory/meta.json" <<'PY'
import json, sys, os, tempfile
path = sys.argv[1]
meta = json.load(open(path))
meta["pendingWrapups"] = [{"transcriptPath": "/tmp/example.jsonl", "recordedAt": "2026-04-27T00:00:00+00:00", "trigger": "session_end"}]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(meta, f)
os.replace(tmp, path)
PY
run_session_start "$home_pending" "$TMP_ROOT/session-start-pending.json" env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
require_grep "Pending Memory Wrapups" "$TMP_ROOT/session-start-pending.json"
pass "SessionStart includes pending wrapup context when pending entries exist"

home_precompact="$TMP_ROOT/home-precompact"
mkdir -p "$home_precompact"
HOME="$home_precompact" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PLUGIN_DIR/scripts/init-memory-dir.sh"
python3 - "$home_precompact/.aria-memory/meta.json" <<'PY'
import json, sys, os, tempfile
path = sys.argv[1]
meta = json.load(open(path))
meta["compactionEvents"] = [f"old-{i}" for i in range(12)]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(meta, f)
os.replace(tmp, path)
PY
printf '{}' | HOME="$home_precompact" bash "$PLUGIN_DIR/hooks/pre-compact.sh"
python3 - "$home_precompact/.aria-memory/meta.json" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1]))
events = meta.get("compactionEvents", [])
assert len(events) == 10, events
PY
pass "PreCompact records compaction events and keeps the last 10"

if command -v git >/dev/null; then
  home_git="$TMP_ROOT/home-git"
  mkdir -p "$home_git"
  HOME="$home_git" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$PLUGIN_DIR/scripts/init-memory-dir.sh"
  (
    cd "$home_git/.aria-memory"
    git init -q
    git checkout -q -b main
    git config user.email aria-memory-test@example.invalid
    git config user.name "Aria Memory Test"
    git remote add origin "$TMP_ROOT/nonexistent-remote"
  )
  transcript_git="$home_git/session.jsonl"
  for i in 1 2 3 4 5; do
    printf '{"type":"user","message":{"content":"hello"}}\n' >> "$transcript_git"
  done
  printf '{"transcript_path":"%s"}' "$transcript_git" | HOME="$home_git" bash "$PLUGIN_DIR/hooks/session-end.sh"
  require_file "$home_git/.aria-memory/.git-push-failed"
  require_grep "Stage: git push" "$home_git/.aria-memory/.git-push-failed"
  pass "Git sync failure is non-blocking and writes a diagnostic marker"
else
  echo "SKIP: git sync marker test (git not found)"
fi

require_grep "Runtime Capability Matrix" "$PLUGIN_DIR/README.md"
require_grep "Codex supported" "$PLUGIN_DIR/README.md"
require_grep "Codex conditional" "$PLUGIN_DIR/README.md"
require_grep "Codex agent path" "$PLUGIN_DIR/README.md"
pass "README contains Codex capability and packaging documentation"

echo "All aria-memory Codex compatibility checks passed."
