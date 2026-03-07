# Aria 记忆系统 — 简化方案可行性分析（单会话 + Agent Teams）

> 日期：2026-03-07
> 基于 Claude Code v2.1.71 实测
> 前提假设：**只有一个会话**，放弃多会话并发

---

## 〇、简化假设带来的变化

原设计假设「私聊 + 多个群聊」并发 → 需要 Memory Agent 全局单例来解决写入冲突。

**简化为单会话后：**
- ❌ 不再需要全局单例 → 并发写入问题消失
- ❌ 不再需要 MCP Server → 不用写额外服务
- ❌ 不再需要跨会话记忆流动 → 只有一个会话，记忆天然可见
- ❌ 不再需要「全局睡眠 vs 会话级收尾」的区分 → 只有一种睡眠
- ✅ 可以用 Agent Teams / Sub-agent 在会话内直接完成所有事

这让整个系统从「分布式协调问题」降级为「单进程内的模块分工问题」，复杂度大幅下降。

---

## 一、两种实现路径对比

### 路径 A：Custom Sub-agent 模式

```
用户 ←→ 主 Agent (Aria)
              │
              ├── 需要记忆时 ──→ Memory Sub-agent（按需调用，短生命周期）
              │                       │
              │                       └──→ 文件系统（记忆存储）
              │
              └── 会话结束 ──→ SessionEnd hook ──→ claude -p（异步整理）
```

**工作方式：**
- Memory Agent 定义在 `.claude/agents/memory.md`
- 主 Agent 通过 Agent 工具调用它
- 每次调用是新实例，但文件系统是持久的
- 会话内串行调用，不存在并发问题

### 路径 B：Agent Teams 模式

```
用户 ←→ Lead Agent (Aria)
              │
              ├── Teammate: Memory Agent（会话内持久存在）
              │       │
              │       └── 持续监听，管理记忆文件
              │
              └── (可选) Teammate: 其他专业 Agent
```

**工作方式：**
- 主 Agent 作为 Team Lead
- Memory Agent 作为 Teammate，在会话期间持续存在
- 通过 Agent Teams 的消息系统双向通信
- Memory Agent 可以在后台做整理工作

---

## 二、Agent Teams 方案详细分析

### 核心能力匹配度

| 设计需求 | Agent Teams 支持度 | 说明 |
|---------|-------------------|------|
| Memory Agent 持续存在 | ✅ | Teammate 在会话期间持久 |
| 双向通信 | ✅ | Lead ↔ Teammate 自动消息传递 |
| Memory Agent 主动通知 | ✅ | Teammate 可以主动发消息给 Lead |
| 独立工具集 | ⚠️ | 继承 Lead 权限，不能在生成时限制 |
| 独立 system prompt | ⚠️ | 没有正式的 system prompt 字段，但 spawn prompt 可以充当 |
| 独立 context window | ✅ | 每个 Teammate 有自己的 context |
| 共享文件系统 | ✅ | 所有 Teammate 访问同一文件系统 |
| 会话恢复后保留 | ❌ | Teammate 不支持 session resume |

### Agent Teams 的关键优势

**1. 真正的会话内持久 Memory Agent**

Sub-agent 模式下，每次调用 Memory Agent 都要重新加载 context，理解当前状态。Agent Teams 的 Teammate 则在整个会话期间保持上下文，记得之前的所有交互。

**2. 双向通信**

这是 Agent Teams 相比 Sub-agent 的最大优势：
- **主 → Memory**：主 Agent 发消息给 Memory Teammate（查询、写入请求）
- **Memory → 主**：Memory Teammate 完成整理后主动通知（"我已经更新了用户档案"）
- 这完美匹配设计文档中 Memory Agent 的双向通信需求

**3. 并发执行**

Memory Teammate 可以在主 Agent 与用户对话的同时，后台做记忆整理。不需要等到会话结束。

### Agent Teams 的关键限制

**1. 实验特性（Experimental）**

Agent Teams 目前仍标记为实验特性，默认禁用。API 和行为可能变化。

**2. 不支持 Session Resume**

会话恢复后 Teammate 会丢失。这意味着：
- 每次 `claude -c`（继续会话）后，需要重新生成 Memory Teammate
- Memory Teammate 的对话历史不保留
- 但记忆文件在文件系统上是持久的，所以不会丢失数据

