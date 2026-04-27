#!/bin/bash
# SessionStart hook: inject memory context + pending check + auto-maintain prompt

set -euo pipefail

INPUT=$(cat)
MEMORY_DIR="$HOME/.aria-memory"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCRIPT_DIR/../scripts/plugin-root.sh"
PLUGIN_ROOT="$(aria_memory_resolve_plugin_root "${BASH_SOURCE[0]}")" || exit 0
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

# Initialize memory directory and run idempotent migrations every session.
# init-memory-dir.sh is safe to call when the dir already exists; it migrates
# the legacy single .role file into .role.claude before any per-runtime
# lazy registration happens below.
bash "$PLUGIN_ROOT/scripts/init-memory-dir.sh"

# Lazy self-registration: this runtime introduces itself by creating its own
# .role.<runtime> file (default "secondary") on first session if absent.
# Runs AFTER init-memory-dir.sh so any legacy .role → .role.claude migration
# has completed first; otherwise we'd shadow an existing primary endpoint.
# User elects a (runtime, machine) pair as primary by manually writing "primary".
if [ "$RUNTIME" != "unknown" ] && [ ! -f "$MEMORY_DIR/.role.$RUNTIME" ]; then
  echo "secondary" > "$MEMORY_DIR/.role.$RUNTIME"
fi

# === 0. Git sync: pull remote changes (from Obsidian/Mac) ===
if [ -d "$MEMORY_DIR/.git" ]; then
  (
    cd "$MEMORY_DIR"
    PULL_ERR=$(git pull --rebase --quiet origin main 2>&1) || {
      {
        echo "Failed at: $(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
        echo "Stage: git pull --rebase"
        echo "Error: $PULL_ERR"
      } > "$MEMORY_DIR/.git-push-failed"
      exit 0
    }
  ) || true
fi

CONTEXT=""

# === 1. 注入 index.md ===
if [ -f "$MEMORY_DIR/index.md" ]; then
  INDEX_CONTENT=$(head -200 "$MEMORY_DIR/index.md")
  CONTEXT="## Long-Term Memory Index\n\nThe following is the user's long-term memory index from previous sessions (compressed quick reference — entries may be incomplete; verify specific facts via memory-agent query).\n\n<memory-index>\n$INDEX_CONTENT\n</memory-index>"
fi

# === 2. 注入 personality.md ===
if [ -f "$MEMORY_DIR/personality.md" ]; then
  PERSONALITY=$(head -50 "$MEMORY_DIR/personality.md")
  CONTEXT="$CONTEXT\n\n## User Interaction Patterns\n\n<personality-notes>\n$PERSONALITY\n</personality-notes>"
fi

# === 2.5 注入最近 daily 摘要 ===
DAILY_DIR="$MEMORY_DIR/daily"
if [ -d "$DAILY_DIR" ]; then
  # Get the 3 most recent daily files (sorted descending by filename = by date)
  DAILY_FILES=$(find "$DAILY_DIR" -maxdepth 1 -type f -name '????-??-??.md' | sort -r | head -3)
  if [ -n "$DAILY_FILES" ]; then
    DAILY_CONTENT=""
    for f in $DAILY_FILES; do
      DAILY_CONTENT="$DAILY_CONTENT$(cat "$f")\n\n---\n\n"
    done
    CONTEXT="$CONTEXT\n\n## Recent Daily Summaries\n\n<daily-summaries>\n$DAILY_CONTENT</daily-summaries>"
  fi
fi

