#!/bin/bash
# SessionStart hook: inject memory context + pending check + auto-maintain prompt

set -euo pipefail

INPUT=$(cat)
MEMORY_DIR="$HOME/.aria-memory"

# Initialize memory directory if needed
if [ ! -d "$MEMORY_DIR" ]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/init-memory-dir.sh"
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

# === 3. 记忆系统使用指南 ===
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
MEMORY_GUIDE="${MEMORY_GUIDE//MEMORY_DIR_PLACEHOLDER/$MEMORY_DIR}"
CONTEXT="$CONTEXT\n\n$MEMORY_GUIDE"

# === 4. 检查 pending wrapups（核心 wrapup 触发机制） ===
PENDING=0
if [ -f "$MEMORY_DIR/meta.json" ]; then
  PENDING=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('pendingWrapups',[])))" "$MEMORY_DIR/meta.json" 2>/dev/null || echo 0)
fi

if [ "$PENDING" -gt 0 ]; then
  CONTEXT="$CONTEXT\n\n## CRITICAL: Pending Memory Wrapups\n\nThere are $PENDING unprocessed session transcripts from previous sessions. BEFORE responding to the user's first message, you MUST call the memory-agent subagent to process them:\n\n{\"type\":\"session_wrapup\",\"memoryDir\":\"$MEMORY_DIR\",\"processPending\":true}\n\nThis ensures your memory index is up-to-date with information from previous sessions."
fi

# === 5. 维护状态提示 ===
LAST_SLEEP="never"
HOURS_AGO=999999
UNPROCESSED=0
if [ -f "$MEMORY_DIR/meta.json" ]; then
  SLEEP_INFO=$(python3 - "$MEMORY_DIR/meta.json" "$MEMORY_DIR/impressions" << 'PYEOF'
import json, sys, os, time
from datetime import datetime

meta = json.load(open(sys.argv[1]))
impressions_dir = sys.argv[2]

last = meta.get('lastGlobalSleepAt')
if not last:
    last_str = 'never'
    hours_ago = 999999
    last_ts = 0
else:
    # Python < 3.11 doesn't support 'Z' suffix in fromisoformat
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
fi

MAINT_MSG="## Memory Maintenance\n\nLast global_sleep: $LAST_SLEEP ($HOURS_AGO hours ago)\nUnprocessed wrapups since last maintenance: $UNPROCESSED"

if [ "$UNPROCESSED" -ge 2 ] 2>/dev/null || [ "$HOURS_AGO" -ge 12 ] 2>/dev/null; then
  MAINT_MSG="$MAINT_MSG\n\n**Memory maintenance needed.** You should proactively suggest running /memory-sleep to the user early in this session. Also offer to set up /memory-auto-maintain so maintenance runs automatically every 6 hours during long sessions."
elif [ "$UNPROCESSED" -ge 1 ] 2>/dev/null && [ "$HOURS_AGO" -ge 4 ] 2>/dev/null; then
  MAINT_MSG="$MAINT_MSG\n\nWhen there is a natural pause in conversation, suggest running /memory-sleep. Also consider recommending /memory-auto-maintain to keep things tidy automatically."
else
  MAINT_MSG="$MAINT_MSG\n\nMaintenance is up to date. No action needed unless the user requests it."
fi

CONTEXT="$CONTEXT\n\n$MAINT_MSG"

if [ -n "$CONTEXT" ]; then
  python3 -c "
import json, sys
ctx = sys.stdin.read()
out = {'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': ctx}}
print(json.dumps(out, ensure_ascii=False))
" <<< "$(echo -e "$CONTEXT")"
fi

exit 0
