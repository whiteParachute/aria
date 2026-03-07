# Aria 记忆系统 — 设计文档 v0.3（单会话简化版）

> 日期：2026-03-07
> 状态：基于 v0.2 + 可行性调研，适配 Claude Code 实际能力
> 前提：单会话，挂在 Claude Code 上

---

## 一、设计原则

在 Claude Code 上做记忆系统，不从零写。

**与 v0.2 的关键变化：**
- 放弃多会话并发 → 单会话，消除所有并发问题
- 放弃 Memory Agent 全局单例 → Memory Sub-agent，按需调用
- 睡眠机制从两级合并为一级 → SessionEnd hook 统一处理
- 落地到 Claude Code 的具体机制（MEMORY.md、hooks、`.claude/agents/`）

**不变的：**
- 四层记忆模型
- 热度机制
- 可信度规则
- 性格演化
- 时间绝对化

---

## 二、架构

```
用户 ←→ Claude Code 会话（主 Agent / Aria）
              │
              ├── 启动时自动加载 MEMORY.md（随身索引）
              │
              ├── 对话中：
              │   ├── 扫随身索引 → 有就直接用
              │   ├── 需要深层记忆 → 调用 Memory Sub-agent
              │   └── 用户说"记住" → 调用 Memory Sub-agent
              │
              ├── 会话结束：
              │   └── SessionEnd hook → 睡眠维护脚本
              │
              └── 文件系统（记忆存储）
                  └── ~/.claude/projects/{project}/memory/
```

### 主 Agent（Aria）

- Claude Code 本身，负责与用户对话
- **不直接写记忆文件**（MEMORY.md 除外，见下文说明）
- 每次会话自动加载 MEMORY.md（随身索引）
- 需要深层记忆时调用 Memory Sub-agent
- 行为由 CLAUDE.md 控制（包括性格）

### Memory Sub-agent

- 定义在 `.claude/agents/memory.md`
- 按需调用，短生命周期——调用时启动，任务完成后结束
- **拥有记忆的写入权**（通过 prompt 约束）
- 负责：记忆写入、查询、冲突检测、分类归档
- 不负责：compact、热度评估、性格演化（这些由睡眠维护完成）

### 写入权说明

v0.2 要求「只有 Memory Agent 可以写入」，在 Sub-agent 模式下稍作调整：

- **检索知识、模糊印象** → 只有 Memory Sub-agent 写入（通过 CLAUDE.md 指令约束主 Agent）
- **随身索引（MEMORY.md）** → Memory Sub-agent 写入；睡眠维护脚本也会写入（compact/升降级）
- **原始记录** → Claude Code 自动保存，无需管理

---

## 三、四层记忆存储

### 物理结构

```
~/.claude/projects/{project}/memory/
├── MEMORY.md                       ← 第一层：随身索引（自动加载）
├── knowledge/                      ← 第二层：检索知识
│   ├── user/
│   │   ├── profile.md              ← 用户档案
│   │   └── preferences.md          ← 用户偏好
│   ├── topics/
│   │   ├── memory-system.md        ← 按话题组织
│   │   └── defi-lending.md
│   └── people/
│       └── ...                     ← 提到的人
├── impressions/                    ← 第三层：模糊印象
│   ├── 2026-03-07-memory-arch.md   ← 按会话生成的语义索引
│   └── ...
└── meta/
    └── heat.json                   ← 热度元数据
```

原始记录（第四层）不在此目录，由 Claude Code 自动保存在 `~/.claude/projects/{project}/{sessionId}.jsonl`。

### 第一层：随身索引（MEMORY.md）

- **载体**：`MEMORY.md`，Claude Code 每次会话自动加载前 200 行
- **内容**：不是知识本身，而是「我知道什么」的地图
- **容量**：~200 行上限，分区管理
- **规则**：只放索引和摘要，不放具体内容

#### 分区设计