# === 3. 记忆系统使用指南 ===
if [ "$RUNTIME" = "codex" ]; then
  MEMORY_GUIDE=$(cat << 'MEMGUIDE'
## 记忆系统

你拥有一个通过 memory-agent 子代理驱动的长期记忆系统。记忆目录：MEMORY_DIR_PLACEHOLDER

### memory-agent query — 深度回忆

你可以像问一个知道过往上下文的助手那样，直接问它问题。不需要把问题过度拆解，但要给足背景。例如：
- 「今天是 2026-03-16 周一，根据记忆用户今天可能有什么安排？」
- 「用户提到过一个关于 XXX 的项目，具体细节是什么？」
- 「上周用户和我聊过一个技术方案，涉及向量数据库，帮我回忆一下。」

**什么时候应该使用 memory-agent query：**
- 当你不确定自己知不知道某件事时——先查再答，不要猜
- 用户问起过去的事（"之前聊的"、"上次说的"、"还记得吗"）
- 涉及用户个人信息、日程、偏好等需要确认准确性的问题
- 用户在考你/测试你的记忆时
- compact summary 或随身索引中的信息不够详细，需要深入了解时

**索引不是权威事实来源。** 上方随身索引经过压缩，可能丢失限定条件或上下文。
如果索引中已有一些信息，你可以先给出快速印象，然后询问用户要不要让你深入想想（调用 memory-agent query 获取完整细节）。
涉及具体事实（日期、数字、决策结论）时，优先通过 memory-agent query 确认后再回答。

**重要：查询可能需要一定时间。** 发起查询前，先给用户发一条消息（如「让我想想……」「我去翻翻记忆」），避免用户以为你卡死了。

### memory-agent remember — 主动记忆

Codex 会话结束后可能会通过 session_wrapup 整理对话内容存入记忆；是否可用取决于当前 Codex runtime 是否提供可验证的 transcript 路径。
只在以下情况使用主动记忆：
- 用户明确说「记住」「别忘了」
- 特别重要、怕被自动整理遗漏的信息（如用户纠正了个人信息、重要决策）

### 记忆系统与 Codex 项目记忆的分工

不要在 Codex 的项目指导文件（如 AGENTS.md）中手动维护用户身份、长期偏好、过往对话知识；这些由 Aria 记忆系统统一管理，已通过上方随身索引加载。AGENTS.md 只用于项目级代码约定、构建/测试流程和当前仓库工作协议。
MEMGUIDE
)
else
  MEMORY_GUIDE=$(cat << 'MEMGUIDE'
## 记忆系统

你拥有一个通过 memory-agent subagent 驱动的长期记忆系统。记忆目录：MEMORY_DIR_PLACEHOLDER

### memory-agent query — 深度回忆

你可以像问一个知道一切过往的助手那样，直接问它问题。不需要把问题过度拆解，但要给足背景。例如：
- 「今天是 2026-03-16 周一，根据记忆用户今天可能有什么安排？」
- 「用户提到过一个关于 XXX 的项目，具体细节是什么？」
- 「上周用户和我聊过一个技术方案，涉及向量数据库，帮我回忆一下。」

**什么时候应该使用 memory-agent query：**
- 当你不确定自己知不知道某件事时——先查再答，不要猜
- 用户问起过去的事（"之前聊的"、"上次说的"、"还记得吗"）
- 涉及用户个人信息、日程、偏好等需要确认准确性的问题
- 用户在考你/测试你的记忆时
- compact summary 或随身索引中的信息不够详细，需要深入了解时

**索引不是权威事实来源。** 上方随身索引经过压缩，可能丢失限定条件或上下文。
如果索引中已有一些信息，你可以先给出快速印象，然后询问用户要不要让你深入想想（调用 memory-agent query 获取完整细节）。
涉及具体事实（日期、数字、决策结论）时，优先通过 memory-agent query 确认后再回答。

**重要：查询可能需要一定时间。** 发起查询前，先给用户发一条消息（如「让我想想……」「我去翻翻记忆」），避免用户以为你卡死了。

### memory-agent remember — 主动记忆

每次对话结束后，系统会自动整理对话内容存入记忆（session_wrapup），所以不需要频繁手动记录。
只在以下情况使用：
- 用户明确说「记住」「别忘了」
- 特别重要、怕被自动整理遗漏的信息（如用户纠正了个人信息、重要决策）

### 记忆系统与内置 auto-memory 的分工

不要在 Claude Code 的内置记忆文件（~/.claude/projects/ 下的 CLAUDE.md 或 memory 文件）中手动维护用户身份、偏好、过往知识——这些由记忆系统统一管理，已通过上方随身索引加载。内置 auto-memory 仅用于项目级的代码约定和工作流偏好。
MEMGUIDE
)
fi
MEMORY_GUIDE="${MEMORY_GUIDE//MEMORY_DIR_PLACEHOLDER/$MEMORY_DIR}"
CONTEXT="$CONTEXT\n\n$MEMORY_GUIDE"

