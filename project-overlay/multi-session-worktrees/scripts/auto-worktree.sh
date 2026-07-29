#!/usr/bin/env bash
# SessionStart hook: every Claude session that lands in the canonical checkout
# is offloaded to a fresh worktree. v2 architectural rule: Claude sessions
# never edit canonical, regardless of how many sessions are active. Canonical
# exists for the user's IDE and manual git ops only.
#
# v1 of this hook only fired when `pgrep` saw >=2 sessions, which left the
# index race window open while session B was starting and silently let session
# A pollute canonical. v2 always fires from canonical, with `BB_STAY_IN_CANONICAL=1`
# as the documented escape for read-only research sessions.
#
# Output goes into the model's context at SessionStart and is shaped as a
# directive ("MUST cd into <path>"). The model that sees this output is
# expected to immediately switch to the worktree before any tool call.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

# Read-only research escape. Documented in docs/multi-session.md.
if [[ "${BB_STAY_IN_CANONICAL:-0}" == "1" ]]; then
  echo "BB_STAY_IN_CANONICAL=1 — auto-worktree skipped. Git mutations are still blocked in canonical when other sessions are active."
  exit 0
fi

# Only act when SessionStart cwd is canonical. If we're already inside a
# worktree (e.g. user resumed `claude` from an existing wt-auto-* dir), do nothing.
TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$TOP" || "$TOP" != "$CANONICAL" ]]; then
  exit 0
fi

# Compact the registry: drop entries for dead claude PIDs.
bb_registry_compact || true

# Drop dead worktrees from prior sessions so the list stays tidy.
git -C "$CANONICAL" worktree prune 2>/dev/null || true

DATE_PART="$(date +%Y%m%d)"
SHORT_PID="$$"
SLUG="auto-${DATE_PART}-${SHORT_PID}"
WORKTREE_PATH="${WORKTREE_BASE}/bb-${SLUG}"
BRANCH="wt/${SLUG}"

# If a branch with this name already exists (rare — same PID reuse on the
# same day), bump with a counter.
COUNTER=2
while git -C "$CANONICAL" rev-parse --verify --quiet "refs/heads/${BRANCH}" >/dev/null 2>&1; do
  SLUG="auto-${DATE_PART}-${SHORT_PID}-${COUNTER}"
  WORKTREE_PATH="${WORKTREE_BASE}/bb-${SLUG}"
  BRANCH="wt/${SLUG}"
  COUNTER=$((COUNTER + 1))
  if [[ "$COUNTER" -gt 9 ]]; then
    echo "AUTO_WORKTREE_FAIL: could not find a free branch name after 9 attempts. Run /wt <slug> manually."
    exit 0
  fi
done

# Branch from origin/main (not canonical's local main) whenever it is safe to do
# so — see bb_resolve_worktree_base in _lib.sh for why. Falls back to local main
# on divergence or when the remote can't be reached, with a note explaining it.
BASE_LINE="$(bb_resolve_worktree_base "$CANONICAL")"
BASE_REF="${BASE_LINE%%$'\t'*}"
BASE_NOTE="${BASE_LINE#*$'\t'}"
# Explicit `if` rather than `[[ ]] && BASE_NOTE=""` — the latter evaluates to 1
# when the note is non-empty, which is a landmine if this hook ever gains `set -e`.
if [[ "$BASE_NOTE" == "$BASE_LINE" ]]; then BASE_NOTE=""; fi

# Fail loudly rather than letting `worktree add` interpret a bad ref. Belt and
# braces: the resolver only ever returns `main` or `refs/remotes/origin/main`,
# both of which it verified, but a future edit shouldn't be able to turn this
# into a silent mis-branch.
if ! git -C "$CANONICAL" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1; then
  echo "AUTO_WORKTREE_FAIL: resolved base ref '${BASE_REF}' does not name a commit. Run \`/wt <slug>\` manually."
  exit 0
fi

LOG="$(mktemp "${TMPDIR:-/tmp}/wt-auto-worktree.XXXXXX")" || {
  echo "AUTO_WORKTREE_FAIL: could not allocate a temporary log file. Run \`/wt <slug>\` manually."
  exit 0
}
# --no-track is load-bearing, not cosmetic: with a remote-tracking start point,
# branch.autoSetupMerge would set the new branch's upstream to origin/main, and a
# bare `git push` from the session worktree would then target MAIN. Verified.
if ! git -C "$CANONICAL" worktree add --no-track "$WORKTREE_PATH" -b "$BRANCH" "$BASE_REF" >"$LOG" 2>&1; then
  echo "AUTO_WORKTREE_FAIL — could not create $WORKTREE_PATH:"
  echo
  cat "$LOG"
  echo
  echo "Manual fallback: run \`/wt <slug>\` or \`git worktree add --no-track ${WORKTREE_BASE}/bb-<slug> -b wt/<slug> ${BASE_REF}\` before any \`git add\` / \`git commit\` / \`git cherry-pick\`."
  rm -f "$LOG"
  exit 0
fi
rm -f "$LOG"

# Hand off to setup-worktree.sh for symlinks + PURPOSE.md + registry add.
# Pass our PID as fallback claude_pid in case the walk-up can't find it
# (e.g. when invoked under unusual harness configurations).
SETUP_LOG="$(mktemp "${TMPDIR:-/tmp}/bb-setup-worktree.XXXXXX")" || SETUP_LOG="/dev/null"
if ! bash "$LIB_DIR/setup-worktree.sh" "$WORKTREE_PATH" "$BRANCH" "$$" >"$SETUP_LOG" 2>&1; then
  echo "AUTO_WORKTREE_PARTIAL: worktree created at $WORKTREE_PATH but setup failed:"
  cat "$SETUP_LOG"
  echo
  # Don't bail — the worktree is usable, just missing symlinks/registry.
fi
rm -f "$SETUP_LOG"

COUNT="$(bb_count_claude_sessions)"

cat <<EOT
PARALLEL_SAFE_WORKTREE — auto-created (${COUNT} claude session(s) active on this host).

Worktree: ${WORKTREE_PATH}
Branch:   ${BRANCH}
Base:     ${BASE_REF}${BASE_NOTE:+

⚠️  ${BASE_NOTE}}

You MUST \`cd ${WORKTREE_PATH}\` before any tool call that edits files or touches git state. Canonical at ${CANONICAL} is for the user's IDE only — Claude sessions never edit it.

Symlinks installed: node_modules, .env, .env.local, dist/, client/dist/, .next/ (where canonical has them) — \`npm run build\` / \`npm test\` / \`npm run dev\` work in the worktree without reinstalling.

Read-only ops (Read, Grep, Glob, \`git status\`, \`git log\`, \`gh\`) are safe in either location.

Cleanup happens automatically when this session ends (SessionEnd hook + hourly idle reaper). If you commit work, the branch is queued for review at ~/.claude/logs/myproject-review-queue.log instead of being deleted.

If your work has a clearer name, run \`/wt-rename <slug>\` to rename the branch from auto-${DATE_PART}-${SHORT_PID}.
EOT
