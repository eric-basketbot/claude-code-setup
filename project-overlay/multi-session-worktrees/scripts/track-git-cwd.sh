#!/usr/bin/env bash
# PreToolUse hook on Bash: blocks git mutations attempted in the canonical
# checkout when other claude sessions are alive. v2 promotes this from
# advisory to blocking — a session physically cannot `git add` in canonical.
# The error message names the exact worktree the session should `cd` into,
# read from the global registry, so the model retries with the right path
# instead of looping.
#
# Behavior matrix:
#   in_canonical=false                 → log only, exit 0
#   in_canonical=true, sessions == 1   → log + warn (soft), exit 0
#   in_canonical=true, sessions >= 2   → log + block, exit 2
#
# Read-only verbs are always allowed. `git fetch` / `git status` / `git log`
# / `git diff` / `git show` / `git branch` / `git worktree list` etc. fall
# through.
#
# Audit log lives at ~/.claude/logs/${PROJECT_SLUG}-git-cwd.jsonl as JSON-Lines.
# Use scripts/claude-hooks/git-cwd-report.sh for a quick compliance summary.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

LOG="${LOG_DIR}/${PROJECT_SLUG}-git-cwd.jsonl"

PAYLOAD="$(cat)"
COMMAND="$(echo "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")"

# Match git verbs that mutate the index/working tree/refs. `git fetch` and
# read-only verbs are intentionally excluded. `git push` is gated by a
# separate hook (check-remote-push.sh) that handles divergence + force.
if ! echo "$COMMAND" | grep -qE '\bgit[[:space:]]+(add|commit|cherry-pick|reset|rm|merge|rebase|restore|stash[[:space:]]+(push|pop|drop|apply))\b'; then
  exit 0
fi

VERB="$(echo "$COMMAND" | grep -oE 'git[[:space:]]+(add|commit|cherry-pick|reset|rm|merge|rebase|restore|stash)' | head -1 | awk '{print $2}')"

CWD="$(pwd)"
TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo none)"
COUNT="$(bb_count_claude_sessions)"

IN_CANONICAL="false"
[[ "$TOP" == "$CANONICAL" ]] && IN_CANONICAL="true"

# Truncate command for log readability.
TRUNC_CMD="$(echo "$COMMAND" | head -c 300)"

# Audit log (always written, regardless of block decision).
ACTION="allowed"
if [[ "$IN_CANONICAL" == "true" && "${COUNT:-0}" -ge 2 ]]; then
  ACTION="blocked"
elif [[ "$IN_CANONICAL" == "true" ]]; then
  ACTION="warned"
fi

jq -n -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg cwd "$CWD" \
  --arg top "$TOP" \
  --arg verb "$VERB" \
  --arg cmd "$TRUNC_CMD" \
  --arg action "$ACTION" \
  --argjson sessions "${COUNT:-0}" \
  --argjson pid "$$" \
  --argjson in_canonical "$([[ "$IN_CANONICAL" == "true" ]] && echo true || echo false)" \
  '{ts: $ts, pid: $pid, cwd: $cwd, top: $top, verb: $verb, sessions: $sessions, in_canonical: $in_canonical, action: $action, command: $cmd}' \
  >> "$LOG" 2>/dev/null || true

# Allow if not in canonical.
[[ "$IN_CANONICAL" == "true" ]] || exit 0

# Find the worktree this session was assigned to (set up at SessionStart).
TARGET_WT="$(bb_my_worktree_path)"
TARGET_BRANCH="$(bb_my_worktree_branch)"

if [[ "${COUNT:-0}" -ge 2 ]]; then
  # BLOCK. Stderr message goes back to the model.
  if [[ -n "$TARGET_WT" ]]; then
    cat >&2 <<EOF
Refusing \`git ${VERB}\` in canonical checkout (${COUNT} claude sessions active).

Your assigned worktree: ${TARGET_WT}
                branch: ${TARGET_BRANCH}

Run: cd ${TARGET_WT}

Then re-run the git command. Canonical's .git/index is shared with the other sessions; committing here would sweep up their unrelated staged files.
EOF
  else
    cat >&2 <<EOF
Refusing \`git ${VERB}\` in canonical checkout (${COUNT} claude sessions active).

This session has no registered worktree. Either:
  1. Create one: /wt <slug>   (or: git worktree add /tmp/bb-<slug> -b wt/<slug> main)
  2. Switch to an existing one: \`git worktree list\` to see them, then cd

Canonical's .git/index is shared with the other sessions; committing here would sweep up their unrelated staged files.
EOF
  fi
  exit 2
fi

# Solo session: soft warn, allow. Surfaces as model context.
if [[ -n "$TARGET_WT" ]]; then
  echo "POLICY_REMINDER: \`git ${VERB}\` in canonical (only this session active). Your worktree: ${TARGET_WT}. Prefer \`cd ${TARGET_WT}\` to keep canonical clean for the IDE." >&2
else
  echo "POLICY_REMINDER: \`git ${VERB}\` in canonical (only this session active). Run /wt <slug> to offload work into a worktree." >&2
fi
exit 0
