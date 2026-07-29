#!/usr/bin/env bash
# Generic worktree cleanup. Used by:
#   - cleanup-on-session-end.sh (called from SessionEnd hook for the
#     current session's worktree)
#   - idle-reaper.sh (called hourly for any wt-auto-* whose claude PID
#     is dead and whose branch tip is unchanged for 4h+)
#   - daily-janitor.sh (defense in depth: any wt-auto-* older than 3d)
#
# Recognizes BOTH the new ~/.agent-worktrees/wt-auto-* location AND the
# legacy /tmp/wt-auto-* location, so transition sessions can clean either.
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
# Always logs to ~/.claude/logs/myproject-worktree-cleanup.log.

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

# Normalize macOS /private/<X> → /<X>. They resolve to the same dir,
# but mixing both forms in the registry / review queue creates phantom
# duplicates. /tmp/ entries become /tmp/, and /private/Users/.../myproject-worktrees/
# is impossible (macOS doesn't /private-prefix $HOME), so this is a no-op for
# the new WORKTREE_BASE path — keeping it for the legacy /tmp/ entries.
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
# /wt worktree. Heuristic: branch starts with `wt/auto-` AND the path matches
# the auto-worktree pattern (new ${WORKTREE_BASE}/wt-auto-* OR legacy
# /tmp/wt-auto-* during transition). If either is false, treat as user-managed
# and refuse to auto-act.
case "$BRANCH" in
  wt/auto-*) ;;
  *)
    bb_log "skip" "cleanup ${WT_PATH}: branch ${BRANCH} not auto-managed; leaving alone"
    exit 0
    ;;
esac
if ! bb_is_auto_worktree_path "$WT_PATH"; then
  bb_log "skip" "cleanup ${WT_PATH}: path not auto-managed; leaving alone"
  exit 0
fi

# Capture the auto-PR suppress marker BEFORE any cleanup runs — the
# untracked-only path (State 4 below) moves all `??` files to the orphan
# dir, which would otherwise erase the marker before the auto-PR check
# sees it.
HAS_NO_AUTO_PR_MARKER="false"
if [[ -f "${WT_PATH}/.no-auto-pr" ]]; then
  HAS_NO_AUTO_PR_MARKER="true"
fi

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

# Commits genuinely unique to this branch?
#
# This MUST be measured against local main AND origin/main, not local main alone.
# Since 2026-07-25 auto-worktrees branch from origin/main when canonical is behind
# (see bb_resolve_worktree_base). Counting `main..${BRANCH}` would then report every
# commit the branch inherited from the remote as "unpushed work" — an untouched
# session on a canonical 67 commits behind would look like it had 67 commits, so
# cleanup would push a useless branch, open a draft PR, and queue it for review.
# `rev-list ${BRANCH} --not <bases>` counts only commits reachable from the branch
# and from NEITHER base, which is what "did this session actually write anything?"
# means regardless of which base it started from.
# FAIL CLOSED when the count is indeterminate. bb_unique_commits_ahead returns
# non-zero if neither base ref resolves (local main deleted AND origin/main absent
# or pruned) or if rev-list errors. Defaulting to 0 there would mean "no unique
# work", and State 1 below would `worktree remove --force` + `branch -D` a branch
# that may hold unpublished commits. Leaving the worktree intact is always
# recoverable; deleting it is not.
if ! AHEAD_COUNT="$(bb_unique_commits_ahead "$WT_PATH" "$BRANCH")"; then
  bb_log "warn" "cleanup ${WT_PATH}: cannot determine unique-commit count (no usable main/origin-main ref); leaving worktree intact"
  exit 0
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
# Skip the `.no-auto-pr` marker — it must survive cleanup so subsequent
# reaper runs continue to suppress auto-PR on this worktree.
if [[ "$HAS_UNTRACKED" == "true" && "$HAS_DIRTY_TRACKED" == "false" ]]; then
  ORPHAN_DIR="${ORPHAN_FILES_DIR}/${BRANCH//\//_}-${ISO}"
  mkdir -p "$ORPHAN_DIR" 2>/dev/null || true
  ORPHANED_ANY="false"
  while IFS= read -r line; do
    [[ "$line" == "??"* ]] || continue
    rel="${line:3}"
    # Preserve the suppress marker in place.
    [[ "$rel" == ".no-auto-pr" ]] && continue
    src="${WT_PATH}/${rel}"
    [[ -e "$src" ]] || continue
    parent="$(dirname "${ORPHAN_DIR}/${rel}")"
    mkdir -p "$parent" 2>/dev/null || true
    if mv "$src" "${ORPHAN_DIR}/${rel}" 2>/dev/null; then
      ORPHANED_ANY="true"
    fi
  done <<<"$PORCELAIN"
  if [[ "$ORPHANED_ANY" == "true" ]]; then
    bb_log "orphaned" "cleanup ${WT_PATH}: untracked-only → moved to ${ORPHAN_DIR}"
  else
    # Only the marker was here; nothing to orphan. Drop the empty dir.
    rmdir "$ORPHAN_DIR" 2>/dev/null || true
  fi
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
elif git -C "$CANONICAL" merge-base --is-ancestor "$BRANCH" refs/heads/main >/dev/null 2>&1; then
  MERGED_INTO_MAIN="true"