```markdown
## 关于用户（长期，很少变动）
- Yuelun，偏好简洁，第一性原理思维
- 目前在写 Go，关注 DeFi + AI Agent
[上限：~30 行]

## 活跃项目/话题（中期，按热度升降）
- 记忆系统设计 [有详细笔记 → topics/memory-system.md]
- 投资研究 [有详细笔记 → topics/investment.md]
[上限：~50 行]

## 重要提醒（时效性，过期自动清理）
- 用户 2026-03-14 ~ 2026-03-21 去东京出差
[上限：~20 行]

## 近期上下文（短期，每次睡眠刷新）
- 上次在讨论记忆系统的简化设计
- 待定：MVP 实现范围
[上限：~50 行]

## 备用空间
[~50 行，给溢出和临时提升用]
```

与 v0.2 的变化：近期上下文不再按会话分区（因为只有一个会话），简化为一个扁平区域。

### 第二层：检索知识

- **性质**：按领域组织的详细知识库
- **内容**：结晶化的事实、用户档案、领域笔记
- **组织**：`knowledge/` 下按主题分目录，由 Memory Sub-agent 自由管理
- **访问**：主 Agent 通过 Memory Sub-agent 查询
- 每个文件可带 YAML frontmatter 存储元数据：

```markdown
---
created: 2026-03-07
last_accessed: 2026-03-07
access_count: 3
confidence: high
---
# DeFi 借贷协议笔记

## 核心概念
- 超额抵押：借款需要 >100% 的抵押率...
```

### 第三层：模糊印象（语义索引文件）

与 v0.2 完全一致，不需要改动：

- **性质**：全局语义索引
- **作用**：前两层没命中时，提供「好像在哪儿见过」的模糊关联
- **实现**：睡眠时为每次会话生成描述性索引文件，查询时 Grep 搜索
- **自我修复**：Memory Sub-agent 在检索时发现索引缺关键词 → 补充；发现误命中 → 修正

语义索引文件格式不变：

```markdown
# 2026-03-07 会话 — 记忆系统架构讨论

## 话题
- 讨论了 Aria 记忆系统的架构设计
- 四层记忆模型：随身索引、检索知识、模糊印象、原始记录

## 关键词
记忆系统, 随身索引, compact, 热度, 性格演化

## 涉及的人/事/概念
- Qdrant（提了一嘴，没深入）
- Claude Code 作为主 Agent 的宿主
```

### 第四层：原始记录

- Claude Code 已自动保存为 `{sessionId}.jsonl`
- append-only，source of truth
- 包含完整对话历史、工具调用、时间戳

### 检索瀑布

```
用户问："我们是不是聊过 Qdrant？"

1. 主 Agent 扫 MEMORY.md → 没有 Qdrant 相关
2. 主 Agent 调用 Memory Sub-agent："我们聊过 Qdrant 吗？"
3. Memory Sub-agent grep impressions/ → 命中 2026-03-07 索引文件
4. Memory Sub-agent 回复："有的，2026-03-07 聊记忆系统时提过，当时在讨论向量数据库选型"
5. 如需更多细节 → Memory Sub-agent 读原始记录补充
6. 主 Agent 用自己的语气转述给用户
```

与 v0.2 的变化：Sub-agent 模式下无法做「分步回复」（先模糊再补细节），因为 Sub-agent 返回的是一次性结果。但主 Agent 可以在自己的回复中模拟这个过程（先说「让我想想」，再给出细节）。

---

## 四、触发机制

### 同步触发（会话中）

| 场景 | 触发方式 | Memory Sub-agent 行为 |
|------|---------|---------------------|
| 用户说「记住这个」 | 主 Agent 识别意图，调用 Sub-agent | 跳过筛选，直接写入 |
| 主 Agent 需要查记忆 | 主 Agent 调用 Sub-agent 查询 | Grep 索引 → 读文件 → 返回结果 |
| 用户问「我们聊过X吗」 | 同上 | 检索瀑布流程 |

### 异步触发（会话结束后）

**SessionEnd hook** → 睡眠维护脚本（`claude -p`）

这是唯一的异步触发点。单会话下不需要区分「会话级收尾」和「全局睡眠」。

