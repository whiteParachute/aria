#!/bin/bash
# Cron-driven `/memory-sleep` runner for the primary claude code endpoint.
#
# Self-disables (exit 0 silently) on any (runtime, machine) pair that is not
# .role.claude=primary, so leaving this entry in crontab on a machine that
# later flips to secondary will not trigger any sleep.
#
# Logs to ~/.aria-memory/.cron.log with a coarse 1MB rotation.

set -euo pipefail

# ---- environment for cron (PATH is stripped by default) ----
export PATH="/home/heyucong.bebop/.local/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="${HOME:-/home/heyucong.bebop}"

MEMORY_DIR="$HOME/.aria-memory"
LOG="$MEMORY_DIR/.cron.log"
TS() { date -u +%Y-%m-%dT%H:%M:%S+00:00; }

# Ensure log dir + simple rotation (>1MB → .1)
mkdir -p "$MEMORY_DIR"
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv -f "$LOG" "${LOG}.1" 2>/dev/null || true
fi

log() { printf '[%s] %s\n' "$(TS)" "$*" >> "$LOG"; }

# ---- role check (silent self-disable when not primary) ----
ROLE_FILE="$MEMORY_DIR/.role.claude"
ROLE="secondary"
if [ -f "$ROLE_FILE" ]; then
  ROLE=$(tr -d '[:space:]' < "$ROLE_FILE" 2>/dev/null)
  ROLE="${ROLE:-secondary}"
fi
if [ "$ROLE" != "primary" ]; then
  log "skip: .role.claude=$ROLE (not primary)"
  exit 0
fi

# ---- single-instance lock ----
LOCK="$MEMORY_DIR/.cron-memory-sleep.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  log "skip: previous run still holds lock $LOCK"
  exit 0
fi

# ---- run /memory-sleep headlessly ----
log "begin: claude -p /memory-sleep"

CLAUDE_BIN="$(command -v claude || echo /home/heyucong.bebop/.local/bin/claude)"
if [ ! -x "$CLAUDE_BIN" ]; then
  log "fatal: claude binary not found"
  exit 1
fi

# Marker so session-end.sh skips wrapup recording for cron-driven runs.
export ARIA_MEMORY_CRON_RUN=1

# 10 minute hard cap — global_sleep on a healthy vault is well under this.
# stdin redirected from /dev/null so claude does not wait 3s for piped input.
set +e
timeout 600 "$CLAUDE_BIN" \
  --print \
  --no-session-persistence \
  --permission-mode bypassPermissions \
  --output-format text \
  "/memory-sleep" \
  < /dev/null >> "$LOG" 2>&1
RC=$?
set -e

log "end: rc=$RC"
exit 0
