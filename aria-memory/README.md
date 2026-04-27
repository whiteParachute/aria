# Aria Memory Plugin

Persistent long-term memory for Claude Code and Codex. Both runtimes share the same local memory store at `~/.aria-memory/`; each runtime has its own plugin entrypoints and prompt surfaces.

## Features

- **Memory Query** (`memory`) - retrieve past conversations, user preferences, and project knowledge.
- **Memory Storage** (`remember`) - store important facts in `knowledge/` and update the quick index.
- **Status Dashboard** (`memory-status`) - inspect index size, pending wrapups, maintenance state, and file counts.
- **Session Wrapup** (`memory-wrapup`) - process transcripts into structured memory when a transcript source is available.
- **Global Maintenance** (`memory-sleep`) - compact, merge, archive, and rebuild memory indexes.
- **Auto Maintenance** (`memory-auto-maintain`) - Claude `/loop` setup; Codex remains conditional until a scheduler is verified.

## Architecture

```text
aria-memory/
├── .claude-plugin/plugin.json      # Claude plugin metadata
├── .codex-plugin/plugin.json       # Codex plugin metadata
├── hooks/hooks.json                # Claude hook config
├── hooks.json                      # Codex root hook config
├── hooks/*.sh                      # Shared hook scripts
├── scripts/*.sh                    # Shared file/status/verification scripts
├── skills/                         # Claude-facing skill surface
├── agents/memory-agent.md          # Claude-only memory-agent
└── codex/
    ├── skills/*/SKILL.md           # Codex-facing skill surface
    └── agents/memory-agent.md      # Codex-facing memory-agent
```

The shared memory directory:

```text
~/.aria-memory/
├── index.md
├── meta.json
├── personality.md
├── changelog.md
├── knowledge/
├── knowledge/.pending/
├── impressions/
├── impressions/archived/
└── daily/
```

## Installation

### Claude Code

```bash
claude plugin add --plugin-dir /path/to/aria-memory
```

Claude uses:

- `aria-memory/.claude-plugin/plugin.json`
- `aria-memory/hooks/hooks.json`
- `aria-memory/skills/`
- `aria-memory/agents/memory-agent.md`

### Codex

Expose this plugin directory through the local Codex plugin or marketplace mechanism used by your installation.

Codex uses:

- `aria-memory/.codex-plugin/plugin.json`
- `aria-memory/hooks.json`
- `aria-memory/codex/skills/`
- `aria-memory/codex/agents/memory-agent.md`

Codex agent path: `aria-memory/codex/agents/memory-agent.md`.

Codex skill root: `aria-memory/codex/skills`.

Codex hook discovery: `.codex-plugin/plugin.json` points to `./hooks.json`, whose commands invoke the shared hook scripts under `aria-memory/hooks/`.

Local marketplace samples in this checkout did not contain a `.codex-plugin` reference implementation. The chosen Codex shape is therefore explicit and conservative: keep Claude assets untouched, add Codex-owned assets under `codex/`, and document manual runtime verification for discovery and context injection.

## Runtime Capability Matrix

| Capability | Claude supported | Codex supported | Codex conditional | unsupported |
| --- | --- | --- | --- | --- |
| Shared `~/.aria-memory` store | yes | yes | no | no |
| Initialize memory on session start | yes | yes | no | no |
| Startup context injection | yes | initializes safely by default | set `ARIA_MEMORY_CODEX_CONTEXT_OUTPUT=claude-compatible` only after verifying the local Codex runtime accepts Claude-compatible hook context | no |
| Query memory | yes | yes | no | no |
| Remember explicit facts | yes | yes | no | no |
| Status dashboard | yes | yes | no | no |
| Deferred transcript wrapup | yes | yes, via direct hook transcript fields or Codex `~/.codex/state_*.sqlite` `threads.rollout_path` lookup | Codex hook input or env must expose a session/thread id, rollout path, transcript path, or cwd | no |
| Manual transcript wrapup | yes | no | yes, when the user provides a valid transcript path | no |
| Global maintenance | yes | yes, when Codex memory-agent discovery works | fallback is status-only if no agent surface is available | no |
| Auto maintenance scheduler | yes, via Claude `/loop` | no | yes, only after a Codex scheduler is verified locally | default Codex scheduler setup |
| Git sync | yes | yes | remote/network availability | no |

## Usage

### Query memory

```text
/memory what did we discuss about the database migration?
```

Codex skill: `memory <query>`.

### Store information

```text
/remember our production database is PostgreSQL 15 on AWS RDS
```

Codex skill: `remember <content>`.

### Check status

```text
/memory-status
```

Codex skill: `memory-status`.

### Manual session wrapup

```text
/memory-wrapup
```

Claude discovers the current transcript from Claude runtime paths. Codex does not assume Claude transcript paths; provide a transcript path or use this only after Codex transcript discovery is verified.

### Run maintenance

```text
/memory-sleep
```

Codex can run this through the Codex memory-agent surface when discovered. Without agent discovery, use `memory-status` and store important facts manually with `remember`.

### Auto maintenance

```text
/memory-auto-maintain
```

Claude uses `/loop 6h /memory-sleep`. Codex has no default scheduler contract in this plugin; keep maintenance manual unless your local Codex runtime exposes and verifies a scheduler.

## Hook Behavior

The three shared hook scripts are:

