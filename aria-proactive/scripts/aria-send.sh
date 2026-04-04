#!/usr/bin/env bash
# aria-send.sh — Launch a fresh headless Claude session to complete a task
# and send the result to a Telegram chat via curl.
#
# This avoids the 409 Conflict that would occur if a second Claude session
# tried to load the telegram plugin alongside an already-running one:
# the Telegram Bot API only allows one getUpdates poller per token.
#
# Sending a message (sendMessage API) is a stateless HTTP POST that any
# process can make without touching the plugin, so the fresh session uses
# curl directly.
#
# Required env var:
#   TELEGRAM_CHAT_ID   — chat_id to send the result to
#
# Optional env vars:
#   TELEGRAM_TOKEN_FILE  — path to env file containing TELEGRAM_BOT_TOKEN
#                          (default: $HOME/.claude/channels/telegram/.env)
#   CLAUDE_BIN           — path to claude CLI (default: `claude` on PATH)
#
# Usage:
#   TELEGRAM_CHAT_ID=<id> aria-send.sh "<task description>"

set -euo pipefail

TASK="${1:-}"
if [[ -z "$TASK" ]]; then
  echo "Usage: TELEGRAM_CHAT_ID=<id> $0 '<task description>'" >&2
  exit 1
fi

if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "Error: TELEGRAM_CHAT_ID env var is required" >&2
  exit 1
fi

TOKEN_FILE="${TELEGRAM_TOKEN_FILE:-$HOME/.claude/channels/telegram/.env}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

if [[ ! -r "$TOKEN_FILE" ]]; then
  echo "Error: token file not readable: $TOKEN_FILE" >&2
  exit 1
fi

# Build the prompt by piecing together literal heredoc sections and
# interpolated variables. Using a single heredoc triggers shell quoting
# edge cases (apostrophes, backslashes) so we assemble it piecewise.
read -r -d '' HEADER <<'PROMPT_HEADER' || true
This is a headless background task. Complete the task below, then deliver the result to a Telegram chat via curl.

## Task
PROMPT_HEADER

read -r -d '' FOOTER <<'PROMPT_FOOTER' || true

## Delivery
- Bot token location is the TOKEN_FILE above. Load it with: source "$TOKEN_FILE" (variable name TELEGRAM_BOT_TOKEN)
- Send with curl by POSTing to https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage with form fields chat_id=$TELEGRAM_CHAT_ID and text=<your message> (use --data-urlencode for the text to handle special characters)

## Notes
- Follow whatever persona and style rules are defined in your loaded CLAUDE.md.
- Telegram messages are capped at 4096 characters — for longer content, chunk the message or attach as a file.
- After sending, print "done" and exit.
PROMPT_FOOTER

PROMPT="${HEADER}
${TASK}

TOKEN_FILE=${TOKEN_FILE}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
${FOOTER}"

exec "$CLAUDE_BIN" -p "$PROMPT" --dangerously-skip-permissions
