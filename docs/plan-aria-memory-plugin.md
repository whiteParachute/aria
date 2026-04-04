# Aria Memory Plugin — Claude Code 插件技术方案

## 1. 概述

### 1.1 目标

将 HappyClaw 项目中的 Memory Agent 记忆系统移植为一个 Claude Code Plugin，使 Claude Code 在所有项目中都具备**持久化长期记忆**能力。核心能力包括：

- **记忆查询 (query)** — 多层级检索：index → impressions → knowledge → archived
- **记忆存储 (remember)** — 分类存储到 knowledge/，自动更新索引
- **会话收尾 (session_wrapup)** — 会话结束后自动提炼对话内容到记忆系统（延迟到下次 SessionStart 处理）
- **全局维护 (global_sleep)** — 定期整理、压缩、拆分、交叉引用维护

### 1.2 技术选型依据

| 维度 | 选型 | 理由 |
|------|------|------|
| 扩展方式 | Claude Code Plugin | 自包含、可分发、生命周期完整 |
| 记忆推理 | Subagent (memory-agent) | 使用会话自身 auth，无需额外 API key；隔离上下文 |
| 自动化 | Hooks (command 类型) | 覆盖 SessionStart / SessionEnd / PreCompact 生命周期事件 |
| 用户入口 | Skills (/memory-*) | 提供显式命令；description 引导 Claude 自动调用 |
| 数据持久化 | `~/.aria-memory/` | 固定路径，不依赖未文档化的环境变量，跨 plugin 更新持久 |
| 对话记录获取 | `transcript_path` (hook 输入 JSON 字段) | 所有 hook 事件均携带此字段，指向 session JSONL 文件 |

---

## 2. 架构设计

### 2.1 系统架构图

```
┌───────────────────────────────────────────────────────────┐
│                    Claude Code Session                     │
│                                                           │
│  ┌─────────────┐   ┌─────────────────────────────────┐   │
│  │  主 Agent    │   │         Plugin: aria-memory      │   │
│  │  (Claude)    │   │                                   │   │
│  │             │   │  ┌───────────┐  ┌────────────┐   │   │
│  │  读取 index │◄──┤  │ Hooks     │  │ Skills     │   │   │
│  │  作为上下文  │   │  │           │  │            │   │   │
│  │             │   │  │ •Session  │  │ •/memory   │   │   │
│  │  调用 Agent │──►│  │  Start    │  │ •/remember │   │   │
│  │  工具触发   │   │  │ •Stop     │  │ •/wrapup   │   │   │
│  │  subagent   │   │  │ •Post     │  │ •/sleep    │   │   │
│  │             │   │  │  Compact  │  │ •/mstatus  │   │   │
│  └─────────────┘   │  └─────┬─────┘  └─────┬──────┘   │   │
│                     │        │              │           │   │
│                     │        ▼              ▼           │   │
│                     │  ┌─────────────────────────────┐ │   │
│                     │  │   Subagent: memory-agent     │ │   │
│                     │  │   (隔离上下文，拥有文件工具)   │ │   │
│                     │  │                               │ │   │
│                     │  │  Read / Write / Edit /        │ │   │
│                     │  │  Grep / Glob / Bash           │ │   │
│                     │  └──────────┬────────────────────┘ │   │
│                     │             │                       │   │
│                     └─────────────┼───────────────────────┘   │
│                                   │                           │
└───────────────────────────────────┼───────────────────────────┘
                                    ▼
                    ┌───────────────────────────────┐
                    │     ~/.aria-memory/            │
                    │                               │
                    │  index.md          (随身索引)  │
                    │  meta.json         (元数据)    │
                    │  personality.md    (交互风格)   │
                    │  knowledge/        (知识库)    │
                    │  impressions/      (印象索引)   │
                    │  impressions/archived/         │
                    └───────────────────────────────┘
```

### 2.2 数据流

```
SessionStart ──► command hook 读取 index.md ──► 注入 additionalContext 给主 Agent
      │                                          (含 pending wrapup 检查 + auto-maintain 提示)
      │
      ├─ [核心] 若有 pendingWrapups ──► prompt 引导主 Agent 调用 memory-agent (session_wrapup)
      ├─ [自配置] 若无 maintenance loop ──► prompt 引导主 Agent 用 /loop 创建定时任务
      │
      ▼
用户对话进行中
      │
      ├─ 主 Agent 自主判断需要查询记忆 ──► 调用 memory-agent subagent (query)
      ├─ 主 Agent 自主判断需要记住信息 ──► 调用 memory-agent subagent (remember)
      ├─ 用户手动 /memory [query]      ──► 触发 skill → memory-agent (query)
      └─ 用户手动 /remember [content]  ──► 触发 skill → memory-agent (remember)
      │
      ▼
PreCompact ──► command hook 记录 compact 时间戳到 meta.json（标记本次会话需要 wrapup）
      │
      ▼
SessionEnd ──► command hook 记录 transcript 路径到 meta.json pendingWrapups
      │
      ▼
下次 SessionStart ──► 检测 pendingWrapups ──► 引导 Claude 调用 memory-agent 处理
      │
      ▼
每 6 小时 (/loop) ──► /memory-sleep ──► memory-agent subagent (global_sleep 7步维护)
      │
      ▼
SessionStart 检查 loop 存活 ──► 过期则重建
```

