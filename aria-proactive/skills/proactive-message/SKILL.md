---
name: proactive-message
description: |
  Send a proactive Telegram message by spawning a fresh headless Claude
  session (not the current one). Use this when the user asks for scheduled
  or fire-and-forget tasks that end in a Telegram notification — it avoids
  the 409 Conflict that would occur if a second session tried to load the
  telegram plugin alongside the current one.
allowed-tools: [Bash]
---

# Proactive Message Skill

## When to use

- User asks for scheduled messaging ("every day at X", "remind me at Y", recurring check-ins)
- User asks for a fire-and-forget background task that ends in a Telegram notification
- You need to send a Telegram message from a context without the telegram plugin loaded
- You want scheduled messaging that survives the current session ending

**Do NOT use this skill** for normal in-session replies — use `mcp__plugin_telegram_telegram__reply` directly when responding live.

## Why a fresh session

When the current session was launched with `--channels plugin:telegram@claude-plugins-official`, it spawned a bun subprocess that long-polls Telegram's `getUpdates` API. **Telegram only allows one getUpdates poller per bot token** — a second `claude` instance with the same flag would hit endless 409 Conflict retries.

But **sending** a message (`sendMessage` API) is a stateless HTTP POST that works from any process. The pattern:

1. Launch `claude -p "<prompt>"` **without** `--channels` → no polling conflict
2. The fresh session uses Bash + curl to POST directly to Telegram's Bot API
3. Bot token is read from the existing plugin state file (already on disk)
4. Fresh session exits after sending — no zombie processes

## Prerequisites

The telegram plugin must already be configured and paired (token stored at `~/.claude/channels/telegram/.env`). This skill uses that existing token but does NOT require the plugin to be running in the fresh session.

You need a `TELEGRAM_CHAT_ID` — the chat where messages should be delivered. Get this from the inbound `<channel>` tag in any Telegram message the user has sent.

## How to invoke

### Immediate one-shot

```bash
TELEGRAM_CHAT_ID=<chat_id> "${CLAUDE_PLUGIN_ROOT}/scripts/aria-send.sh" "<task description>"
```

Examples:

```bash
# Simple greeting
TELEGRAM_CHAT_ID=123456 "${CLAUDE_PLUGIN_ROOT}/scripts/aria-send.sh" \
  "Send a good morning greeting and check if there's anything on the calendar today"

# Status report with external data
TELEGRAM_CHAT_ID=123456 "${CLAUDE_PLUGIN_ROOT}/scripts/aria-send.sh" \
  "Look up the current BTC price and send a one-line comment"

# Memory-aware check-in
TELEGRAM_CHAT_ID=123456 "${CLAUDE_PLUGIN_ROOT}/scripts/aria-send.sh" \
  "Query long-term memory for today's schedule and send a reminder"
```

The fresh session:
- Loads whatever CLAUDE.md personality is configured globally for the user
- Has access to the memory-agent subagent (if installed) for long-term context
- Knows where the bot token file is and how to call the Telegram API
- Exits cleanly after delivering

### Scheduled / recurring

For persistent scheduling that survives session restarts, shell out to `crontab` or `launchd` pointing at the helper script.

**crontab** (edit with `crontab -e`):

```cron
# Daily 9:03am greeting
3 9 * * * TELEGRAM_CHAT_ID=123456 /path/to/aria-proactive/scripts/aria-send.sh "Send a good morning check-in"
```

**launchd** (macOS, better than cron for sleep/wake handling): create a plist in `~/Library/LaunchAgents/` with `ProgramArguments` pointing at the script and `EnvironmentVariables.TELEGRAM_CHAT_ID` set.

### One-shot future trigger

Use `at` for "remind me at X time" requests:

```bash
echo 'TELEGRAM_CHAT_ID=123456 /path/to/aria-proactive/scripts/aria-send.sh "Remind about the 2pm meeting"' \
  | at 13:55
```

## Configuration reference

The helper script reads these env vars:

| Variable               | Required | Default                                    | Purpose                       |
|------------------------|----------|--------------------------------------------|-------------------------------|
| `TELEGRAM_CHAT_ID`     | Yes      | —                                          | Destination chat              |
| `TELEGRAM_TOKEN_FILE`  | No       | `$HOME/.claude/channels/telegram/.env`     | File with `TELEGRAM_BOT_TOKEN`|
| `CLAUDE_BIN`           | No       | `claude` (on PATH)                         | Claude CLI path               |

## Limitations

- The fresh session has **no current conversation context** — only what's in CLAUDE.md and long-term memory. Include any task-specific context directly in the task description.
- Token file path must be readable by the user running cron/launchd.
- Telegram messages are capped at 4096 chars per message; longer content should be chunked or attached as a file.

## Related

- `mcp__plugin_telegram_telegram__reply` — use this for live in-session replies, NOT this skill.
- The aria-memory plugin (sibling) — the fresh session can call memory-agent to pull context.