- `hooks/session-start.sh`
- `hooks/session-end.sh`
- `hooks/pre-compact.sh`

Plugin root resolution order:

1. `CLAUDE_PLUGIN_ROOT`
2. `CODEX_PLUGIN_ROOT`
3. `CODEX_PLUGIN_DIR`
4. `CODEX_PLUGIN_PATH`
5. `PLUGIN_ROOT`
6. hook script location
7. current working directory, only when it looks like the plugin root

`SessionStart` initializes `~/.aria-memory` when missing and emits valid JSON using the Claude `hookSpecificOutput.SessionStart.additionalContext` shape in Claude mode. This preserves Claude behavior.

Codex mode is deliberately safer: `hooks.json` sets `ARIA_MEMORY_RUNTIME=codex`, so `SessionStart` initializes memory and exits with no stdout unless `ARIA_MEMORY_CODEX_CONTEXT_OUTPUT=claude-compatible` is set. Only set that opt-in after verifying the local Codex runtime consumes the Claude-compatible hook context shape. Without that opt-in, use the explicit `memory` skill.

`SessionEnd` records a pending wrapup when it can resolve a valid transcript with enough content. Claude normally provides `transcript_path` directly. Codex stores full rollout JSONL files under `~/.codex/sessions/...` and indexes them in `~/.codex/state_*.sqlite` as `threads.rollout_path`; the hook resolves those by direct rollout path fields, `session_id`, `thread_id`, compatible aliases, session-id environment variables, or an explicit `cwd` lookup. Missing transcript/session input skips pending wrapup recording but still allows the later vault Git sync step to run.

`PreCompact` records compaction timestamps in `meta.json` and keeps the latest 10 entries.

## Git Sync

Git sync remains enabled for both runtimes when `~/.aria-memory/.git` exists.

- `SessionStart` attempts `git pull --rebase --quiet origin main`.
- `SessionEnd` commits local memory changes and pushes `origin main`, even when no transcript could be resolved.
- Failures are non-blocking.
- Push or pull failures write `~/.aria-memory/.git-push-failed` with stage and error details.

Delete `.git-push-failed` after resolving the repository or remote problem.

## Verification

Run the compatibility checks:

```bash
bash aria-memory/scripts/verify-codex-compat.sh
```

The script validates:

- Claude and Codex manifests.
- Claude and Codex hook configs.
- Codex skill and agent surfaces.
- hook root resolution with and without `CLAUDE_PLUGIN_ROOT`.
- Codex safe startup downgrade and opt-in context output.
- fresh memory initialization in temporary `HOME`.
- missing transcript safe exit.
- small transcript skip behavior.
- transcript pending-wrapup deduplication.
- pending wrapup startup reminder.
- compaction timestamp retention.
- non-blocking Git sync failure marker.
- README capability documentation.

The script uses temporary `HOME` directories and does not modify real `~/.aria-memory`.

## Manual Codex Runtime Verification

Use this after installing or exposing the plugin to Codex:

1. Confirm Codex displays metadata from `.codex-plugin/plugin.json`.
2. Confirm Codex discovers `aria-memory/codex/skills`.
3. Confirm Codex discovers `aria-memory/codex/agents/memory-agent.md`, or document that your runtime requires direct skill fallback.
4. Start a Codex session with a seeded `~/.aria-memory/index.md`.
5. Check whether startup context from `SessionStart` is injected. If not, use the `memory` skill explicitly.
6. Run a memory query against seeded content.
7. Run `remember` and confirm a knowledge file and index entry are updated.
8. Run `memory-status`.
9. Test `memory-wrapup` only with a verified transcript path.
10. Test automatic maintenance only if the local Codex runtime exposes a scheduler.

Record the Codex runtime date/version if available.

## Design Decisions

### Split Runtime Entrypoints

Claude and Codex are not treated as the same runtime. Claude keeps `.claude-plugin/`, `hooks/hooks.json`, `skills/`, and `agents/memory-agent.md`. Codex owns `.codex-plugin/`, root `hooks.json`, `codex/skills/`, and `codex/agents/memory-agent.md`.

### Shared Core Storage

Both runtimes use the same `~/.aria-memory` schema and scripts. This keeps memory portable while avoiding runtime-specific prompt drift.

### Conditional Transcript and Scheduler Support

Codex transcript discovery and scheduler behavior are not assumed. Query, remember, and status are first-class Codex workflows; wrapup and automatic maintenance require local runtime evidence.

### Memory Agent Boundary

The Claude memory-agent remains Claude-only. The Codex memory-agent reuses the same operation schema without Claude environment assumptions, Claude transcript paths, or Claude-only tool frontmatter.

## Troubleshooting

- **Codex cannot see skills**: verify the plugin is installed through the local Codex plugin mechanism and that `.codex-plugin/plugin.json` points to `./codex/skills`.
- **Startup context missing in Codex**: run `memory <query>` explicitly; context injection depends on the local Codex hook contract.
- **No transcript wrapup in Codex**: provide a transcript path or use `remember` for important facts.
- **Auto maintenance unavailable in Codex**: run `memory-sleep` manually if the memory-agent is available, otherwise run `memory-status`.
- **Git sync failed**: inspect `~/.aria-memory/.git-push-failed`, fix the remote/rebase issue, then delete the marker.

## License

MIT