> **核心设计决策：延迟 Wrapup**
>
> 由于 Claude Code plugin hooks 仅支持 `command` 和 `prompt` 两种类型（无 `agent` 类型），
> 且同一事件内的 hooks 并行执行（无顺序保证），**同步 wrapup 不可行**。
>
> 因此 wrapup 采用**延迟处理模式**：SessionEnd 记录 pending，下次 SessionStart 处理。
> 两次会话之间存在短暂的记忆空窗期，但由于 transcript 文件（JSONL）由 Claude Code 自动维护并持久化，
> 数据不会丢失，只是处理时机延后。

---

## 3. 插件目录结构

```
aria-memory/
├── .claude-plugin/
│   └── plugin.json                    # 插件清单
│
├── agents/
│   └── memory-agent.md                # 核心记忆 Agent（完整系统提示词）
│
├── skills/
│   ├── memory/
│   │   └── SKILL.md                   # /memory [query] — 查询记忆
│   ├── remember/
│   │   └── SKILL.md                   # /remember [content] — 存储记忆
│   ├── memory-wrapup/
│   │   └── SKILL.md                   # /memory-wrapup — 手动会话收尾
│   ├── memory-sleep/
│   │   └── SKILL.md                   # /memory-sleep — 手动全局维护
│   ├── memory-status/
│   │   └── SKILL.md                   # /memory-status — 查看记忆系统状态
│   └── memory-auto-maintain/
│       └── SKILL.md                   # /memory-auto-maintain — 自动配置维护定时任务
│
├── hooks/
│   ├── hooks.json                     # Hook 配置（仅 command 类型）
│   ├── session-start.sh               # SessionStart: 注入 index.md + pending 检查 + auto-maintain 提示
│   ├── session-end.sh                 # SessionEnd: 记录 transcript 路径到 pendingWrapups
│   └── pre-compact.sh                 # PreCompact: 记录 compact 时间戳
│
├── scripts/
│   ├── init-memory-dir.sh             # 初始化记忆目录结构
│   └── memory-status.sh               # 读取记忆系统状态信息
│
└── README.md
```

---

## 4. 各组件详细设计

### 4.1 Plugin Manifest (`plugin.json`)

```json
{
  "name": "aria-memory",
  "version": "0.1.0",
  "description": "Persistent long-term memory system for Claude Code with multi-layer retrieval, automatic session wrapup, and periodic maintenance.",
  "author": {
    "name": "ar8327"
  },
  "license": "MIT",
  "keywords": ["memory", "context", "persistence", "knowledge-management"]
}
```

### 4.2 Memory Agent Subagent (`agents/memory-agent.md`)

这是整个插件的核心，直接移植并适配 HappyClaw 的记忆管理系统提示词。

```yaml
---
name: memory-agent
description: |
  Persistent memory management agent. Use this agent for:
  - Querying long-term memory about past conversations, user preferences, project knowledge
  - Storing important information for future recall
  - Processing session transcripts into structured memory
  - Performing periodic memory maintenance and optimization

  <example>
  Context: User asks about something discussed in a previous session
  user: "我们之前讨论的那个数据库迁移方案是什么来着？"
  assistant: "Let me check your long-term memory for that discussion."
  <commentary>
  The user is referencing a past conversation. The memory-agent should be triggered to search through impressions and knowledge files.
  </commentary>
  </example>

  <example>
  Context: User shares important personal or project information
  user: "记住，我们的生产数据库用的是 PostgreSQL 15，部署在 AWS RDS 上"
  assistant: "I'll store this in your long-term memory."
  <commentary>
  The user explicitly asks to remember something. memory-agent should classify and store this as project infrastructure knowledge.
  </commentary>
  </example>

  <example>
  Context: Claude learns something important during the conversation
  user: "这个项目的 CI/CD 用的是 GitHub Actions，部署到 Vercel"
  assistant: [after helping with the task, stores the infrastructure info]
  <commentary>
  Important project context was revealed. memory-agent should be triggered to remember this for future sessions.
  </commentary>
  </example>

model: sonnet
color: magenta
effort: high
---
```

**系统提示词**（以下为核心内容，从 HappyClaw 适配）：

