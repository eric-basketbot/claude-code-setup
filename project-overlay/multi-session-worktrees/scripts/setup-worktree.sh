#!/usr/bin/env bash
# Post-create setup for auto-worktrees. Called by auto-worktree.sh and by
# /wt-rename when migrating an existing worktree.
#
# Args:
#   $1 = worktree path (required)
#   $2 = branch name (required)
#   $3 = fallback PID for registry (defaults to walk-up result)
#
# Responsibilities:
#   1. Symlink heavy artifacts from canonical so the worktree is usable for
#      build/test/dev without reinstalling anything. Symlinks (not copies) so
#      the worktree stays tiny.
#   2. Write WORKTREE_PURPOSE.md so /sessions and the track-git-cwd "teach"
#      message can identify the worktree's claude session and intent.
#   3. Add a line to the global registry at /tmp/${PROJECT_SLUG}-auto-registry.txt so
#      hooks running in any session can answer "what worktree is my claude
#      session assigned to".

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

WT_PATH="${1:-}"
BRANCH="${2:-}"
FALLBACK_PID="${3:-$$}"

if [[ -z "$WT_PATH" || -z "$BRANCH" ]]; then
  echo "usage: setup-worktree.sh <worktree-path> <branch> [fallback-claude-pid]" >&2
  exit 2
fi
if [[ ! -d "$WT_PATH" ]]; then
  echo "setup-worktree.sh: $WT_PATH does not exist" >&2
  exit 2
fi

# 1. Symlink build/dependency artifacts from canonical.
#    Skip the symlink if it would clobber an existing path in the worktree.
#    Each line: "source-relative-to-canonical:dest-relative-to-worktree".
LINK_TARGETS=(
  "node_modules:node_modules"
  ".env:.env"
  ".env.local:.env.local"
  "dist:dist"
  "client/node_modules:client/node_modules"
  "client/dist:client/dist"
  ".next:.next"
)

for entry in "${LINK_TARGETS[@]}"; do
  src_rel="${entry%%:*}"
  dst_rel="${entry##*:}"
  src="${CANONICAL}/${src_rel}"
  dst="${WT_PATH}/${dst_rel}"

  # Source must exist in canonical for us to link it.
  [[ -e "$src" ]] || continue
  # Don't clobber a real file/dir already in the worktree (rare but possible
  # if the branch checked out content at that path).
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    continue
  fi
  # Ensure parent exists (e.g. client/ for client/node_modules).
  mkdir -p "$(dirname "$dst")" 2>/dev/null || true
  rm -f "$dst" 2>/dev/null || true
  ln -s "$src" "$dst" 2>/dev/null || true
done

# 2. Determine the claude PID for this session.
CLAUDE_PID="$(bb_find_claude_pid "$FALLBACK_PID")"
if [[ -z "$CLAUDE_PID" ]]; then
  # Best-effort fallback: most recent claude PID on the box.
  CLAUDE_PID="$(pgrep -f 'claude --output-format stream-json' 2>/dev/null | tail -1)"
fi
[[ -z "$CLAUDE_PID" ]] && CLAUDE_PID="$FALLBACK_PID"

# 3. Write the purpose file. The "Prompt:" field is left as a placeholder for
#    the model / /wt-rename to fill in once intent is clear.
ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "${WT_PATH}/${PURPOSE_FILE_NAME}" <<EOF
# Worktree purpose

- Branch: \`${BRANCH}\`
- Path: \`${WT_PATH}\`
- Claude PID: ${CLAUDE_PID}
- Started: ${ISO}
- Prompt: _(set by model on first non-trivial turn, or via /wt-rename <slug>)_

Auto-created by \`scripts/claude-hooks/auto-worktree.sh\` at SessionStart.
Cleanup is automatic via SessionEnd hook + hourly idle reaper. See
[docs/multi-session.md](../docs/multi-session.md).
EOF

# Don't track the purpose file in the worktree's branch; we want a clean
# diff vs main. Per-worktree exclude (.git/worktrees/<name>/info/exclude)
# is NOT honored by git status — only the main repo's .git/info/exclude is.
# Write there instead. This makes the entry global to all worktrees, which
# is fine: WORKTREE_PURPOSE.md never exists in canonical or named worktrees.
COMMON_GITDIR="$(git -C "$WT_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -n "$COMMON_GITDIR" && -d "$COMMON_GITDIR" ]]; then
  mkdir -p "${COMMON_GITDIR}/info" 2>/dev/null || true
  if ! grep -qx "${PURPOSE_FILE_NAME}" "${COMMON_GITDIR}/info/exclude" 2>/dev/null; then
    echo "${PURPOSE_FILE_NAME}" >> "${COMMON_GITDIR}/info/exclude"
  fi
fi

# 4. Register.
bb_registry_add "$CLAUDE_PID" "$WT_PATH" "$BRANCH"

bb_log "info" "setup-worktree complete path=${WT_PATH} branch=${BRANCH} claude_pid=${CLAUDE_PID}"

exit 0