---

## 五、睡眠机制

### 定义

- **睡眠** = 会话结束到下次会话开始之间的时间
- **触发** = SessionEnd hook 自动触发，无需用户手动告知

### 睡眠维护流程

SessionEnd hook 触发后，执行以下步骤（通过 `claude -p` 调用 LLM）：

```
1. 读取本次会话的原始记录（transcript）
    │
    ├──→ 知识线：
    │    ├── 筛选值得记的内容
    │    ├── 提炼为简短 fact
    │    ├── 检查与已有记忆的冲突
    │    ├── 写入/合并到 knowledge/
    │    └── 生成语义索引文件 → impressions/
    │
    ├──→ 随身索引维护：
    │    ├── 近因提升：本次对话重要内容 → MEMORY.md 近期上下文区
    │    ├── 过期清理：移除已过时的提醒
    │    ├── compact：超限时压缩合并、降级低热度条目
    │    └── 自审：检查分区比例、重复条目、内容是否混进索引
    │
    └──→ 性格线（每 N 次睡眠执行一次）：
         ├── 分析近期交互模式
         ├── 积累信号，达到阈值时
         └── 修改 CLAUDE.md 中的行为指令
```

与 v0.2 的变化：将「会话级收尾」和「全局睡眠」合并为一个流程，因为只有一个会话。

### 热度评估时机

热度评估在睡眠维护中完成：

- 读取 `meta/heat.json`（每条记忆的访问元数据）
- 根据 PostToolUse hook 追踪到的访问记录更新热度
- 执行升降级：
  - 高热度的检索知识 → 升到 MEMORY.md
  - 低热度的随身索引条目 → 降到检索知识

---

## 六、热度机制

与 v0.2 基本一致：

- **升级**（检索 → 随身）：频繁使用、近期重要、用户强调
- **降级**（随身 → 检索）：长时间没访问，热度衰减
- **compact**：随身层满了 → 压缩合并、降级低热度条目

### 访问追踪

- **PostToolUse hook**：监控 Read 工具对 `memory/` 目录下文件的访问
- hook 将访问事件追加到 `meta/heat.json`
- 不要求精确——「大概用到了」就够

### 元数据格式（`meta/heat.json`）

```json
{
  "knowledge/topics/memory-system.md": {
    "created": "2026-03-07",
    "last_accessed": "2026-03-07",
    "access_count": 5
  },
  "knowledge/user/profile.md": {
    "created": "2026-03-01",
    "last_accessed": "2026-03-07",
    "access_count": 12
  }
}
```

compact 示例与 v0.2 一致，不重复。

---

## 七、性格演化

与 v0.2 一致，实现方式明确化：

- **载体**：`CLAUDE.md`（用户级 `~/.claude/CLAUDE.md` 或项目级 `.claude/CLAUDE.md`）
- **修改时机**：睡眠维护的性格线（不是每次都执行，每 N 次睡眠检查一次）
- **修改方式**：睡眠脚本通过 `claude -p` 分析交互模式，输出 CLAUDE.md 的修改建议，写入文件
- **生效时机**：下次会话启动时自动加载新的 CLAUDE.md

性格不是「知识」，而是对主 Agent 行为的直接修改。

---

## 八、硬规则

### 时间绝对化

与 v0.2 完全一致：
```
❌ "用户下周要去东京出差"
✅ "用户 2026-03-14 ~ 2026-03-21 去东京出差（2026-03-07 提及）"
```

### 写入权

- 检索知识、模糊印象 → 只有 Memory Sub-agent 和睡眠脚本可以写入
- 随身索引 → Memory Sub-agent 和睡眠脚本可以写入
- 主 Agent 不直接修改记忆文件（通过 CLAUDE.md 指令约束）

### 随身索引

只放索引，不放内容。超限触发 compact，不触发丢弃。

### 记忆可信度（自述优先原则）

与 v0.2 完全一致。单会话场景下简化为只有用户一个信息来源（没有群聊的第三方），但规则仍保留以备后续扩展。

