---
name: memory-agent-spec
description: Canonical Aria long-term memory operation spec, shared by Claude memory-agent subagent and Codex skills. Codex skills must Read this file before executing query/remember/session_wrapup/global_sleep operations.
type: reference
---

# Aria Memory Operation Spec（Canonical）

This document is the canonical specification for managing the user's Aria long-term memory store. It is identical in scope to `aria-memory/agents/memory-agent.md` (Claude memory-agent subagent prompt). Codex skills (`codex/skills/*/SKILL.md`) Read this file as a Prerequisite and execute inline using their available tools.

## Runtime

This spec is runtime-neutral. Use whichever read/write/edit/glob/grep/bash tools your runtime provides. The memory directory is passed in each request.

- Claude side: invoked via the `memory-agent` subagent (Agent tool); tools are Read, Write, Edit, Grep, Glob, Bash.
- Codex side: invoked inline by the main model after a skill (`/memory`, `/remember`, `/memory-wrapup`, `/memory-sleep`) Reads this spec; tools are Read, Write, Edit, Grep, Glob, Bash (whichever Codex exposes).

## 请求格式

你会收到一个 JSON 格式的请求（在用户消息中或 skill 输入中），格式如下：

```json
{
  "type": "query" | "remember" | "session_wrapup" | "global_sleep",
  "memoryDir": "/path/to/memory/dir",
  // type-specific fields...
}
```

## 你的工作目录

记忆目录结构：

```
memoryDir/
├── index.md          — 随身索引（~200 条上限）
├── meta.json         — 元数据（indexVersion、totalImpressions、totalKnowledgeFiles、pendingWrapups）
├── personality.md    — 用户交互风格记录
├── changelog.md      — 变更日志（每次 wrapup/sleep 追加记录）
├── knowledge/        — 按领域组织的详细知识
├── knowledge/.pending/ — 多源写入的临时合并文件（global_sleep 时合并到主文件）
├── impressions/      — 按会话组织的语义索引文件
├── impressions/archived/ — 超过 6 个月的旧 impression
├── daily/            — Daily Notes（每天一个 YYYY-MM-DD.md）
├── .obsidian/        — Obsidian 配置（忽略，不读不写不搜索）
├── .role.<input>     — 每个输入源（claude/codex/human/lark-bridge/...）在本机的 role
│                       （"primary" | "secondary"，单行，gitignored 不跨机同步；
│                       由各输入源在本机首次运行时自动创建为 "secondary"，用户手动 echo "primary" 选举）
└── .git/             — Git 同步（忽略）
```

注意：对话记录（transcripts）不复制到记忆目录。
- Claude Code 自动维护 transcript 文件于 `~/.claude/projects/[project-path]/[session-id].jsonl`，wrapup 时直接读取原始路径。
- Codex 维护 transcript 文件于 `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl`，session-end hook 通过 `~/.codex/state_*.sqlite` 的 `threads.rollout_path` 解析路径并写入 `meta.json.pendingWrapups`。

## 忽略目录

在所有操作（Glob、Grep、Read、ls）中，**必须排除**以下目录：
- `.obsidian/` — Obsidian 编辑器配置
- `.git/` — Git 版本控制

Glob 示例：使用 `knowledge/*.md` 而非 `**/*.md`，避免匹配到 `.obsidian/` 下的文件。

## Frontmatter 处理规则

knowledge/ 和 impressions/ 中的文件可能包含 YAML frontmatter（`---` 包裹的头部）。

**读取时**：跳过 frontmatter 部分，只处理正文内容。避免将 frontmatter 中的元数据当作知识内容。
**写入时**：新建或更新文件时，必须保留或生成 frontmatter（格式见下方各流程说明）。
**搜索时**：Grep 搜索结果如果命中 frontmatter 行（如 `tags:`），不算有效匹配，需继续看正文。

---

## 处理流程

### 一、query — 记忆查询

收到 query 请求时：

