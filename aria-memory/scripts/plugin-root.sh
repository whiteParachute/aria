#!/bin/bash
# Resolve the aria-memory plugin root across Claude and Codex runtimes.

aria_memory_is_plugin_root() {
  local candidate="${1:-}"
  [ -n "$candidate" ] || return 1
  [ -f "$candidate/scripts/init-memory-dir.sh" ] || return 1
  [ -f "$candidate/.claude-plugin/plugin.json" ] || [ -f "$candidate/.codex-plugin/plugin.json" ]
}

aria_memory_resolve_plugin_root() {
  local script_path="${1:-}"
  local candidate

  for candidate in \
    "${CLAUDE_PLUGIN_ROOT:-}" \
    "${CODEX_PLUGIN_ROOT:-}" \
    "${CODEX_PLUGIN_DIR:-}" \
    "${CODEX_PLUGIN_PATH:-}" \
    "${PLUGIN_ROOT:-}"; do
    if aria_memory_is_plugin_root "$candidate"; then
      (cd "$candidate" && pwd -P)
      return 0
    fi
  done

  if [ -n "$script_path" ]; then
    local script_dir
    script_dir="$(cd "$(dirname "$script_path")" 2>/dev/null && pwd -P)" || script_dir=""
    for candidate in "$script_dir/.." "$script_dir"; do
      if aria_memory_is_plugin_root "$candidate"; then
        (cd "$candidate" && pwd -P)
        return 0
      fi
    done
  fi

  candidate="$(pwd -P)"
  if aria_memory_is_plugin_root "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}