---

## 九、同步 vs 异步写入

| | 同步（用户说「记住这个」） | 异步（睡眠整理） |
|---|---|---|
| 触发 | 主 Agent 调用 Memory Sub-agent | SessionEnd hook |
| 执行者 | Memory Sub-agent（会话内） | 睡眠脚本 + claude -p（会话外） |
| 筛选 | 跳过（用户已决定重要性） | LLM 判断什么值得记 |
| 定位 | 定位 + 写入 | 定位 + 写入 + 合并 |
| 热度 | 不评估 | 评估升降级 |
| 额外工作 | 无 | compact、性格演化、过期清理 |

---

## 十、用例推演

### 用例 1：跨会话事实记忆

**场景**：用户今天说「我下周去东京出差」。三周后新会话说「好累啊」。

1. 对话中，这句话进入 → 原始记录（Claude Code 自动保存）
2. 会话结束 → SessionEnd hook → 睡眠脚本提炼 fact「用户 2026-03-14 ~ 2026-03-21 去东京出差」
3. 写入 `knowledge/user/schedule.md`
4. 生成 `impressions/2026-03-07-xxx.md`
5. 判断为近期重要 → 写入 MEMORY.md：「用户 2026-03-14 ~ 2026-03-21 去东京出差」
6. 三周后新会话 → 主 Agent 启动时加载 MEMORY.md → 看到这条 → 直接说：「是不是东京出差累到了？」
7. 再过两个月没提 → 睡眠脚本热度评估 → 从 MEMORY.md 降回 knowledge/

### 用例 2：模糊回想

**场景**：用户问「我们是不是聊过 Qdrant？」

1. 主 Agent 扫 MEMORY.md → 没有
2. 主 Agent 调用 Memory Sub-agent
3. Sub-agent grep `impressions/` → 命中 2026-02-20 的索引文件
4. Sub-agent 返回：「找到了，2026-02-20 聊向量数据库选型时提过，你在比较 Qdrant 和 Milvus」
5. 主 Agent 用自己的语气回复用户

### 用例 3：用户主动说「记住这个」

**场景**：用户说「记住，服务器 root 密码不能告诉别人」

1. 主 Agent 识别「记住」意图 → 调用 Memory Sub-agent
2. Sub-agent 跳过筛选 → 写入 `knowledge/user/security-rules.md`
3. Sub-agent 更新 MEMORY.md 加一行：「安全：服务器 root 密码不可外泄 [详见 user/security-rules.md]」
4. Sub-agent 返回确认 → 主 Agent 告知用户已记住

### 用例 4：记忆冲突

**场景**：半年前说「在学 Rust」，现在说「在写 Go，Rust 放弃了」

1. 会话结束 → 睡眠脚本提炼 fact「用户在写 Go」
2. 检测到与已有 fact「用户在学 Rust」冲突
3. 更新 `knowledge/user/profile.md`：标记旧条目为历史
4. 更新 MEMORY.md：「用户目前在写 Go」

### 用例 5：性格适应

**场景**：用户连续二十次对话都用简短风格

1. 每次睡眠 → 性格线分析交互模式
2. 积累 20+ 次「用户偏好简短」信号 → 达到阈值
3. 睡眠脚本修改 CLAUDE.md → 提高回复简洁度权重
4. 下次会话 → 主 Agent 加载新 CLAUDE.md → 变得更简洁

### 用例 6：领域知识学习

**场景**：用户说「帮我把这篇 DeFi 借贷的文章学一下」

1. 主 Agent 调用 Memory Sub-agent → 直接写入 `knowledge/topics/defi-lending.md`
2. Sub-agent 更新 MEMORY.md：「领域知识：DeFi 借贷 [详见 topics/defi-lending.md]」
3. 会话结束 → 睡眠脚本生成语义索引文件
4. 后续频繁聊 DeFi → 热度升高 → 核心概念可能升到 MEMORY.md 摘要里

### 用例 7：随身索引 compact

**场景**：MEMORY.md 接近 200 行上限

