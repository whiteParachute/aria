# Aria 记忆系统 — 基于 Claude Code 的可行性分析报告

> 日期：2026-03-07
> 基于 Claude Code v2.1.71 实测

---

## 〇、结论摘要

| 模块 | 可行性 | 难度 | 说明 |
|------|--------|------|------|
| 随身索引 | ✅ 完全可行 | 低 | CLAUDE.md / MEMORY.md 天然支持 |
| 检索知识 | ✅ 完全可行 | 低 | 文件系统 + Read/Grep 工具 |
| 模糊印象（语义索引） | ✅ 完全可行 | 低 | 文件 + Grep 搜索 |
| 原始记录 | ✅ 完全可行 | 低 | session transcript 已自动保存 |
| Memory Agent（单例写入者） | ⚠️ 部分可行 | 高 | 无真正的常驻单例进程，需要变通 |
| 双 Agent 通信 | ⚠️ 部分可行 | 中 | 需通过文件系统或 MCP 间接通信 |
| 多会话共享记忆 | ✅ 可行 | 低 | 文件系统天然共享 |
| 睡眠机制 | ⚠️ 部分可行 | 中 | 有 hooks 支持，但全局睡眠需额外编排 |
| 热度机制 | ✅ 可行 | 中 | 需自己实现逻辑，基础设施足够 |
| 性格演化 | ✅ 可行 | 低 | 修改 CLAUDE.md 即可 |
| 同步写入（"记住这个"） | ✅ 完全可行 | 低 | Sub-agent 或 MCP 工具调用 |
| 被动触发（会话结束） | ✅ 可行 | 中 | SessionEnd / Stop hooks |

**总体判断：可行，但架构需要适配。** 设计文档中的「Memory Agent 全局单例」需要调整为「按需调用的 Memory 工具/子 Agent」模式。

---

## 一、四层记忆存储

### 第一层：随身索引 — ✅ 完全可行

**实现方式：CLAUDE.md + MEMORY.md**

Claude Code 有两个天然的「每次会话自动加载」机制：

1. **CLAUDE.md**（项目级 `.claude/CLAUDE.md` 或用户级 `~/.claude/CLAUDE.md`）
   - 每次会话自动加载到 context
   - 可版本管理，支持团队共享
   - 适合放「行为指令」和「性格参数」

2. **MEMORY.md**（自动记忆，`~/.claude/projects/{project}/memory/MEMORY.md`）
   - 前 200 行每次会话自动加载
   - Claude 自己可以读写
   - **这就是随身索引的天然载体**

**约束与适配：**
- 设计文档要求 ~200 条上限，分区管理 → MEMORY.md 的 200 行限制恰好匹配
- 分区设计（用户/话题/提醒/近期上下文）→ 用 Markdown 标题分区，完全可以
- 只放索引不放内容 → 靠 CLAUDE.md 里的规则约束，或靠 Memory Agent 的 system prompt 约束

**实测验证：** 系统提示中确实包含 `auto memory` 相关指令，确认 MEMORY.md 会被自动加载。

### 第二层：检索知识 — ✅ 完全可行

**实现方式：文件系统目录**

```
~/.claude/projects/{project}/memory/
├── MEMORY.md              ← 随身索引（第一层）
├── knowledge/             ← 检索知识（第二层）
│   ├── user/
│   │   ├── profile.md
│   │   └── security-rules.md
│   ├── topics/
│   │   ├── defi-lending.md
│   │   └── memory-system-design.md
│   └── groups/
│       └── tech-group-a.md
```

- Claude Code 对文件系统有完整的 Read/Write/Glob/Grep 访问权限
- 主 Agent 可以直接 Read 文件，或委托 sub-agent 去检索
- Memory Agent（不管以何种形态实现）可以自由创建/修改/组织这些文件

### 第三层：模糊印象（语义索引文件） — ✅ 完全可行

**实现方式：文件 + Grep 搜索**

```
~/.claude/projects/{project}/memory/
├── impressions/           ← 模糊印象（第三层）
│   ├── 2026-03-07-memory-system-discussion.md
│   ├── 2026-03-05-defi-research.md
│   └── ...
```

- 设计文档要求的「LLM 生成描述性索引文件 + 字符串匹配」→ Grep 工具天然支持
- 检索瀑布流程（Grep 索引文件 → 命中 → 读原始记录）→ Claude Code 的工具链完全覆盖
- 自我修复（补充关键词/修正误命中）→ Edit 工具可以修改索引文件

### 第四层：原始记录 — ✅ 完全可行（已有）

**Claude Code 已自动保存：**

- 会话记录存储在 `~/.claude/projects/{project}/{sessionId}.jsonl`
- 格式为 JSONL，包含 `user`/`assistant` 消息、工具调用、时间戳等
- append-only，天然满足设计要求