# === 4. 检查 pending wrapups（核心 wrapup 触发机制） ===
PENDING=0
if [ -f "$MEMORY_DIR/meta.json" ]; then
  PENDING=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('pendingWrapups',[])))" "$MEMORY_DIR/meta.json" 2>/dev/null || echo 0)
fi

if [ "$PENDING" -gt 0 ]; then
  if [ "$RUNTIME" = "codex" ]; then
    CONTEXT="$CONTEXT\n\n## CRITICAL: Pending Memory Wrapups\n\nThere are $PENDING unprocessed Codex session transcripts from previous sessions. BEFORE responding to the user's first message, call the Codex memory-agent surface to process them:\n\n{\"type\":\"session_wrapup\",\"memoryDir\":\"$MEMORY_DIR\",\"processPending\":true}\n\nThe memory-agent must read pending entries from meta.json and process only verified transcript paths recorded there."
  else
    CONTEXT="$CONTEXT\n\n## CRITICAL: Pending Memory Wrapups\n\nThere are $PENDING unprocessed session transcripts from previous sessions. BEFORE responding to the user's first message, you MUST call the memory-agent subagent to process them:\n\n{\"type\":\"session_wrapup\",\"memoryDir\":\"$MEMORY_DIR\",\"processPending\":true}\n\nThis ensures your memory index is up-to-date with information from previous sessions."
  fi
fi

# === 5. 检查 Git push 失败标记 ===
if [ -f "$MEMORY_DIR/.git-push-failed" ]; then
  FAIL_INFO=$(cat "$MEMORY_DIR/.git-push-failed")
  CONTEXT="$CONTEXT\n\n## ⚠️ Git Push Failure Detected\n\nA previous Git push operation failed after 3 retries. Details:\n\`\`\`\n$FAIL_INFO\n\`\`\`\n\n**Action needed**: Please check the Git status in $MEMORY_DIR and resolve the issue manually. After resolving, delete the \`.git-push-failed\` file."
fi

# === 6. 维护状态提示 ===
LAST_SLEEP="never"
HOURS_AGO=999999
UNPROCESSED=0

# Read .last-sleep-at (Git-synced cross-machine watermark) with meta.json fallback
SLEEP_INFO=$(python3 - "$MEMORY_DIR" << 'PYEOF'
import sys, os, time, json
from datetime import datetime

memory_dir = sys.argv[1]
last_sleep_file = os.path.join(memory_dir, '.last-sleep-at')
meta_file = os.path.join(memory_dir, 'meta.json')
impressions_dir = os.path.join(memory_dir, 'impressions')

# Priority: .last-sleep-at (Git-synced) > meta.json (local cache)
last = None
if os.path.isfile(last_sleep_file):
    last = open(last_sleep_file).read().strip()
if not last and os.path.isfile(meta_file):
    last = json.load(open(meta_file)).get('lastGlobalSleepAt')

if not last:
    last_str = 'never'
    hours_ago = 999999
    last_ts = 0
else:
    last_fixed = last.replace('Z', '+00:00')
    diff = time.time() - datetime.fromisoformat(last_fixed).timestamp()
    last_str = last
    hours_ago = int(diff / 3600)
    last_ts = datetime.fromisoformat(last_fixed).timestamp()

# Count impression files newer than last global_sleep
unprocessed = 0
if os.path.isdir(impressions_dir):
    for f in os.listdir(impressions_dir):
        if f.endswith('.md'):
            fpath = os.path.join(impressions_dir, f)
            if os.path.getmtime(fpath) > last_ts:
                unprocessed += 1

print(f'{last_str} {hours_ago} {unprocessed}')
PYEOF
) 2>/dev/null
SLEEP_INFO="${SLEEP_INFO:-never 999999 0}"
LAST_SLEEP=$(echo "$SLEEP_INFO" | awk '{print $1}')
HOURS_AGO=$(echo "$SLEEP_INFO" | awk '{print $2}')
UNPROCESSED=$(echo "$SLEEP_INFO" | awk '{print $3}')

