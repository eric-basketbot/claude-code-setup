#!/usr/bin/env bash
# Generic worktree cleanup. Used by:
#   - cleanup-on-session-end.sh (called from SessionEnd hook for the
#     current session's worktree)
#   - idle-reaper.sh (called hourly for any /tmp/${PROJECT_SLUG}-auto-* whose claude PID
#     is dead and whose branch tip is unchanged for 4h+)
#   - daily-janitor.sh (defense in depth: any /tmp/${PROJECT_SLUG}-auto-* older than 3d)
#
# Usage: cleanup-worktree.sh <worktree-path> [reason]
#
# State machine:
#   Clean tree, branch merged into main          → remove worktree + delete branch
#   Clean tree, branch has unpushed commits      → leave alone, append to review queue
#   Dirty tree (modified tracked files)          → auto-stash, then remove worktree
#   Untracked-only files                          → move to ~/.claude/logs/orphan-files/<branch>/, then remove worktree
#
# Nothing is ever silently destroyed:
#   - Branches with commits are kept (review queue)
#   - Dirty tracked files become stashes (survive in main's reflog)
#   - Untracked files move to a named directory the user can inspect
#
# Always logs to ~/.claude/logs/${PROJECT_SLUG}-worktree-cleanup.log.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

WT_PATH="${1:-}"
REASON="${2:-manual}"

if [[ -z "$WT_PATH" ]]; then
  echo "usage: cleanup-worktree.sh <worktree-path> [reason]" >&2
  exit 2
fi

# Normalize macOS /private/tmp/X → /tmp/X. They resolve to the same dir,
# but mixing both forms in the registry / review queue creates phantom
# duplicates. Pick /tmp/ as the canonical form (shorter, matches what the
# auto-worktree hook writes).
WT_PATH="${WT_PATH#/private}"

if [[ ! -d "$WT_PATH" ]]; then
  bb_log "skip" "cleanup ${WT_PATH}: directory missing (already cleaned?)"
  bb_registry_remove "$WT_PATH" || true
  git -C "$CANONICAL" worktree prune 2>/dev/null || true
  exit 0
fi

# Resolve canonical-relative info from the worktree.
BRANCH="$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
if [[ -z "$BRANCH" || "$BRANCH" == "HEAD" ]]; then
  bb_log "warn" "cleanup ${WT_PATH}: detached HEAD or unreadable; skipping"
  exit 0
fi

# Make sure we're cleaning an auto-worktree, not the user's manually-named
# /wt worktree. Heuristic: branch starts with `wt/auto-` AND path is /tmp/${PROJECT_SLUG}-auto-*.
# If either is false, treat as user-managed and refuse to auto-act.
case "$BRANCH" in
  wt/auto-*) ;;
  *)
    bb_log "skip" "cleanup ${WT_PATH}: branch ${BRANCH} not auto-managed; leaving alone"
    exit 0
    ;;
esac
case "$WT_PATH" in
  /tmp/${PROJECT_SLUG}-auto-*|/private/tmp/${PROJECT_SLUG}-auto-*) ;;
  *)
    bb_log "skip" "cleanup ${WT_PATH}: path not auto-managed; leaving alone"
    exit 0
    ;;
esac

# Snapshot status.
PORCELAIN="$(git -C "$WT_PATH" status --porcelain 2>/dev/null || echo "")"
HAS_DIRTY_TRACKED="false"
HAS_UNTRACKED="false"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  case "$line" in
    \?\?*) HAS_UNTRACKED="true" ;;
    *)     HAS_DIRTY_TRACKED="true" ;;
  esac
done <<<"$PORCELAIN"

# Commits ahead of main?
AHEAD_COUNT=0
if git -C "$WT_PATH" rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1; then
  AHEAD_COUNT="$(git -C "$WT_PATH" rev-list --count "main..${BRANCH}" 2>/dev/null || echo 0)"
fi
LAST_COMMIT_SUBJ="$(git -C "$WT_PATH" log -1 --pretty=%s 2>/dev/null || echo "")"

ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# State 3: dirty tracked files. Stash before removing.
if [[ "$HAS_DIRTY_TRACKED" == "true" ]]; then
  STASH_MSG="auto-cleanup ${BRANCH} ${ISO} (reason=${REASON})"
  if git -C "$WT_PATH" stash push -u -m "$STASH_MSG" >/dev/null 2>&1; then
    bb_log "stashed" "cleanup ${WT_PATH}: dirty → stashed as \"${STASH_MSG}\""
  else
    bb_log "warn" "cleanup ${WT_PATH}: stash failed; leaving worktree intact"
    exit 0
  fi