**3. 没有正式的自定义 system prompt**

Teammate 没有像 `.claude/agents/xxx.md` 那样的 system prompt 机制。只能通过 spawn prompt 给指导：

```
"生成一个 Memory Agent 队友。它的职责是：
1. 管理 ~/.claude/projects/.../memory/ 下的记忆文件
2. 只有它可以写入记忆
3. 按照四层记忆模型组织（随身索引/检索知识/模糊印象/原始记录）
4. ..."
```

这段 spawn prompt 会作为 Teammate 的初始指令，效果类似 system prompt，但不如专门的 agent 定义文件正式。

**4. 成本线性增长**

每个 Teammate 有独立的 context window，意味着 Memory Teammate 持续运行会持续消耗 token。即使它在「等待」，context 也在那儿。

**5. 无法限制工具集**

不能在生成时限制 Teammate 只能用 Read/Write/Grep。它继承 Lead 的全部权限。这意味着 Memory Teammate 理论上可以执行任何操作（虽然可以通过 spawn prompt 约束行为）。

---

## 三、Sub-agent vs Agent Teams 对比

| 维度 | Sub-agent | Agent Teams |
|------|-----------|-------------|
| **Memory Agent 生命周期** | 短（每次调用新建） | 长（会话内持久） |
| **通信方向** | 单向（主 → Memory） | 双向（互相发消息） |
| **Memory 主动通知** | ❌ 不可能 | ✅ 可以 |
| **后台并发整理** | ❌ 必须串行 | ✅ 可以并行 |
| **Context 效率** | ✅ 用完即释放 | ⚠️ 持续占用 |
| **实现复杂度** | 低（写个 .md 文件） | 中（需要编排团队） |
| **稳定性** | ✅ 稳定特性 | ⚠️ 实验特性 |
| **Session Resume** | ✅ 不受影响 | ❌ Teammate 丢失 |
| **工具限制** | ✅ 可以指定工具列表 | ❌ 继承 Lead 权限 |
| **独立 System Prompt** | ✅ `.claude/agents/xxx.md` | ⚠️ 只有 spawn prompt |
| **成本** | 低（按需调用） | 高（持续运行） |

---

## 四、推荐方案：Sub-agent 为主 + Hooks 补充

考虑到 Agent Teams 仍是实验特性、不支持 session resume、且成本更高，**单会话场景下 Sub-agent 模式反而是更务实的选择**。

但单会话的简化让 Sub-agent 方案变得更加强大——原来的很多「⚠️ 部分可行」现在都变成了「✅ 完全可行」。

### 简化后的完整架构

```
┌─────────────────────────────────────────────────┐
│ Claude Code 单会话                                │
│                                                   │
│  主 Agent (Aria)                                  │
│    │                                              │
│    ├── CLAUDE.md ← 行为指令 + 性格参数             │
│    ├── MEMORY.md ← 随身索引（200行，自动加载）      │
│    │                                              │
│    ├── 同步操作：                                  │
│    │   └── Agent 工具 → Memory Sub-agent           │
│    │         ├── 写入记忆（记住这个）               │
│    │         ├── 查询记忆（我们聊过X吗？）          │
│    │         └── 更新随身索引                       │
│    │                                              │
│    └── 读取操作（直接，不经过 Memory Agent）：       │
│        └── 扫 MEMORY.md → 有就直接用               │
│                                                   │
├── Hooks：                                         │
│   ├── SessionEnd → 异步整理（claude -p）           │
│   ├── PreCompact → 保存即将压缩的上下文             │
│   └── PostToolUse → 追踪记忆文件访问               │
│                                                   │
├── 文件系统（记忆存储）：                            │
│   └── ~/.claude/projects/{project}/memory/         │
│       ├── MEMORY.md          ← 第一层：随身索引     │
│       ├── knowledge/         ← 第二层：检索知识     │
│       ├── impressions/       ← 第三层：模糊印象     │
│       └── (transcript 已有)  ← 第四层：原始记录     │
└─────────────────────────────────────────────────┘
```

### 单会话场景下各模块可行性（更新版）