# Read per-runtime role (.role.claude or .role.codex; per-machine, gitignored).
# Each runtime on each machine has its own role; default secondary if missing.
ROLE_FILE="$MEMORY_DIR/.role.$RUNTIME"
ROLE="secondary"
if [ -f "$ROLE_FILE" ]; then
  ROLE=$(cat "$ROLE_FILE" 2>/dev/null | tr -d '[:space:]')
  ROLE="${ROLE:-secondary}"
elif [ -f "$MEMORY_DIR/.role" ]; then
  # Legacy single .role from earlier prototype — fall back, but init-memory-dir.sh
  # will migrate it on next run.
  ROLE=$(cat "$MEMORY_DIR/.role" 2>/dev/null | tr -d '[:space:]')
  ROLE="${ROLE:-secondary}"
fi

MAINT_MSG="## Memory Maintenance\n\nRuntime: $RUNTIME (role: $ROLE)\nLast global_sleep: $LAST_SLEEP ($HOURS_AGO hours ago)\nUnprocessed wrapups since last maintenance: $UNPROCESSED"

if [ "$UNPROCESSED" -ge 2 ] 2>/dev/null || [ "$HOURS_AGO" -ge 12 ] 2>/dev/null; then
  if [ "$ROLE" = "primary" ]; then
    if [ "$RUNTIME" = "codex" ]; then
      MAINT_MSG="$MAINT_MSG\n\n**Memory maintenance needed (primary endpoint).** Proactively suggest running the Codex memory-sleep skill early in this session. Cron-based auto-maintain is also available — see memory-auto-maintain skill."
    else
      MAINT_MSG="$MAINT_MSG\n\n**Memory maintenance needed (primary endpoint).** Proactively suggest running /memory-sleep early in this session. Also offer /memory-auto-maintain so maintenance runs every 6 hours during long sessions."
    fi
  else
    MAINT_MSG="$MAINT_MSG\n\n**Maintenance is overdue but this endpoint role is '$ROLE'** — global_sleep runs only on the primary endpoint to prevent collisions. Tell the user the watermark is stale and to run /memory-sleep on the primary side. Do NOT run /memory-sleep here."
  fi
elif [ "$UNPROCESSED" -ge 1 ] 2>/dev/null && [ "$HOURS_AGO" -ge 4 ] 2>/dev/null; then
  if [ "$ROLE" = "primary" ]; then
    if [ "$RUNTIME" = "codex" ]; then
      MAINT_MSG="$MAINT_MSG\n\nWhen there is a natural pause in conversation, suggest running the Codex memory-sleep skill."
    else
      MAINT_MSG="$MAINT_MSG\n\nWhen there is a natural pause in conversation, suggest running /memory-sleep. Also consider /memory-auto-maintain."
    fi
  else
    MAINT_MSG="$MAINT_MSG\n\nNudge-level: maintenance is slightly behind on the primary endpoint. No action needed here ($ROLE)."
  fi
else
  MAINT_MSG="$MAINT_MSG\n\nMaintenance is up to date. No action needed unless the user requests it."
fi

CONTEXT="$CONTEXT\n\n$MAINT_MSG"

if [ -n "$CONTEXT" ]; then
  if [ "$RUNTIME" = "codex" ] && [ "${ARIA_MEMORY_CODEX_CONTEXT_OUTPUT:-}" != "claude-compatible" ]; then
    exit 0
  fi

  python3 -c "
import json, sys
ctx = sys.stdin.read()
out = {'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': ctx}}
print(json.dumps(out, ensure_ascii=False))
" <<< "$(echo -e "$CONTEXT")"
fi

exit 0