```markdown
你是一个记忆管理系统。你的职责是管理和维护用户的长期记忆。

## 环境说明

你运行在 Claude Code Plugin 环境中。记忆存储目录通过请求参数传入。
你拥有 Read, Write, Edit, Grep, Glob 工具来操作记忆文件。

## 请求格式

你会收到一个 JSON 格式的请求（在用户消息中），格式如下：

{
  "type": "query" | "remember" | "session_wrapup" | "global_sleep",
  "memoryDir": "/path/to/memory/dir",
  // type-specific fields...
}

## 你的工作目录

记忆目录结构：

- index.md — 随身索引（~200 条上限）
- meta.json — 元数据（indexVersion、totalImpressions、totalKnowledgeFiles、pendingWrapups）
- knowledge/ — 按领域组织的详细知识
- impressions/ — 按会话组织的语义索引文件
- impressions/archived/ — 超过 6 个月的旧 impression
- personality.md — 用户交互风格记录

注意：对话记录（transcripts）不复制到记忆目录。Claude Code 自动维护 transcript 文件于
~/.claude/projects/[project-path]/[session-id].jsonl，wrapup 时直接读取原始路径。

[... 完整的 query/remember/session_wrapup/global_sleep 处理流程 ...]
[... 索引自我修复规则 ...]
[... 硬规则 ...]
```

> **适配要点**：
> 1. 移除 `state.json` 相关逻辑（Claude Code 无主服务进程同步游标概念）
> 2. 移除渠道/群组概念（Claude Code 是单用户 CLI 环境）
> 3. `memoryDir` 路径通过请求参数传入，不再依赖环境变量
> 4. 对话记录从 `transcript_path` 文件复制而来，不再从数据库导出
> 5. session_wrapup 的 transcript 来源是 Claude Code 的对话记录文件，格式为 JSONL

### 4.3 Skills 设计

#### 4.3.1 `/memory [query]` — 查询记忆

```yaml
---
name: memory
description: |
  Query the long-term memory system. Use when the user asks about past conversations,
  previously discussed topics, stored preferences, or project knowledge from earlier sessions.
  TRIGGER when: user references past conversations, asks "do you remember", wants to recall
  something discussed before, or needs context from previous sessions.
argument-hint: <query>
allowed-tools: [Agent]
---

Use the memory-agent subagent to query long-term memory.

Pass this request to the memory-agent:

{
  "type": "query",
  "memoryDir": "!`echo $HOME/.aria-memory`",
  "query": "$ARGUMENTS",
  "context": "User is in project: !`pwd`. Current date: !`date +%Y-%m-%d`"
}

Report the memory-agent's findings to the user concisely. If nothing was found, say so.
```

> **说明**：`memoryDir` 通过 skill 的 `!`command`` 预处理语法动态解析 `$HOME/.aria-memory` 为实际绝对路径。该语法在 Claude 看到 skill 内容前执行。

#### 4.3.2 `/remember [content]` — 存储记忆

```yaml
---
name: remember
description: |
  Store information in long-term memory. Use when the user explicitly asks to remember
  something, or when important information is shared that should persist across sessions.
  TRIGGER when: user says "remember this", "store this", "save this for later", or shares
  critical project/personal information.
argument-hint: <content to remember>
allowed-tools: [Agent]
---

Use the memory-agent subagent to store this information.

Pass this request to the memory-agent:

{
  "type": "remember",
  "memoryDir": "!`echo $HOME/.aria-memory`",
  "content": "$ARGUMENTS",
  "importance": "normal",
  "context": "Project: !`pwd`. Date: !`date +%Y-%m-%d`"
}

Confirm to the user that the information has been stored.
```

#### 4.3.3 `/memory-wrapup` — 手动会话收尾

```yaml
---
name: memory-wrapup
description: |
  Manually trigger session wrapup to process the current conversation into long-term memory.
  Use before ending a long or important session to ensure key information is captured.
  TRIGGER when: user says "save this session", "wrap up memory", or before ending an
  important conversation.
allowed-tools: [Agent, Read, Bash]
---

Trigger a manual session wrapup:

1. Find the current session's transcript file (check recent files in the transcripts directory)
2. Pass to memory-agent subagent:

{
  "type": "session_wrapup",
  "memoryDir": "!`echo $HOME/.aria-memory`",
  "transcriptFile": "<path to transcript>",
  "sessionDate": "!`date +%Y-%m-%d`"
}

Report what was captured and stored.
```

#### 4.3.4 `/memory-sleep` — 手动全局维护