**实测确认的字段：**
```json
{
  "type": "user",
  "message": {"role": "user", "content": "..."},
  "uuid": "...",
  "timestamp": "2026-03-07T10:14:21.448Z",
  "cwd": "/Users/ar8327/dev/aria",
  "sessionId": "...",
  "gitBranch": "main"
}
```

---

## 二、Memory Agent 架构

### 设计文档的期望
- 全局单例进程
- 所有会话共享
- 拥有记忆的写入权
- 双向通信（主动通知 + 被动查询）

### Claude Code 的现实约束

**核心问题：Claude Code 没有「常驻后台 Agent」的概念。**

每个 sub-agent 都是短生命周期的——被 Agent 工具调用时启动，任务完成后结束。没有一个持续运行、等待请求的 agent 进程。

### 可行的替代方案（三选一）

#### 方案 A：Sub-agent 模式（推荐，最简单）

将 Memory Agent 实现为 Claude Code 的自定义 sub-agent（`.claude/agents/memory-agent.md`），每次需要时由主 Agent 调用。

```
主 Agent ──调用──→ Memory Sub-agent（短生命周期）──读写──→ 文件系统
                   ↑
                   每次调用都是新实例，但文件系统是持久的
```

**优点：**
- 零额外基础设施
- 文件系统作为持久化层，天然实现「单例写入者」的效果（因为 sub-agent 是串行调用的）
- 自定义 agent 支持独立的 system prompt、工具列表、model 选择

**缺点：**
- 不是真正的单例进程，每次调用要重新加载 context
- 无法「主动通知」主 Agent（只能被动响应查询）
- 多个并发会话可能同时写文件（但文件级冲突概率低）

**并发安全性：** 文件写入本身是原子的（Write 工具一次性写入完整文件），实际冲突风险很小。如果需要更强的保证，可以用文件锁或写入队列。

#### 方案 B：MCP Server 模式（更强大，需开发）

将 Memory Agent 实现为一个独立的 MCP Server 进程。

```
Claude Code 会话 A ──MCP──→ ┐
Claude Code 会话 B ──MCP──→ ├──→ Memory MCP Server（常驻）──→ 文件系统
Claude Code 会话 C ──MCP──→ ┘
```

**优点：**
- 真正的全局单例，完美匹配设计文档
- 天然解决并发写入问题
- 可以实现复杂的热度管理、compact 逻辑
- MCP 工具对 Claude Code 来说就像内置工具一样好用

**缺点：**
- 需要开发一个 MCP Server（Go/Python/TypeScript）
- MCP Server 本身不含 LLM 能力，需要自己调 API 实现「LLM 判断什么值得记」
- 需要进程管理（启动/停止/监控）

**实测确认：** Claude Code 的 MCP 支持完善，支持 stdio/HTTP 两种传输方式，配置简单（`claude mcp add`），支持项目级和用户级配置。

#### 方案 C：混合模式（推荐长期方案）

- **同步操作**（查询、"记住这个"）→ Sub-agent 模式，直接在主 Agent 会话内完成
- **异步维护**（睡眠整理、compact、性格演化）→ 由 hooks 触发外部脚本，脚本调用 `claude -p` 执行 LLM 判断

```
主 Agent ──同步──→ Sub-agent（读写记忆）
    │
    └── SessionEnd hook ──触发──→ 维护脚本 ──调用──→ claude -p（异步整理）
```

**实测确认：** `claude -p` 可以在脚本中非交互调用，返回结果后退出。实测耗时约 20-30 秒（haiku 模型）。

---

## 三、Hooks 系统（触发机制）

### 可用的关键 Hooks

| Hook | 用途 | 匹配设计文档的场景 |
|------|------|-------------------|
| **SessionEnd** | 会话结束时触发 | 会话级收尾（生成语义索引、提炼知识） |
| **Stop** | Agent 完成一次响应 | 可用于检测对话结束信号 |
| **UserPromptSubmit** | 用户提交消息前 | 可拦截「记住这个」类指令 |
| **PostToolUse** | 工具执行后 | 监控文件写入，追踪记忆访问 |
| **SessionStart** | 会话开始时 | 注入动态上下文（如待办提醒） |
| **PreCompact** | context 压缩前 | 保存即将被压缩的上下文 |

### Hooks 接收的信息

每个 hook 通过 **stdin JSON** 接收：
- `session_id`：会话标识
- `transcript_path`：完整对话记录的文件路径
- `cwd`：工作目录
- 事件特定数据（如 `tool_name`、`tool_input`、`prompt` 等）

### Hook 的能力与限制

