#!/usr/bin/env bash
# Shared helpers for the multi-session worktree hooks. Source with:
#   source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
#
# Designed to be sourced into `set -uo pipefail` scripts without surprises.
#
# Project resolution:
#   CANONICAL is the git repo root these hooks live inside. Auto-detected from
#   the location of this script (assumes scripts live at <repo>/scripts/claude-hooks/).
#   Override with: CANONICAL=/path/to/repo source _lib.sh
#
# PROJECT_SLUG is a lowercase, dash-only identifier derived from $(basename "$CANONICAL"),
# used as a prefix for registry / log / orphan file paths so multiple projects
# can run this harness side-by-side without colliding.

# Auto-detect the canonical repo root from this file's location.
if [[ -z "${CANONICAL:-}" ]]; then
  CANONICAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# Derive a portable slug from the repo basename: "MyProject" -> "myproject"
if [[ -z "${PROJECT_SLUG:-}" ]]; then
  PROJECT_SLUG="$(basename "$CANONICAL" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -E 's/^-+|-+$//g')"
  [[ -z "$PROJECT_SLUG" ]] && PROJECT_SLUG="claude-wt"
fi

# Short slug for worktree branch names (cap at 8 chars).
PROJECT_SLUG_SHORT="${PROJECT_SLUG:0:8}"

LOG_DIR="${HOME}/.claude/logs"
REGISTRY_FILE="/tmp/${PROJECT_SLUG}-auto-registry.txt"
PURPOSE_FILE_NAME="WORKTREE_PURPOSE.md"
REVIEW_QUEUE_LOG="${LOG_DIR}/${PROJECT_SLUG}-review-queue.log"
ORPHAN_FILES_DIR="${LOG_DIR}/${PROJECT_SLUG}-orphan-files"
CLEANUP_LOG="${LOG_DIR}/${PROJECT_SLUG}-worktree-cleanup.log"

mkdir -p "$LOG_DIR" "$ORPHAN_FILES_DIR" 2>/dev/null || true

# Walk up from $$ (or supplied PID) looking for a `claude` parent process.
# Echo the first matching PID, or empty string if none found within depth.
bb_find_claude_pid() {
  local pid="${1:-$$}"
  for _ in 1 2 3 4 5 6 7 8; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$pid" || "$pid" == "0" || "$pid" == "1" ]] && break
    if ps -o command= -p "$pid" 2>/dev/null | grep -qE '(^|/)claude( |$)'; then
      echo "$pid"
      return 0
    fi
  done
  echo ""
}

# Append a line to the registry. Format: pid|worktree_path|branch|iso_started
bb_registry_add() {
  local claude_pid="$1" wt_path="$2" branch="$3"
  local iso
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  : > /dev/null
  printf '%s|%s|%s|%s\n' "$claude_pid" "$wt_path" "$branch" "$iso" >> "$REGISTRY_FILE"
}

# Remove any line matching the given worktree path or claude PID. Idempotent.
bb_registry_remove() {
  local key="$1"
  [[ -f "$REGISTRY_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp -t bb-registry.XXXXXX)"
  grep -vF "$key" "$REGISTRY_FILE" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$REGISTRY_FILE"
}

# Echo registry line for a given claude PID, or empty.
bb_registry_lookup_by_pid() {
  local claude_pid="$1"
  [[ -f "$REGISTRY_FILE" ]] || return 0
  awk -F'|' -v p="$claude_pid" '$1 == p { print; exit }' "$REGISTRY_FILE"
}

# Echo registry line for a given worktree path, or empty.
bb_registry_lookup_by_path() {
  local path="$1"
  [[ -f "$REGISTRY_FILE" ]] || return 0
  awk -F'|' -v p="$path" '$2 == p { print; exit }' "$REGISTRY_FILE"
}

# Iterate live registry lines (claude PID still alive) and print them.
bb_registry_live_lines() {
  [[ -f "$REGISTRY_FILE" ]] || return 0
  while IFS='|' read -r pid path branch iso; do
    [[ -z "$pid" ]] && continue
    if ps -p "$pid" >/dev/null 2>&1; then
      printf '%s|%s|%s|%s\n' "$pid" "$path" "$branch" "$iso"
    fi
  done < "$REGISTRY_FILE"
}

# Compact registry: keep only lines whose claude PID is alive.
bb_registry_compact() {
  [[ -f "$REGISTRY_FILE" ]] || return 0
  local tmp
  tmp="$(mktemp -t bb-registry.XXXXXX)"
  bb_registry_live_lines > "$tmp"
  mv "$tmp" "$REGISTRY_FILE"
}

# Count live claude sessions across the host.
bb_count_claude_sessions() {
  pgrep -f 'claude --output-format stream-json' 2>/dev/null | wc -l | tr -d ' '
}

# Echo the worktree path assigned to the current hook invocation, or empty.
# Strategy: walk up to find the claude PID, then look it up in the registry.
bb_my_worktree_path() {
  local cp
  cp="$(bb_find_claude_pid)"
  [[ -z "$cp" ]] && return 0
  local line
  line="$(bb_registry_lookup_by_pid "$cp")"
  [[ -z "$line" ]] && return 0
  awk -F'|' '{print $2}' <<<"$line"
}

# Echo branch for current claude session's worktree, or empty.
bb_my_worktree_branch() {
  local cp
  cp="$(bb_find_claude_pid)"
  [[ -z "$cp" ]] && return 0
  local line
  line="$(bb_registry_lookup_by_pid "$cp")"
  [[ -z "$line" ]] && return 0
  awk -F'|' '{print $3}' <<<"$line"
}

# Cleanup-log helper.
bb_log() {
  local iso
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s [%s] %s\n' "$iso" "${1:-info}" "${2:-}" >> "$CLEANUP_LOG" 2>/dev/null || true
}