```yaml
---
name: memory-sleep
description: |
  Trigger global memory maintenance (global_sleep). This performs index compaction,
  knowledge file splitting, cross-reference maintenance, and cleanup.
  Only needed periodically or when memory feels cluttered.
allowed-tools: [Agent]
---

Trigger global memory maintenance:

{
  "type": "global_sleep",
  "memoryDir": "!`echo $HOME/.aria-memory`"
}

This will perform the 7-step maintenance process:
1. Backup index.md
2. Compact index.md (capacity-based cleanup)
3. Expire old reminders and archive old impressions
4. Split/merge knowledge files
5. Self-audit index quality
6. Update personality.md
7. Update meta.json

Report a summary of what was done.
```

#### 4.3.5 `/memory-status` — 查看状态

```yaml
---
name: memory-status
description: |
  Show the current status of the memory system: file counts, index size,
  last maintenance time, etc.
allowed-tools: [Read, Glob, Bash]
---

Read and report memory system status:

1. Read meta.json from `$HOME/.aria-memory`
2. Count files: !`ls $HOME/.aria-memory/knowledge/ 2>/dev/null | wc -l`
3. Count impressions: !`ls $HOME/.aria-memory/impressions/ 2>/dev/null | wc -l`
4. Index lines: !`wc -l $HOME/.aria-memory/index.md 2>/dev/null`
5. Read meta.json for last maintenance time

Present a concise status dashboard.
```

#### 4.3.6 `/memory-auto-maintain` — 设置维护定时任务

```yaml
---
name: memory-auto-maintain
description: |
  Set up automatic memory maintenance using /loop. Creates a recurring
  loop that triggers /memory-sleep periodically.
allowed-tools: [Bash]
---

Set up automatic memory maintenance using the /loop feature:

Run `/loop 6h /memory-sleep` to create a recurring loop that triggers global memory maintenance every 6 hours.

If the user asks about maintenance status, check when the last global_sleep was run by reading meta.json:
!`cat $HOME/.aria-memory/meta.json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('lastGlobalSleepAt','never'))" 2>/dev/null || echo "never"`