**能做的：**
- 执行任意 shell 命令（`type: command`）
- 调用 HTTP 端点（`type: http`）
- 使用 LLM 做决策（`type: prompt`）
- 生成子 agent 做复杂验证（`type: agent`）
- 异步后台执行（`async: true`）
- 向 Claude 注入上下文（`additionalContext`）
- 阻止操作或修改工具输入

**不能做的：**
- 不能主动向正在进行的会话推送消息
- 不能调用其他 Claude Code 工具
- 不能修改 Claude 内部状态

### 会话结束检测

设计文档要求「用户手动告知会话结束」。实现方式：

1. **UserPromptSubmit hook**：检测用户消息是否包含结束信号（"先这样吧"/"晚安"等）
2. **SessionEnd hook**：Claude Code 会话真正结束时自动触发
3. **Stop hook**：每次 Claude 完成响应时触发，可配合 prompt 类型 hook 让 LLM 判断对话是否已结束

推荐用 **SessionEnd**（最可靠）+ **UserPromptSubmit**（检测自然语言结束信号）组合。

---

## 四、多会话并发

### 设计文档的期望
- 私聊 + 多个群聊同时存在
- 记忆自动跨会话流动
- Memory Agent 串行处理，避免写入冲突

### Claude Code 的现实

**多会话支持：** Claude Code 可以在多个终端窗口同时运行不同会话，每个会话有独立的 session ID 和 context。

**记忆共享：** 如果所有会话都使用同一个项目目录，那么：
- MEMORY.md（随身索引）自动共享——所有会话启动时都加载同一份
- 文件系统上的检索知识/语义索引天然共享
- 一个会话写入的记忆，下一个会话启动时就能看到

**写入冲突风险：**
- **MEMORY.md**：如果两个会话同时修改，后写的会覆盖先写的。风险中等。
- **检索知识文件**：不同会话通常写不同文件，冲突概率低。
- **解决方案**：用文件锁（`flock`）或通过 MCP Server 串行化写入。

### IM 网关问题

设计文档提到「私聊 + 群聊」，但 Claude Code 本身不是 IM 客户端。这意味着：

- **如果 Aria 只通过 Claude Code CLI 对话**：多会话 = 多个终端窗口，用户手动切换。可行但体验不如 IM。
- **如果需要接入 IM**：需要额外开发 IM 网关，每个 IM 会话对应一个 `claude -p` 调用或一个 MCP 连接。这超出了「挂在 Claude Code 上」的范围。

**建议：** MVP 先只做 CLI 场景（单用户、单/双终端），IM 网关作为后续扩展。

---

## 五、睡眠机制

### 会话级收尾 — ✅ 可行

**触发：** SessionEnd hook

**流程实现：**
1. Hook 脚本接收 `transcript_path`（完整对话记录路径）
2. 脚本调用 `claude -p` 读取对话记录，生成语义索引文件
3. 脚本调用 `claude -p` 提炼新知识，写入检索知识层
4. 标记会话为已整理

**实测确认：** `claude -p --no-session-persistence --model haiku` 可在脚本中调用，适合做轻量级 LLM 处理。

### 全局睡眠 — ⚠️ 需要额外编排

**问题：** Claude Code 没有「所有会话都结束了」的原生事件。

**解决方案：**
1. 每个会话结束时，hook 检查是否还有其他活跃的 Claude Code 进程
2. 如果没有 → 触发全局睡眠脚本
3. 全局睡眠脚本调用 `claude -p` 执行 compact、自审、性格线分析

```bash
# 伪代码：SessionEnd hook
ACTIVE_SESSIONS=$(pgrep -f "claude" | grep -v $$ | wc -l)
if [ "$ACTIVE_SESSIONS" -eq 0 ]; then
    # 触发全局睡眠
    claude -p "执行全局记忆维护..." &
fi
```

**替代方案：** 用 cron 定时任务做全局维护（每天凌晨），不依赖会话结束检测。

---

## 六、热度机制

### 可行性 — ✅ 可行，需自己实现

Claude Code 没有内置的热度系统，但提供了足够的基础设施：

**元数据存储：** 每条记忆可以用 YAML frontmatter 或 JSON 文件存储元数据。

```markdown
---
created: 2026-03-07
last_accessed: 2026-03-07
access_count: 3
source: user_self
about: user
confidence: high
---
用户偏好静态类型语言，目前写 Go（曾学 Rust）
```

**访问追踪：**
- PostToolUse hook 可以监控 Read 工具的调用，记录哪些记忆文件被读取
- 或者在 Memory Agent 的 system prompt 里要求它每次查询后更新 `last_accessed`

**升降级：**
- 全局睡眠脚本扫描所有记忆的元数据
- 高热度 → 升到 MEMORY.md（随身索引）
- 低热度 → 从 MEMORY.md 移除，保留在检索知识层