fi

# State 4: untracked-only files. Move to orphan dir.
# (Re-check after stash, which captured untracked too if any tracked dirt was present.)
if [[ "$HAS_UNTRACKED" == "true" && "$HAS_DIRTY_TRACKED" == "false" ]]; then
  ORPHAN_DIR="${ORPHAN_FILES_DIR}/${BRANCH//\//_}-${ISO}"
  mkdir -p "$ORPHAN_DIR" 2>/dev/null || true
  while IFS= read -r line; do
    [[ "$line" == "??"* ]] || continue
    rel="${line:3}"
    src="${WT_PATH}/${rel}"
    [[ -e "$src" ]] || continue
    parent="$(dirname "${ORPHAN_DIR}/${rel}")"
    mkdir -p "$parent" 2>/dev/null || true
    mv "$src" "${ORPHAN_DIR}/${rel}" 2>/dev/null || true
  done <<<"$PORCELAIN"
  bb_log "orphaned" "cleanup ${WT_PATH}: ${HAS_UNTRACKED:+untracked-only} → moved to ${ORPHAN_DIR}"
fi

# Re-check status after stash/orphan-move; should be clean now.
POST_PORCELAIN="$(git -C "$WT_PATH" status --porcelain 2>/dev/null || echo "")"
if [[ -n "$POST_PORCELAIN" ]]; then
  bb_log "warn" "cleanup ${WT_PATH}: still dirty after stash/orphan-move; leaving worktree intact"
  exit 0
fi

# Decide based on commit-ahead status.
MERGED_INTO_MAIN="false"
if [[ "$AHEAD_COUNT" -eq 0 ]]; then
  MERGED_INTO_MAIN="true"
elif git -C "$CANONICAL" branch --merged main 2>/dev/null | grep -qE "^[*[:space:]]+${BRANCH}$"; then
  MERGED_INTO_MAIN="true"
fi

# State 1: clean + merged → remove worktree + delete branch silently.
if [[ "$MERGED_INTO_MAIN" == "true" ]]; then
  git -C "$CANONICAL" worktree remove --force "$WT_PATH" 2>/dev/null || rm -rf "$WT_PATH"
  git -C "$CANONICAL" worktree prune 2>/dev/null || true
  git -C "$CANONICAL" branch -D "$BRANCH" 2>/dev/null || true
  bb_registry_remove "$WT_PATH" || true
  bb_registry_remove "$BRANCH" || true
  bb_log "removed" "cleanup ${WT_PATH}: clean + merged → deleted (reason=${REASON})"
  exit 0
fi

# State 2: clean but unpushed commits → review queue, keep worktree.
# Dedupe: if the queue already has an entry for this branch+path, skip the
# append (idle-reaper runs hourly and would otherwise re-queue the same
# branch on every pass until the user clears it). WT_PATH is already
# normalized to /tmp/... above; strip /private from queue lines too in case
# any pre-fix entries used the /private/tmp form.
ALREADY_QUEUED="false"
if [[ -f "$REVIEW_QUEUE_LOG" ]]; then
  if awk -F'|' -v b="$BRANCH" -v wp="$WT_PATH" '
    $2 == b {
      qp = $3
      sub(/^\/private/, "", qp)
      if (qp == wp) { found = 1; exit }
    }
    END { exit !found }
  ' "$REVIEW_QUEUE_LOG"; then
    ALREADY_QUEUED="true"
  fi
fi

if [[ "$ALREADY_QUEUED" == "true" ]]; then
  bb_log "skip-queue" "cleanup ${WT_PATH}: already in review queue (reason=${REASON})"
else
  echo "${ISO}|${BRANCH}|${WT_PATH}|${AHEAD_COUNT}|${LAST_COMMIT_SUBJ}" >> "$REVIEW_QUEUE_LOG"
  bb_log "queued" "cleanup ${WT_PATH}: ${AHEAD_COUNT} unpushed commit(s); appended to review queue (reason=${REASON})"
fi

# Worktree stays. Remove the registry entry so /sessions stops listing it as
# active, but the user can still cd into it.
bb_registry_remove "$WT_PATH" || true
exit 0