Note: /loop is session-scoped — it will stop when the session ends. Next SessionStart will remind to set it up again if needed.
```

> **设计说明**：
> - 使用 Claude Code 内置的 `/loop` 命令实现 session-scoped 定时任务
> - `/loop 6h /memory-sleep` 每 6 小时触发一次全局维护
> - `/loop` 是 session-scoped，进程退出即消失
> - SessionStart hook 中检查 lastGlobalSleepAt，超过 24h 时提示用户考虑维护
> - 不再自动创建 loop——由用户决定是否需要

### 4.4 Hooks 设计

#### 4.4.1 Hook 配置 (`hooks/hooks.json`)

```json
{
  "description": "Aria Memory Plugin lifecycle hooks — deferred wrapup + auto-maintenance",
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/session-end.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/pre-compact.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

> **Hook 设计说明**：
>
> Claude Code plugin hooks 仅支持 `command` 和 `prompt` 两种类型（无 `agent` 类型），
> 且同一事件内多个 hooks **并行执行**（无顺序保证）。因此采用**延迟 wrapup** 策略：
>
> - **SessionStart**：注入记忆上下文 + 检测并处理 pending wrapups
> - **SessionEnd**：记录 transcript 路径到 pendingWrapups，下次 SessionStart 处理
> - **PreCompact**：记录 compact 时间戳（标记本次会话有内容需要 wrapup）

#### 4.4.2 SessionStart Hook (`hooks/session-start.sh`)

作用：会话开始时注入记忆上下文 + 检查 pending wrapups + 引导自动配置维护定时任务。

```bash
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
if [ -f "$MEMORY_DIR/meta.json" ]; then
  SLEEP_INFO=$(python3 - "$MEMORY_DIR/meta.json" << 'PYEOF'
import json, sys, time
from datetime import datetime
meta = json.load(open(sys.argv[1]))
last = meta.get('lastGlobalSleepAt')
if not last:
    print('never 999999')
else:
    diff = time.time() - datetime.fromisoformat(last).timestamp()
    print(f'{last} {int(diff / 3600)}')
PYEOF
  ) 2>/dev/null
  SLEEP_INFO="${SLEEP_INFO:-never 999999}"
  LAST_SLEEP=$(echo "$SLEEP_INFO" | awk '{print $1}')
  HOURS_AGO=$(echo "$SLEEP_INFO" | awk '{print $2}')
fi

CONTEXT="$CONTEXT\n\n## Memory Maintenance\n\nLast global_sleep: $LAST_SLEEP ($HOURS_AGO hours ago)\n\nIf last global_sleep was more than 24 hours ago and the session seems idle, consider suggesting /memory-sleep to the user. Do not run maintenance automatically without user awareness."

if [ -n "$CONTEXT" ]; then
  python3 -c "
import json, sys
ctx = sys.stdin.read()
out = {'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': ctx}}
print(json.dumps(out, ensure_ascii=False))
" <<< "$(echo -e "$CONTEXT")"
fi

exit 0
```

#### 4.4.3 SessionEnd Hook (`hooks/session-end.sh`)

作用：会话结束时，记录 transcript 路径到 pendingWrapups，供下次 SessionStart 处理。

> **为什么用 SessionEnd 而非 Stop**：`Stop` 在主 Agent 每次完成响应时触发（过于频繁），
> `SessionEnd` 仅在会话真正结束时触发一次，是记录待处理 wrapup 的正确时机。

```bash
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

exit 0
```

#### 4.4.4 PreCompact Hook (`hooks/pre-compact.sh`)

作用：上下文压缩前，记录 compact 时间戳。transcript 文件由 Claude Code 自动维护，
不需要在此处复制——SessionEnd hook 会在会话结束时统一记录。

> **为什么不在 PreCompact 做更多工作**：PreCompact 仅支持 `command` hook（无法触发 agent），
> 且同一事件内的 hooks 并行执行。虽然 PostCompact 事件可用于 compact 后重注入上下文，
> 当前方案为简化实现暂不使用，完整 wrapup 延迟到下次 SessionStart。
> 未来可增加 PostCompact hook 在 compact 后自动重注入 index.md。

```bash
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
```

### 4.5 初始化脚本 (`scripts/init-memory-dir.sh`)

```bash
#!/bin/bash
# Initialize the memory directory structure

MEMORY_DIR="$HOME/.aria-memory"

mkdir -p "$MEMORY_DIR"/{knowledge,impressions/archived}

# Create index.md if not exists
if [ ! -f "$MEMORY_DIR/index.md" ]; then
  cat > "$MEMORY_DIR/index.md" << 'EOF'
# 随身索引

## 关于用户
<!-- 用户身份、偏好、技能等（~30条） -->

## 活跃话题
<!-- 当前关注的项目、技术、问题等（~50条） -->

## 重要提醒
<!-- 带时间限定的提醒事项（~20条） -->

## 近期上下文
<!-- 最近对话中的关键信息（~50条） -->

## 备用
<!-- 降级候选，仍有价值但优先级较低（~50条） -->
EOF
fi

# Create meta.json if not exists
if [ ! -f "$MEMORY_DIR/meta.json" ]; then
  cat > "$MEMORY_DIR/meta.json" << 'EOF'
{
  "indexVersion": 0,
  "totalImpressions": 0,
  "totalKnowledgeFiles": 0,
  "pendingWrapups": [],
  "compactionEvents": [],
  "lastGlobalSleepAt": null
}
EOF
fi

# Create personality.md if not exists
if [ ! -f "$MEMORY_DIR/personality.md" ]; then
  echo "# 用户交互风格" > "$MEMORY_DIR/personality.md"
  echo "" >> "$MEMORY_DIR/personality.md"
  echo "（尚无足够数据，待 global_sleep 分析后自动生成）" >> "$MEMORY_DIR/personality.md"
fi
```

---

## 5. 关键适配点：从 HappyClaw 到 Claude Code

### 5.1 架构差异对照

| 维度 | HappyClaw | Claude Code Plugin |
|------|-----------|-------------------|
| Memory Agent 运行方式 | 独立子进程，持久 SDK query session | Subagent，每次调用独立上下文 |
| 通信协议 | JSON-line stdin/stdout + requestId | Agent tool 参数 → subagent 返回值 |
| 对话记录来源 | SQLite 数据库导出 | `transcript_path` hook 公共字段指向的文件 |
| 用户模型 | 多用户 (userId 隔离) | 单用户 |
| 渠道/群组 | 多渠道（WhatsApp 群组等） | 无，单一 CLI 交互 |
| state.json | 主服务进程管理消息同步游标 | 不需要（无数据库同步概念） |
| 定时任务 | 主服务 30 分钟检查 + 条件触发 | 用户手动设置 `/loop 6h /memory-sleep`，SessionStart 提示 |
| index.md 注入 | agent-runner 构建 system prompt 时嵌入 | SessionStart hook 注入 additionalContext |
| OAuth/Auth | 共享主 agent 的 session 目录 | 使用 Claude Code 会话自身 auth |

### 5.2 需要移除的功能

1. **state.json 管理** — 无进程间同步需求
2. **渠道/群组标签** — 单用户 CLI 环境，无渠道概念
3. **多用户隔离** — 单用户
4. **消息游标追踪** — 无数据库消息同步
5. **Bearer token 认证** — 无 HTTP API 层
6. **idle timeout / 进程池** — 非持久进程

### 5.3 需要适配的功能

1. **transcript 格式解析** — Claude Code 的 transcript 文件格式为 JSONL（每行一个 JSON 对象），包含 `type`（user/assistant/system/tool_result 等）、`message.role`、`message.content`、`timestamp` 等字段
2. **session_wrapup 触发方式** — 从"容器退出异步触发"改为**延迟处理**：SessionEnd 记录 pending → 下次 SessionStart 引导 Claude 调用 memory-agent 处理
3. **memoryDir 传递** — 固定路径 `~/.aria-memory/`，通过 skill 的 `!`echo $HOME/.aria-memory`` 动态解析
4. **index.md 注入** — 从 system prompt 构建时嵌入改为 SessionStart hook additionalContext
5. **global_sleep 调度** — 从主服务定时检查改为 `/loop 6h /memory-sleep`（用户手动设置）

### 5.4 新增的功能

1. **延迟 Wrapup 机制** — SessionEnd 记录 transcript 路径到 pendingWrapups，下次 SessionStart 自动检测并引导处理（HappyClaw 也是异步的，逻辑类似）
2. **PreCompact 标记** — 记录 compact 时间戳，辅助后续 wrapup 理解会话完整性
3. **pendingWrapups 核心流程** — SessionStart 检查 pending，prompt 引导主 Agent 补处理（非兜底，而是主路径）
4. **Skill 驱动的维护** — 通过 `/memory-auto-maintain` skill 引导用户设置 `/loop` 定时维护

---

## 6. 记忆系统提示词适配要点

Memory Agent 的系统提示词是整个系统的灵魂。从 HappyClaw 移植时的关键修改：

### 6.1 工作目录说明

```diff
- 你的工作目录是用户的记忆存储区。
+ 你的工作目录通过请求中的 memoryDir 字段指定。所有文件操作都基于此目录。
+ 使用 Read/Write/Edit 工具时，确保路径以 memoryDir 为前缀。
```

### 6.2 请求类型

```diff
- // JSON-line stdin 协议
- interface MemoryRequest {
-   requestId: string;
-   type: 'query' | 'remember' | 'session_wrapup' | 'global_sleep';
-   chatJid?: string;
-   channelLabel?: string;
-   groupFolder?: string;
-   ...
- }
+ // 纯文本 JSON 请求（通过 Agent tool prompt 传入）
+ {
+   "type": "query" | "remember" | "session_wrapup" | "global_sleep",
+   "memoryDir": "/path/to/memory",
+   "query": "...",           // query only
+   "content": "...",         // remember only
+   "importance": "high|normal", // remember only
+   "transcriptFile": "...", // session_wrapup only
+   "context": "..."         // optional context (project path, date, etc.)
+ }
```

### 6.3 Session Wrapup 适配

```diff
- 1. 读取 transcripts/ 中的新对话记录（基于 chatJid 游标）
+ 1. 读取请求中 transcriptFile 指定的对话记录文件
+    文件格式为 Claude Code JSONL transcript，包含 role/content 等字段
+    解析时提取 user 和 assistant 的对话内容

- 5. 交叉修复：如果本次对话中引用了旧记忆...检查对应的旧 impressions 索引文件
+ 5. 交叉修复逻辑保持不变

- ⚠️ 只操作 meta.json...绝对不要读写 state.json
+ ⚠️ 操作 meta.json 时，更新 totalImpressions、totalKnowledgeFiles 计数
+    从 pendingWrapups 数组中移除已处理的 transcriptFile
```

### 6.4 硬规则适配

```diff
- 禁止读写 state.json
+ （移除，无 state.json）

- 渠道维度：impression 文件应记录对话发生的渠道/群组名
+ 项目维度：impression 文件应记录对话发生时的项目目录（从 context 中获取）

  其余硬规则保持不变：
  - 时间绝对化
  - 索引只放索引不放内容
  - 自述优先原则
  - 分区上限
  - 索引条目格式 [YYYY-MM-DD]
  - 信息保真（保留限定词）
  - compact 前备份
```

---

## 7. 技术验证结果

所有关键技术点已通过文档研究和实际文件分析验证完毕。以下是完整结果：

### 7.1 ✅ 已验证（影响架构设计的关键发现）

| 验证项 | 结果 | 对方案的影响 |
|--------|------|-------------|
| Hook 类型 | **仅 `command` 和 `prompt` 两种**，无 `agent` 类型 | 无法通过 hook 同步触发 agent wrapup → 改为延迟处理 |
| Hook 事件列表 | 27 种，包括 PreToolUse, PostToolUse, Stop, SubagentStop, UserPromptSubmit, SessionStart, SessionEnd, PreCompact, **PostCompact**, Notification 等。PostCompact 可用于 compact 后重注入 | 当前方案仍采用延迟处理（简化实现）；未来可用 PostCompact 重注入 index.md 消除 compact 后的空窗 |
| Hook 执行模型 | 同一 matcher 内多个 hooks **并行执行**，无顺序保证 | 无法在同一事件内实现 "保存→wrapup→重注入" 顺序流 |
| `${CLAUDE_PLUGIN_DATA}` | 官方支持的持久数据目录，跨插件更新保留 | 当前方案使用固定路径 `~/.aria-memory/` 以保持简单和可预测；`${CLAUDE_PLUGIN_DATA}` 可作为备选 |
| CronCreate | **非直接可用工具**，应使用 `/loop` 或 `/schedule` | 维护定时任务改用 `/loop 6h /memory-sleep` |

### 7.2 ✅ 已验证（确认可用的能力）

| 验证项 | 结果 |
|--------|------|
| Claude Code 支持 plugin 系统 | 是，`claude plugin` 命令完整可用 |
| Plugin 目录结构 | `.claude-plugin/plugin.json` + `agents/` + `skills/` + `hooks/` |
| `--plugin-dir` 本地加载 | 支持，用于开发测试 |
| `${CLAUDE_PLUGIN_ROOT}` 变量 | 在 hooks 和 skills 中均可用 |
| Hook 输入包含 `transcript_path` | 是，hook 输入 JSON 的公共字段 |
| Subagent 拥有文件工具 | 是，Read/Write/Edit/Grep/Glob/Bash |
| `additionalContext` 注入 | 通过 `hookSpecificOutput` JSON 输出，SessionStart 可注入上下文给 Claude |
| Skill `!`command`` 语法 | 在 Claude 看到 skill 内容前执行，可用于动态路径解析 |
| Skill `$ARGUMENTS` | 用户调用 skill 时的参数，自动替换到 skill 内容中 |
| Skills 调用 agent | 通过 `allowed-tools: [Agent]` + 自然语言引导 Claude 使用 Agent tool |

### 7.3 ✅ Transcript 文件格式（已确认）

Claude Code 的 session transcript 文件位于 `~/.claude/projects/[project-path]/[session-id].jsonl`。

**格式**：JSONL（每行一个 JSON 对象），主要记录类型：

| type | 说明 | 关键字段 |
|------|------|----------|
| `user` | 用户消息 | `message.role: "user"`, `message.content: string` |
| `assistant` | Claude 响应 | `message.role: "assistant"`, `message.content: [{type, text/tool_use}]` |
| `user` (tool_result) | 工具执行结果 | `message.content: [{type: "tool_result", content, tool_use_id}]` |
| `system` | 系统事件 | `subtype`, `content`, `level` |
| `attachment` | 工具/上下文附件 | `attachment.type` |

**每条记录的公共字段**：`uuid`, `timestamp`, `sessionId`, `cwd`, `version`, `gitBranch`

**session_wrapup 解析策略**：
- 过滤 `type: "user"` (非 tool_result) 和 `type: "assistant"` 的记录
- 提取 `message.content`（user 为 string，assistant 为 content blocks 数组）
- 从 content blocks 中提取 `type: "text"` 的文本内容
- 忽略 `type: "thinking"`、`type: "tool_use"` 等辅助记录

---

## 8. 分阶段实施路线

> 所有技术验证已在方案设计阶段完成（见第 7 节），无需独立验证阶段。

### Phase 1: 插件骨架 + 核心查询/存储

**目标**：搭建插件结构，实现 query 和 remember 的完整链路。

1. 创建插件目录结构（plugin.json + agents/ + skills/ + hooks/）
2. 编写 memory-agent subagent 完整系统提示词（从 HappyClaw 适配）
3. 实现 `init-memory-dir.sh` 初始化脚本
4. 实现 `/memory` 和 `/remember` skills
5. 实现 `SessionStart` hook（注入 index.md + personality.md）
6. 用 `--plugin-dir` 加载测试
7. 端到端测试：存储 → 重启会话 → 查询

**交付物**：可用的 query/remember 功能 + SessionStart 注入

### Phase 2: 延迟 Wrapup

**目标**：实现 SessionEnd 记录 + SessionStart 延迟处理的 wrapup 流程。

1. 实现 `session-end.sh`（SessionEnd hook，记录 transcript 路径到 pendingWrapups）
2. 实现 `pre-compact.sh`（PreCompact hook，记录 compact 时间戳）
3. 编写 memory-agent 的 session_wrapup 处理逻辑（JSONL 解析 + impressions 生成 + knowledge 提炼 + index 更新）
4. 更新 SessionStart hook：检测 pendingWrapups → 引导 Claude 调用 memory-agent 处理
5. 实现 `/memory-wrapup` skill（手动触发）
6. 端到端测试：对话 → 退出 → 新会话 → 验证 pending 处理 → 验证 index 已更新

**交付物**：自动延迟 wrapup 流程

### Phase 3: Global Sleep + 维护 + 打磨

**目标**：实现全局维护，完善所有 skills，准备使用。

1. 实现 `/memory-sleep` skill（7 步维护流程）
2. 实现 `/memory-auto-maintain` skill（引导 `/loop` 设置）
3. 实现 `/memory-status` skill（状态面板）
4. 更新 SessionStart hook：加入 lastGlobalSleepAt 检查和维护提示
5. 调优 memory-agent 提示词（基于实际使用反馈）
6. 编写 README.md
7. `claude plugin validate` 验证

**交付物**：完整可用的 aria-memory 插件

---

## 9. 已知限制与未来方向

### 9.1 当前方案的限制

1. **Subagent 无持久上下文** — 每次调用 memory-agent 都是新上下文，不像 HappyClaw 的持久 query session。每次 query 都需要重新"理解"记忆结构。

   **缓解**：memory-agent 的系统提示词足够详细，加上文件工具的能力，单次调用即可完成检索。

2. **Wrapup 延迟** — 无法在 session 结束时同步执行 wrapup（plugin hooks 无 agent 类型），只能延迟到下次 SessionStart 处理。两次会话之间存在记忆空窗期。

   **缓解**：transcript 文件由 Claude Code 自动维护并持久化，数据不会丢失。用户也可随时手动执行 `/memory-wrapup`。

3. **Compact 后未自动重注入** — 当前方案未使用 PostCompact hook，context compaction 后不会自动重新注入 index.md。（PostCompact 事件实际可用，留作未来优化。）

   **缓解**：compaction 摘要应保留记忆系统的存在感。Claude 可通过 memory-agent 查询获取详情。未来可增加 PostCompact hook 自动重注入。

4. **Global Sleep 依赖用户设置** — `/loop` 是 session-scoped，进程退出即消失。需要用户手动设置 `/loop 6h /memory-sleep`。

   **缓解**：SessionStart hook 提示用户最近维护时间，引导用户在需要时手动触发或设置 loop。

5. **记忆目录单一** — 所有项目共享同一记忆空间 `~/.aria-memory/`。

   **缓解**：index.md 的分区机制天然支持多话题；knowledge/ 按领域组织；impressions 记录项目路径。

6. **additionalContext 非强制** — SessionStart 注入的 pending wrapup 指令依赖 LLM 遵循，理论上可能不执行。

   **缓解**：使用强措辞（CRITICAL / MUST / before responding）在实践中可靠性很高。

### 9.2 未来增强方向

1. **Embedding 检索** — 用本地 embedding 模型对 knowledge/ 文件做向量索引，提升 query 精度
2. **多项目记忆隔离** — 支持 per-project 记忆目录，同时保留全局记忆
3. **MCP Server 扩展** — 将记忆操作暴露为 MCP tools，支持更灵活的调用方式
4. **与 Claude Code 内置 auto-memory 集成** — 与 `~/.claude/projects/` 内置记忆协同而非替代
5. **PostCompact 重注入** — 利用已有的 PostCompact hook 事件，在 context compaction 后自动重注入 index.md，消除 compact 后的记忆空窗
6. **Persistent Subagent** — 若 Claude Code 未来支持持久 subagent，可消除 subagent 无持久上下文的限制
7. **Agent Hook** — 若 Claude Code 未来支持 `type: "agent"` hooks，可实现同步 wrapup（SessionEnd 时自动处理）

---

## 10. 总结

本方案将 HappyClaw 的多层级记忆系统移植到 Claude Code Plugin 体系中，利用：

- **Subagent** 作为记忆推理引擎（替代独立子进程）
- **延迟 Wrapup** 实现 session_wrapup（SessionEnd 记录 → 下次 SessionStart 处理，类似 HappyClaw 的异步模式）
- **Skills** 提供用户交互入口（`/memory`, `/remember`, `/memory-wrapup`, `/memory-sleep` 等）
- **SessionStart Hook** 注入 index.md + 检测 pending wrapups + 引导处理
- **`transcript_path`** 获取对话记录（JSONL 格式，替代数据库导出）
- **`~/.aria-memory/`** 固定路径持久化存储

核心记忆逻辑（四层检索、索引自我修复、session_wrapup、global_sleep 7 步维护）完整保留。

**与原方案的关键差异**：经技术验证，Claude Code plugin hooks 仅支持 `command`/`prompt` 类型（无 `agent` 类型），因此放弃同步 wrapup 设计，采用延迟处理作为主路径。PostCompact 事件可用但当前方案为简化实现暂未使用（留作未来优化）。实质性牺牲：(1) subagent 无持久上下文；(2) 两次会话间的记忆空窗期。