1. 睡眠脚本检测到 MEMORY.md 行数接近上限
2. 读取 `meta/heat.json` 获取访问数据
3. 合并相关条目：「用户在写 Go」+「用户之前学过 Rust」→「用户目前写 Go（曾学 Rust）」
4. 降级低热度条目 → 从 MEMORY.md 移除（knowledge/ 里还有）
5. 精简表述，确保不丢失索引能力

---

## 十一、Claude Code 实现映射

| 设计概念 | Claude Code 实现 |
|---------|-----------------|
| 主 Agent (Aria) | Claude Code 会话本身 |
| 主 Agent 行为指令 | `~/.claude/CLAUDE.md` |
| Memory Agent | `.claude/agents/memory.md`（Sub-agent） |
| 随身索引 | `MEMORY.md`（自动加载前 200 行） |
| 检索知识 | `memory/knowledge/` 目录 |
| 模糊印象 | `memory/impressions/` 目录 |
| 原始记录 | `{sessionId}.jsonl`（Claude Code 自动保存） |
| 同步写入 | Agent 工具调用 Memory Sub-agent |
| 异步整理 | SessionEnd hook → `claude -p` |
| 热度追踪 | PostToolUse hook → `meta/heat.json` |
| 性格演化 | 睡眠脚本修改 CLAUDE.md |
| 会话结束检测 | SessionEnd hook（自动） |

---

## 十二、需要创建的文件

```
aria/
├── .claude/
│   ├── CLAUDE.md                    ← 主 Agent 行为指令（含记忆交互规则）
│   ├── agents/
│   │   └── memory.md                ← Memory Sub-agent 定义
│   └── settings.json                ← hooks 配置
├── scripts/
│   ├── sleep.sh                     ← 睡眠维护入口脚本
│   └── track-access.sh              ← 热度追踪脚本（PostToolUse hook）
└── docs/
    └── ...
```

---

## 十三、已确定事项

| 话题 | 结论 |
|---|---|
| 架构 | 单会话，主 Agent + Memory Sub-agent（按需调用） |
| Memory Agent 形态 | `.claude/agents/memory.md`，不是常驻进程 |
| 随身索引载体 | MEMORY.md，前 200 行自动加载 |
| 记忆存储 | 文件系统，`~/.claude/projects/{project}/memory/` |
| 原始记录 | Claude Code 自动保存的 session transcript |
| 同步写入 | 主 Agent 通过 Agent 工具调用 Memory Sub-agent |
| 异步整理 | SessionEnd hook → claude -p 执行睡眠维护 |
| 睡眠 | 不再分级，SessionEnd 时统一执行全部维护 |
| 热度追踪 | PostToolUse hook 监控记忆文件读取 |
| 性格演化 | 睡眠脚本修改 CLAUDE.md，下次会话生效 |
| 搜索流程 | MEMORY.md → grep impressions/ → 读原始记录 |
| 索引自我修复 | Memory Sub-agent 检索时发现缺失/误命中 → 补充/修正 |
| 记忆可信度 | 自述优先原则（保留，备后续多人场景扩展） |
| 时间绝对化 | 所有时间转绝对时间，记录提及时间和事件时间 |

### 与 v0.2 的差异汇总

| v0.2 | v0.3 | 原因 |
|------|------|------|
| 多会话并发 | 单会话 | 简化，消除并发问题 |
| Memory Agent 全局单例 | Memory Sub-agent 按需调用 | Claude Code 无常驻 Agent |
| 双向通信（含主动通知） | 单向调用 + 返回值 | Sub-agent 不能主动推送 |
| 两级睡眠（会话级 + 全局） | 一级睡眠 | 只有一个会话 |
| 近期上下文按会话分区 | 近期上下文扁平区域 | 只有一个会话 |
| 分步回复（先模糊再补细节） | 一次性返回结果 | Sub-agent 返回完整结果 |
| 群聊场景 | 暂不支持 | 单会话假设 |
| 可信度多来源 | 保留规则但简化为单来源 | 只有用户一个信息源 |