**Compact：**
- `claude -p` 可以读取当前 MEMORY.md，判断哪些条目可以合并/精简
- 输出新的 MEMORY.md 内容

---

## 七、性格演化

### 可行性 — ✅ 完全可行

**实现方式：修改 CLAUDE.md**

Claude Code 的行为完全由 CLAUDE.md 控制。性格演化 = 修改 CLAUDE.md 中的行为指令。

```
全局睡眠脚本 ──分析交互模式──→ 决定调整 ──→ Edit CLAUDE.md
```

**实测确认：** 当前用户的 `~/.claude/CLAUDE.md` 已经包含了详细的人设指令（傲娇毒舌妹妹人设），证明这种方式是有效的。

**注意：** CLAUDE.md 的修改在下次会话生效（当前会话不会热更新，除非重新加载）。

---

## 八、记忆可信度

### 可行性 — ✅ 可行

完全是逻辑层面的设计，不依赖特殊基础设施：

- 在 Memory Agent 的 system prompt 中定义可信度规则
- 在记忆文件的元数据中标注来源和可信度
- 冲突检测在写入时由 LLM 判断

---

## 九、同步 vs 异步写入

| 场景 | 实现方式 | 可行性 |
|------|---------|--------|
| 同步（"记住这个"） | 主 Agent 调用 Memory Sub-agent | ✅ 直接可用 |
| 异步（会话结束整理） | SessionEnd hook → claude -p | ✅ 已验证 |
| 异步（定时维护） | cron → claude -p | ✅ 标准方案 |

---

## 十、关键风险与限制

### 1. MEMORY.md 200 行硬限制
- 超过 200 行的内容不会自动加载
- 需要严格的 compact 策略
- **缓解：** 这个限制反而强制了「只放索引不放内容」的设计原则

### 2. 无真正的常驻 Memory Agent
- 每次调用都是新实例，没有内存中的状态
- **缓解：** 文件系统作为持久化层，状态在文件中而非内存中

### 3. claude -p 调用延迟
- 实测 haiku 模型约 20-30 秒完成一次调用
- 异步维护可接受，但同步场景（用户等待）可能太慢
- **缓解：** 同步场景用 sub-agent（在当前会话内，更快），异步场景用 claude -p

### 4. 多会话写入冲突
- 两个会话同时修改 MEMORY.md 可能导致数据丢失
- **缓解：** 文件锁、MCP Server 串行化、或接受低概率冲突

### 5. Context Window 消耗
- Sub-agent 每次调用都占用主 Agent 的 context
- 频繁查询记忆会加速 context 压缩
- **缓解：** 合理控制查询频率，利用随身索引减少深层查询

### 6. 成本
- 每次异步维护（claude -p）都是一次 API 调用
- 频繁的会话收尾 + 全局睡眠会产生额外成本
- **缓解：** 用 haiku 模型做维护（便宜），只在必要时触发

---

## 十一、推荐 MVP 方案

### Phase 1：最小可行记忆系统

1. **随身索引**：手动维护 MEMORY.md（先不做自动 compact）
2. **检索知识**：文件目录 + sub-agent 查询
3. **同步写入**：sub-agent 处理「记住这个」
4. **异步收尾**：SessionEnd hook → 脚本调用 claude -p 生成语义索引

### Phase 2：自动化

5. **热度机制**：PostToolUse hook 追踪访问
6. **compact**：定时 cron 或全局睡眠时自动执行
7. **性格演化**：全局睡眠时分析并修改 CLAUDE.md

### Phase 3：多会话（可选）

8. **MCP Server**：替代 sub-agent，实现真正的单例写入者
9. **IM 网关**：接入 Telegram/Discord 等

---

## 十二、需要开发的组件清单

| 组件 | 类型 | 复杂度 | 说明 |
|------|------|--------|------|
| Memory Sub-agent prompt | `.claude/agents/memory.md` | 低 | system prompt + 工具配置 |
| 记忆目录结构 | 文件/文件夹 | 低 | 按设计文档组织 |
| SessionEnd hook | Shell 脚本 | 中 | 读对话记录，调用 claude -p 整理 |
| 语义索引生成器 | claude -p prompt | 中 | 从对话记录提取索引 |
| Compact 脚本 | claude -p prompt | 中 | 压缩 MEMORY.md |
| 热度追踪 hook | Shell 脚本 | 中 | 监控文件访问，更新元数据 |
| 全局睡眠编排 | Shell 脚本 | 中 | 检测所有会话结束，触发维护 |
| CLAUDE.md 行为指令 | Markdown | 低 | 定义主 Agent 如何与记忆交互 |
| MCP Memory Server（可选） | Go/TS | 高 | 全局单例，串行写入 |