| 模块 | 可行性 | 难度 | 变化 |
|------|--------|------|------|
| 随身索引 | ✅ 完全可行 | 低 | 不变 |
| 检索知识 | ✅ 完全可行 | 低 | 不变 |
| 模糊印象 | ✅ 完全可行 | 低 | 不变 |
| 原始记录 | ✅ 完全可行 | 低 | 不变 |
| Memory Agent | ✅ **完全可行** | **低** | ↑ 单会话不需要单例，sub-agent 足够 |
| 双 Agent 通信 | ✅ **完全可行** | **低** | ↑ 会话内 Agent 工具直接调用 |
| 写入冲突 | ✅ **不存在** | — | ↑ 单会话无并发 |
| 睡眠机制 | ✅ **完全可行** | **低** | ↑ 只有一种睡眠，SessionEnd hook |
| 热度机制 | ✅ 可行 | 中 | 不变 |
| 性格演化 | ✅ 可行 | 低 | 不变 |
| 同步写入 | ✅ 完全可行 | 低 | 不变 |
| 被动触发 | ✅ 完全可行 | 低 | ↑ SessionEnd hook 直接用 |

### 对比原方案：消除了所有「⚠️」

原方案有 3 个「⚠️ 部分可行」（Memory Agent 单例、双 Agent 通信、睡眠机制），简化后全部变为「✅ 完全可行」。

---

## 五、Memory Sub-agent 唯一不能做的事

**主动通知。**

Sub-agent 只能被动响应调用，不能主动向主 Agent 推送信息。设计文档中的场景：

> Memory → 主：主动通知（"用户刚说要搬家，我已更新"）

这在 Sub-agent 模式下做不到。但可以用以下方式弥补：

1. **不需要主动通知**：单会话里，主 Agent 调用 Memory Sub-agent 写入后，Sub-agent 的返回消息就是「通知」。主 Agent 自然知道记忆已更新。

2. **SessionStart hook 注入**：每次会话开始时，hook 检查上次睡眠期间的变化，注入一段 `additionalContext` 告诉主 Agent："上次睡眠时做了这些更新：……"

3. **如果真的需要**：可以等 Agent Teams 稳定后迁移。架构上预留这个扩展点即可。

---

## 六、Agent Teams 的最佳使用场景

Agent Teams 虽然不是 Memory Agent 的最优实现方式，但在 Aria 系统的其他场景下可能有价值：

| 场景 | 适合用 Teams 吗 | 原因 |
|------|----------------|------|
| Memory Agent（记忆管理） | ❌ 不推荐 | 实验特性、session resume 问题、成本高 |
| 领域知识学习（用户说"学一下这篇文章"） | ✅ 可以 | 生成一个学习 Teammate，后台阅读和整理，完成后通知 |
| 长时间研究任务 | ✅ 可以 | 主 Agent 继续对话，研究 Teammate 后台工作 |
| 多文件并行编辑 | ✅ 可以 | 每个 Teammate 负责不同文件 |

---

## 七、最终推荐的 MVP 实现清单

| 组件 | 类型 | 复杂度 | 说明 |
|------|------|--------|------|
| Memory Sub-agent | `.claude/agents/memory.md` | 低 | prompt 定义记忆管理规则 |
| 记忆目录结构 | 文件夹 | 低 | knowledge/ + impressions/ |
| CLAUDE.md 行为指令 | Markdown | 低 | 告诉主 Agent 何时调用 Memory Agent |
| MEMORY.md 初始模板 | Markdown | 低 | 分区结构（用户/话题/提醒/近期上下文） |
| SessionEnd hook | Shell 脚本 | 中 | 调用 claude -p 做会话收尾 |
| SessionStart hook | Shell 脚本 | 低 | 注入上次睡眠的变更摘要 |

**总计：4 个低复杂度 + 1 个中复杂度组件。** 核心是写好 Memory Sub-agent 的 prompt 和 CLAUDE.md 的指令，剩下的基础设施 Claude Code 已经提供了。

---

## 八、结论

> **单会话假设下，不需要 Agent Teams，用 Sub-agent + Hooks 就能实现设计文档中的所有核心功能。**

Agent Teams 的双向通信和持久性优势在单会话场景下不是刚需——Sub-agent 的返回值就是通知，文件系统就是持久化。而 Agent Teams 的实验性质、不支持 session resume、持续消耗 token 等缺点在当前阶段风险太大。

当 Agent Teams 稳定后（毕竟它确实更优雅），可以考虑迁移。但 MVP 阶段，Sub-agent 模式是最务实的选择。