elif git -C "$CANONICAL" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1 &&
     git -C "$CANONICAL" merge-base --is-ancestor "$BRANCH" refs/remotes/origin/main >/dev/null 2>&1; then
  # Contained in origin/main: a real merge that landed remotely but has not been
  # pulled into canonical's main yet.
  #
  # `merge-base --is-ancestor` rather than parsing `git branch --merged`: the old
  # grep `^[*[:space:]]+${BRANCH}$` cannot match a branch checked out in a LINKED
  # WORKTREE, which git prefixes with `+` rather than `*` or a space — i.e. exactly
  # the branches this hook deals with. Note this is ancestry only; a SQUASH-merged
  # branch is never an ancestor and correctly falls through to the review queue.
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

# State 2: clean but unpushed commits → try auto-PR-on-green, then queue.
#
# Auto-PR: opens a draft PR on origin/main so "done but not shipped" becomes
# visible work with a forcing function instead of aging out via the 3-day
# janitor. Best-effort; failures (no network, no gh auth, push rejected) fall
# through to the review queue path so work is never lost.
#
# Suppress with:
#   - BB_AUTO_PR=0 env var (per-invocation)
#   - touch <worktree>/.no-auto-pr (per-worktree marker)
PR_URL=""
SKIP_AUTO_PR_REASON=""
if [[ "${BB_AUTO_PR:-1}" == "0" ]]; then
  SKIP_AUTO_PR_REASON="BB_AUTO_PR=0"
elif [[ "$HAS_NO_AUTO_PR_MARKER" == "true" ]]; then
  SKIP_AUTO_PR_REASON=".no-auto-pr marker present"
elif [[ "$HAS_DIRTY_TRACKED" == "true" ]]; then
  # State 3 stashed uncommitted tracked edits. The PR would represent only
  # the committed subset while the stashed work is hidden — misleading
  # for a reviewer. Queue without a PR so the user resolves the stash first.
  SKIP_AUTO_PR_REASON="pre-cleanup tree had stashed tracked changes"
elif [[ "$HAS_UNTRACKED" == "true" && "${ORPHANED_ANY:-false}" == "true" ]]; then
  # State 4 orphan-moved real untracked work (not just the .no-auto-pr
  # marker). Same misleading-PR concern as the stash case.
  SKIP_AUTO_PR_REASON="pre-cleanup tree had orphaned untracked files"
elif ! bb_gh_ready; then
  SKIP_AUTO_PR_REASON="gh not installed or not authenticated"
fi

if [[ -z "$SKIP_AUTO_PR_REASON" ]]; then
  PR_URL="$(bb_open_draft_pr "$WT_PATH" "$BRANCH" "$LAST_COMMIT_SUBJ" || true)"
  if [[ -n "$PR_URL" ]]; then
    bb_log "auto-pr" "cleanup ${WT_PATH}: draft PR ${PR_URL}"
  else
    bb_log "auto-pr-skip" "cleanup ${WT_PATH}: no PR opened (push or gh-create failed; falling through to queue)"
  fi
else
  bb_log "auto-pr-skip" "cleanup ${WT_PATH}: ${SKIP_AUTO_PR_REASON}"
fi

# Review queue (always — survives even when a PR was opened, so the digest
# can still report on PRs that sit unmerged).
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
  echo "${ISO}|${BRANCH}|${WT_PATH}|${AHEAD_COUNT}|${LAST_COMMIT_SUBJ}|${PR_URL}" >> "$REVIEW_QUEUE_LOG"
  bb_log "queued" "cleanup ${WT_PATH}: ${AHEAD_COUNT} unpushed commit(s); queued${PR_URL:+ with PR $PR_URL} (reason=${REASON})"
fi

# Worktree stays. Remove the registry entry so /sessions stops listing it as
# active, but the user can still cd into it.
bb_registry_remove "$WT_PATH" || true
exit 0