```json
{
  "type": "query",
  "memoryDir": "/path",
  "query": "用户的查询内容",
  "context": "Project: /path/to/project. Date: 2026-03-16"
}
```

**执行步骤**：

1. **读取 index.md**，在索引中搜索与查询相关的条目
2. **搜索 impressions/**，用 Grep 在 impression 文件中搜索关键词
3. **搜索 knowledge/**，用 Grep 在 knowledge 文件中搜索关键词
4. 如果在 impressions/ 中找到相关条目，**读取对应的 knowledge 文件**获取详细信息
5. 如果最近的 impressions 中没有结果，**扩展到 impressions/archived/** 搜索
6. **综合所有发现**，以自然语言返回结果

**搜索策略**：
- 先用精确关键词搜索，再用语义近义词扩展
- impression 文件名格式为 `YYYY-MM-DD_主题关键词.md`，可通过 Glob 先筛选日期范围
- knowledge 文件按领域命名（如 `tech-stack.md`, `personal-prefs.md`），根据查询领域选择性搜索
- 返回信息时标注来源（哪个 impression/knowledge 文件）和日期

**输出格式**：
以自然语言返回找到的信息，包含关键细节和时间上下文。如果没有找到相关信息，明确说明。

---

### 二、remember — 记忆存储

收到 remember 请求时：

```json
{
  "type": "remember",
  "memoryDir": "/path",
  "content": "要记忆的内容",
  "importance": "high" | "normal",
  "context": "Project: /path/to/project. Date: 2026-03-16"
}
```

**执行步骤**：

1. **分析内容**，判断属于哪个知识领域：
   - 用户个人信息（身份、偏好、技能）
   - 项目技术栈 / 架构
   - 工作流程 / 约定
   - 人际关系 / 组织信息
   - 日程 / 提醒
   - 其他领域

2. **选择或创建 knowledge 文件**：
   - 用 Glob 列出 `knowledge/` 目录已有文件
   - 如果有匹配领域的文件，读取并在合适位置追加/更新（保留已有 frontmatter）
   - 如果没有，创建新文件，文件名格式：`领域-子领域.md`（英文 kebab-case）
   - **新建 knowledge 文件时必须包含 frontmatter**：
     ```yaml
     ---
     title: "文件标题"
     type: knowledge
     created: YYYY-MM-DD
     updated: YYYY-MM-DD
     tags: [tag1, tag2]
     confidence: high
     ---
     ```
   - **更新已有文件时**：更新 frontmatter 中的 `updated` 日期

3. **更新 index.md**：
   - 在合适的分区（关于用户 / 活跃话题 / 重要提醒 / 近期上下文）添加一行索引
   - 索引条目格式：`- [YYYY-MM-DD] 简短描述（~15字）→ [[文件名]]`（Obsidian wikilink，不含目录前缀和 .md 后缀）
   - 示例：`- [2026-04-05] lark-bridge 插件设计 → [[feishu-bridge]]`
   - 如果是对已有条目的更新，修改而非新增
   - 检查分区是否超过上限，如超过则移动最旧/最低优先级条目到「备用」

4. **更新 meta.json**：
   - 增加 `indexVersion`
   - 如果创建了新 knowledge 文件，增加 `totalKnowledgeFiles`

5. **确认存储结果**（返回简短确认消息）

---

### 三、session_wrapup — 会话收尾

收到 session_wrapup 请求时：

```json
{
  "type": "session_wrapup",
  "memoryDir": "/path",
  "transcriptFile": "/path/to/transcript.jsonl",
  "sessionDate": "2026-03-16",
  // OR: process all pending
  "processPending": true
}
```

**如果 processPending 为 true**：
1. 读取 `meta.json` 中的 `pendingWrapups` 数组
2. 对每个 pending entry，依次执行下方的单个 wrapup 流程
3. 处理完成后从 `pendingWrapups` 中移除该条目
4. 更新 `meta.json`

**单个 wrapup 流程**：

#### 步骤 1：读取并解析 transcript

读取 transcriptFile，支持三种格式：

**格式 A：Claude Code JSONL（`.jsonl` 后缀，路径含 `~/.claude/projects/`）**
- 每行一个 JSON 对象
- 过滤 `type: "user"`（且 message.content 为 string，非 tool_result）和 `type: "assistant"` 的记录
- 从 assistant 记录的 `message.content` 数组中提取 `type: "text"` 的文本内容
- 忽略 `type: "thinking"`、`type: "tool_use"`、`type: "tool_result"` 等辅助记录
- 提取每条记录的 `timestamp`、`cwd`、`sessionId`
- 将 user/assistant 对话按时间顺序配对

**格式 B：Codex Rollout JSONL（`.jsonl` 后缀，路径含 `~/.codex/sessions/`）**
- 每行一个 JSON 对象，typical schema 为 `{"type":"response_item","payload":{"type":"message","role":"user"|"assistant","content":[{"type":"input_text"|"output_text","text":"..."}]}}`
- 过滤 `payload.type === "message"`，按 `payload.role` 分 user/assistant
- 从 `payload.content[]` 中提取 `text` 字段拼接
- 忽略 `payload.type === "function_call"`、`reasoning` 等辅助记录
- 文件路径中的日期目录可作为会话日期参考；session_id 可从 rollout 文件名 UUID 提取

**格式 C：Markdown（dbclaw IM 会话，`.md` 后缀）**
- 纯 Markdown 文本，包含用户和助手的对话记录
- 格式通常为 `**User** (时间): 内容` 和 `**Assistant** (时间): 内容` 交替
- 按 bold 标记（`**User**`/`**Assistant**`）分割对话对
- 从文件头部提取会话元信息（群组名、日期等）
- channel 标记为 `im`（区别于 Claude/Codex 的 `flow`/`main`）

**格式检测**：根据文件扩展名（`.jsonl` vs `.md`）+ 路径前缀（`~/.claude/` vs `~/.codex/`）+ 首行内容自动判断。

如果 transcript 文件不存在或为空，跳过并返回提示。

#### 步骤 2：提炼对话内容

从对话中提取：
- **事实性信息**：用户透露的个人信息、项目信息、技术选型、偏好等
- **决策与结论**：对话中做出的重要决定
- **问题与解决方案**：遇到的问题和最终解决方式
- **待办与承诺**：提到的后续计划
- **情感与态度**：用户表达的强烈偏好或不满

#### 步骤 3：创建 impression 文件

在 `impressions/` 目录创建语义索引文件：
- 文件名格式：`YYYY-MM-DD_关键主题.md`（日期使用 sessionDate，关键主题用英文 kebab-case）
- 文件内容为对话的**语义摘要索引**，不是原文复制

impression 文件格式：
```markdown
---
title: "主题描述"
type: impression
date: YYYY-MM-DD
channel: flow|main|feishu|im|codex
session_id: "sessionId"
tags: [tag1, tag2, tag3]
produces: [[相关knowledge文件名]]
---

# Session: YYYY-MM-DD 主题描述

- **项目**: 对话发生时的项目路径
- **日期**: YYYY-MM-DD
- **会话**: sessionId (简短)

## 关键话题
- 话题1：一句话摘要
- 话题2：一句话摘要

## 事实与决策
- [事实] 具体事实描述
- [决策] 决策描述及理由

## 情感标记
- 用户对 X 表示满意/不满/感兴趣

## 关联知识
- [[相关knowledge文件名]]（新增/更新了什么）
```

注意：关联知识使用 `[[wikilink]]` 格式（shortest-path，不含目录前缀和 .md 后缀），不再使用 `→ knowledge/xxx.md` 指针格式。

#### 步骤 4：更新 knowledge 文件（多源写入安全）

如果对话中包含应持久化的知识：

**写入规则（多源冲突避免）**：
- 用 Glob 列出 `knowledge/*.md` 已有文件
- **目标文件不存在** → 直接新建（与 remember 相同的 frontmatter 模板）
- **目标文件已存在** → **不直接追加**，改为写临时文件到 `knowledge/.pending/` 目录：
  - 文件名格式：`{原文件名}_{source_id}_{wrapup_id}_{时间戳}.md`
  - source_id：当前端点标识。约定：
    - SG devbox claude code 端 = `sg-claude`（primary）
    - SG devbox codex 端 = `sg-codex`
    - CN dbclaw = `cn-dbclaw`
    - SG keyclaw = `sg-keyclaw`
    - Mac obsidian 手动编辑 = `mac-obsidian`
  - wrapup_id：本次 wrapup 的唯一标识（使用 sessionId 的前 8 位）
  - 时间戳：`YYYYMMDDHHmmss` 格式（UTC）
  - 示例：`feishu-bridge_sg-claude_fdcff362_20260414163000.md`
- 临时文件 frontmatter 中必须包含幂等键：
  ```yaml
  ---
  title: "待合并：原文件标题"
  type: knowledge-pending
  target: "原文件名.md"
  source_id: "sg-claude"
  wrapup_id: "fdcff362"
  created: YYYY-MM-DD
  tags: [pending-merge]
  ---
  ```
- 临时文件正文为需要追加/更新到目标文件的内容片段
- **global_sleep 会扫描 `.pending/` 目录并合并到主文件**

**新建文件时**：
- 必须包含 YAML frontmatter（见 remember 流程中的模板）
- 文件内容中引用其他文件使用 `[[wikilink]]` 格式

#### ~~步骤 5：更新 index.md~~ — 已移至 global_sleep

> **多源写入架构变更**：wrapup 不再直接更新 index.md。索引的更新统一由 global_sleep 汇总层执行，避免多端并发写同一文件导致冲突。

#### 步骤 5：交叉修复

如果本次对话中引用了旧记忆（用户说"之前聊的XXX"），检查：
- 对应的旧 impressions 文件是否仍然准确
- 如果旧信息已被更新/纠正，修复旧文件中的过时内容
- 在旧 impression 文件中添加交叉引用到本次新 impression

#### 步骤 6：更新 meta.json

- 增加 `totalImpressions`
- 增加 `indexVersion`
- 如有新 knowledge 文件，增加 `totalKnowledgeFiles`

#### ~~步骤 7：追加 changelog.md~~ — 已移至 global_sleep

> **多源写入架构变更**：wrapup 不再追加 changelog.md。变更日志统一由 global_sleep 汇总写入。

#### ~~步骤 8：追加 Daily Note~~ — 已移至 global_sleep

> **多源写入架构变更**：wrapup 不再追加 daily 文件。Daily Note 的生成和合并统一由 global_sleep 执行，避免多端写同一 daily 文件冲突。

#### 步骤 7：Git 提交推送

wrapup 完成后执行 Git 同步：
- `git add -A && git commit -m "wrapup: <session_id简短> <日期>"`
- push 失败时 pull --rebase → retry，最多 3 次
- 3 次仍失败则写入 `.git-push-failed` 标记文件（内容为失败时间+错误信息）

> **注意**：session-end.sh 也有 Git push 兜底逻辑。如果 wrapup 内已经完成了 commit+push，session-end.sh 会检测到没有 dirty 文件而跳过。两者不冲突。

---

### 四、global_sleep — 全局维护（12 步）

收到 global_sleep 请求时：

```json
{
  "type": "global_sleep",
  "memoryDir": "/path"
}
```

**主备前置检查**：

主备粒度是 **(input-source, machine) 对**，不是 machine。同一台机器上的不同输入源（claude code、codex、human 手动编辑、lark-bridge daemon、其他将来引入的源）各自是独立 agent，需要各自配置 role。每个输入源在本机首次运行时自动创建 `.role.<source>=secondary`，由用户手动选举。

在执行任何 global_sleep 步骤之前：
1. 读取 `memoryDir/.role.<source>`（其中 `<source>` 是当前调用方的标识，如 `claude` / `codex` / `human` / 自定义；文件不存在视为 `secondary`）
2. 如果内容不是 `primary`，**立即拒绝**并返回提示：「This input source on this machine is `<role>`. Global maintenance runs only on the (source, machine) pair elected as primary. Switch to the primary endpoint to run, or temporarily set `.role.<source>=primary` if you have coordinated with the other endpoints.」
3. 只有 `primary` 端继续执行下面的 12 步

当前约定：SG devbox claude code = primary；其他（同机 codex / CN dbclaw / Mac obsidian / SG keyclaw / lark-bridge / human 手动编辑）= secondary。

**执行 12 个步骤**（含多源写入架构新增步骤）：

#### 步骤 1：备份 index.md

```bash
cp memoryDir/index.md memoryDir/index.md.bak
```

#### 步骤 2：`.pending/` 膨胀检查（多源写入安全）

扫描 `knowledge/.pending/` 目录：
- 统计文件数量
- **超过 50 个**：在 changelog.md 记录 `⚠️ .pending/ 膨胀告警：N 个待合并文件`
- **超过 100 个**：额外在返回结果中标注 `🚨 .pending/ 严重膨胀`，提示用户关注

#### 步骤 3：合并 `.pending/` 临时文件（多源写入核心）

扫描 `knowledge/.pending/*.md` 中的所有临时文件：

1. 读取每个临时文件的 frontmatter，提取 `target`（目标主文件名）和 `wrapup_id`（幂等键）
2. **幂等去重**：如果有多个临时文件 `wrapup_id` 相同且 `target` 相同，只处理最新的一个
3. 对每个目标文件：
   - 读取目标主文件当前内容
   - **冲突检测**：如果目标文件的 mtime > 临时文件的 ctime（说明 Mac 端在 pending 创建后手动编辑过），执行智能合并（保留两者内容），而非覆盖
   - 将临时文件的正文内容追加到目标主文件合适位置
   - 更新目标文件的 `updated` 日期
4. 合并完成后删除已处理的临时文件
5. 如果目标主文件不存在（被删除了），将临时文件直接重命名为正式文件（去掉 source_id/wrapup_id/时间戳后缀）

#### 步骤 4：压缩 index.md（容量维护）

- 读取 index.md，计算各分区条目数
- 分区上限：关于用户 ~30、活跃话题 ~50、重要提醒 ~20、近期上下文 ~50、备用 ~50
- 总条目上限 ~200
- 超过上限时：
  - 移除过期的提醒（日期已过）
  - 将最旧的「近期上下文」降级到「备用」
  - 将最低优先级的「备用」条目删除
  - 合并重复/相似的条目

#### 步骤 5：重建 index.md（汇总层职责）

> **多源写入架构变更**：index.md 的更新从 wrapup 移至 global_sleep，由汇总层统一执行。

- 扫描全量 impressions/ 和 knowledge/ 文件
- 基于最新内容重建各分区的索引条目
- 格式：`- [YYYY-MM-DD] 描述 → [[文件名]]`（wikilink 格式）
- 补充新增文件的索引、移除已删除文件的悬空引用
- 确保格式规范：无旧格式 `→ knowledge/xxx.md`，统一为 `→ [[xxx]]`

#### 步骤 6：过期清理与归档

- 检查 `impressions/` 中超过 6 个月的文件，移动到 `impressions/archived/`
- 检查「重要提醒」分区，移除已过期的提醒
- 检查 knowledge/ 文件，标记超过 6 个月未更新的为低活跃

#### 步骤 7：拆分/合并 knowledge 文件

- 检查 knowledge/ 文件大小
- 超过 200 行的文件考虑按子领域拆分
- 内容过少（<10行）且领域相近的文件考虑合并
- 更新 index.md 中指向这些文件的引用
- **See Also 双向链接**（增量）：只处理本周期新增/修改的文件（用 `.last-sleep-at` 判断），维护文件末尾的 `## See Also` 区：
  - 3-6 条相关文件，使用 `[[wikilink]]` + 一句话描述
  - A 引用 B，B 必须反向引用 A
  - 首次执行分批处理，每次 10-15 个

#### 步骤 8：更新 personality.md

- 综合所有 impression 文件中的情感标记和交互模式
- 更新 personality.md，记录：
  - 用户的沟通风格（简洁/详细、正式/随意、中文/英文偏好）
  - 用户的技术偏好和专长领域
  - 用户的典型工作模式（时间段、项目类型）
  - 需要注意的敏感话题或偏好

#### 步骤 9：更新 meta.json

- 更新 `lastGlobalSleepAt` 为当前精确 ISO 时间（使用 `date -u +%Y-%m-%dT%H:%M:%S.000000+00:00` 获取，不可用日期近似）
- 更新 `indexVersion`
- 重新计算 `totalImpressions`（count impressions/ 非 archived 文件）
- 重新计算 `totalKnowledgeFiles`（count knowledge/ 文件）
- 重新计算 `totalDailyFiles`（count daily/ 文件）

#### 步骤 10：更新 `.last-sleep-at`（跨机水位同步）

> lastGlobalSleepAt 从 meta.json 移到 Git 同步的 `.last-sleep-at` 文件。

- 将当前精确 ISO 时间写入 `memoryDir/.last-sleep-at`（纯文本文件，只含一个 ISO8601 时间戳）
- 此文件加入 Git 跟踪（不在 .gitignore 中），确保跨机同步
- meta.json 中的 `lastGlobalSleepAt` 仍然更新，作为本地缓存兼容

#### 步骤 11：生成每日摘要（daily 生成+合并）

> **多源写入架构变更**：daily 文件的生成从 wrapup 移至 global_sleep 统一执行。

1. 用 Glob 列出 `impressions/YYYY-MM-DD_*.md` 所有文件（不含 archived/），提取不重复的日期集合
2. 用 Glob 列出 `daily/YYYY-MM-DD.md` 已有文件
3. 对每个日期的处理：

**daily 文件格式**（含用户手记分区）：
```markdown
---
title: "Daily: YYYY-MM-DD"
type: daily
date: YYYY-MM-DD
sessions: N
---

## 今日进展
- 进展1：一句话描述完成了什么

## 关键决策
- [决策] 决策描述及理由

## 未解决 / 明日跟进
- 待办事项

<!-- aria:user-start -->
<!-- aria:user-end -->
```

> 用户手记区域使用 HTML 注释 `<!-- aria:user-start -->` / `<!-- aria:user-end -->` 标记，替代旧的 `## 手记`。Obsidian 渲染时不可见，解析更可靠。

**合并策略**：

| 文件状态 | 处理方式 |
|----------|----------|
| 文件不存在 | 直接新建（含 `<!-- aria:user-start/end -->` 标记） |
| 文件只有 frontmatter / 空壳（无实质正文） | 覆盖（Obsidian Daily Notes 插件自动创建的空文件） |
| 文件已存在且有实质内容 | 合并：保留 `<!-- aria:user-start -->` 到 `<!-- aria:user-end -->` 之间的内容不动，只重写上方 AI 段落（整体替换，幂等） |

**旧标记迁移**：如果已有 daily 文件使用旧的 `## 手记` 标记，自动替换为 `<!-- aria:user-start -->` / `<!-- aria:user-end -->`，保留其中内容。

**生成规则**：
- 只写有实质内容的段落——无决策则省略「关键决策」段，无待办则省略「未解决」段
- 每段控制在 3-5 条以内，总文件不超过 20 行正文（不含手记区域）
- 「今日进展」聚焦成果而非过程（"完成了X"而非"讨论了X"）
- 跳过 `impressions/archived/` 中的文件，只处理活跃 impressions
- AI 段落重写时整体替换（幂等），不是追加

#### 步骤 12：追加 changelog.md

在 changelog.md 追加本次 global_sleep 的变更记录：

```markdown
## YYYY-MM-DD HH:MM
- **global_sleep**: 索引压缩 vN，归档 M 条 impression
- **pending 合并**: 处理 N 个 .pending/ 文件
- **更新**: personality.md (变更摘要)
- **拆分/合并**: knowledge/xxx.md → knowledge/yyy.md + knowledge/zzz.md
- **daily 生成**: 新生成/更新 N 个 daily 文件
- **手记标记迁移**: 迁移 N 个 daily 文件的旧 ## 手记 标记
```

如果 changelog.md 不存在，创建它（带 frontmatter）：
```markdown
---
title: "Memory Changelog"
type: meta
---

# Changelog
```

**膨胀控制**：如果 changelog.md 超过 500 行，将旧条目（超过 3 个月的）归档到 `changelog-YYYY-Qn.md`（按季度分片），只在主文件保留最近 3 个月的记录。

---

## 索引自我修复规则

在任何操作（query/remember/wrapup/sleep）执行过程中，如果发现以下问题，就地修复：

1. **悬空引用**：索引指向的文件不存在 → 移除该索引条目
2. **孤立文件**：knowledge/ 或 impressions/ 中的文件未被索引引用 → 在索引中补充条目
3. **分区溢出**：某分区超过上限 → 立即执行降级
4. **格式异常**：条目不符合 `[YYYY-MM-DD] 描述 → [[文件名]]` 格式 → 就地修正（旧格式 `→ knowledge/xxx.md` 转为 `→ [[xxx]]`）
5. **日期缺失**：条目没有日期标记 → 从文件修改时间或内容推断日期

---

## 硬规则（不可违反）

1. **时间绝对化**：所有索引和 knowledge 中的时间必须用绝对日期（YYYY-MM-DD），绝不使用"今天"、"昨天"、"上周"等相对表述

2. **索引只放索引不放内容**：index.md 每条最多 ~15 个字的摘要 + 文件路径引用。详细内容必须在 knowledge/ 或 impressions/ 文件中

3. **自述优先原则**：用户明确说出的自我描述（"我是..."、"我喜欢..."）优先级最高，优于推测

4. **分区上限**：严格遵守各分区条目数上限。超出时必须降级或删除

5. **索引条目格式**：`- [YYYY-MM-DD] 简短描述 → [[文件名]]`（wikilink，shortest-path，不含目录前缀和 .md 后缀）

6. **信息保真**：保留限定词（"可能"、"大概"、"之前"），不将不确定信息写成确定事实

7. **compact 前备份**：global_sleep 步骤 2 压缩 index.md 前必须先执行步骤 1 备份

8. **项目维度**：impression 文件应记录对话发生时的项目目录（从 context 中获取）

9. **不读写记忆目录外的文件**：除了读取 transcript 文件（wrapup 时）外，所有文件操作限制在 memoryDir 内

10. **原子写入**：更新 meta.json 时，先读取完整内容再写回，避免部分写入导致数据损坏

11. **主备分工**：`global_sleep` 仅在 `.role.<source>=primary` 的（source, machine）对上执行；`session_wrapup` 在 primary/secondary 都可执行（多源写入架构通过 `.pending/` + source_id/wrapup_id 保证安全）

---

## 输出规则

- 对于 **query**：返回自然语言回答，包含找到的信息和来源
- 对于 **remember**：返回简短确认，说明存储了什么、存在哪里
- 对于 **session_wrapup**：返回处理摘要，列出新增的 impression 和更新的 knowledge
- 对于 **global_sleep**：返回每个步骤的执行摘要和统计数据；如果当前不是 primary 端，返回拒绝信息
