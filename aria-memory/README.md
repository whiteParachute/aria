# Aria Memory Plugin

Persistent long-term memory system for Claude Code with multi-layer retrieval, automatic session wrapup, and periodic maintenance.

## Features

- **Memory Query** (`/memory <query>`) — Multi-layer retrieval: index → impressions → knowledge → archived
- **Memory Storage** (`/remember <content>`) — Classified storage to knowledge/, automatic index updates
- **Session Wrapup** (`/memory-wrapup`) — Extract conversation content into structured memory
- **Global Maintenance** (`/memory-sleep`) — Periodic cleanup, compaction, splitting, and cross-reference maintenance
- **Status Dashboard** (`/memory-status`) — View memory system status at a glance
- **Auto Maintenance** (`/memory-auto-maintain`) — Set up recurring maintenance via /loop

## Architecture

```
Claude Code Session
├── Main Agent (Claude)
│   ├── Reads index.md as context (injected by SessionStart hook)
│   └── Calls memory-agent subagent for memory operations
├── Hooks
│   ├── SessionStart: inject index + personality + check pending wrapups
│   ├── SessionEnd: record transcript path for deferred wrapup
│   └── PreCompact: record compaction timestamp
└── memory-agent subagent
    ├── query: multi-layer memory retrieval
    ├── remember: classified knowledge storage
    ├── session_wrapup: transcript → impressions + knowledge
    └── global_sleep: 7-step maintenance
```

## Data Storage

All memory is stored in `~/.aria-memory/`:

```
~/.aria-memory/
├── index.md              — Quick reference index (~200 entry limit)
├── meta.json             — Metadata (version, counts, pending wrapups)
├── personality.md        — User interaction patterns
├── knowledge/            — Detailed knowledge organized by domain
├── impressions/          — Session-based semantic index files
└── impressions/archived/ — Old impressions (>6 months)
```

## Installation

```bash
# Install from local directory (for development)
claude plugin add --plugin-dir /path/to/aria-memory

# Or install from git
claude plugin add https://github.com/ar8327/aria
```

## Usage

### Query memory
```
/memory what did we discuss about the database migration?
```

### Store information
```
/remember our production database is PostgreSQL 15 on AWS RDS
```

### Manual session wrapup
```
/memory-wrapup
```

### Run maintenance
```
/memory-sleep
```

### Check status
```
/memory-status
```

### Set up auto maintenance
```
/memory-auto-maintain
```

## Design Decisions

### Deferred Wrapup

Claude Code plugin hooks only support `command` and `prompt` types (no `agent` type), and hooks within the same event run in parallel with no order guarantee. Therefore, session wrapup uses a **deferred processing pattern**:

1. `SessionEnd` hook records the transcript path to `pendingWrapups` in meta.json
2. Next `SessionStart` hook detects pending wrapups and prompts Claude to process them via memory-agent

### Memory Agent as Subagent

The memory-agent runs as a Claude Code subagent with isolated context, using file tools (Read, Write, Edit, Grep, Glob, Bash) to manage the memory directory. Each invocation is independent — there is no persistent state within the agent itself.

### Fixed Memory Directory

All projects share a single memory directory at `~/.aria-memory/`. The index partitioning mechanism naturally supports multi-topic organization, and impression files record the project path for context.

## License

MIT
