#!/usr/bin/env bash
# PreToolUse hook on Bash for `git push`. Layered on top of the worktree
# isolation: worktrees fix the local .git/index race; this hook addresses
# the remote-side race where two sessions independently push to origin/main
# (or vps/main) and one ends up overwriting the other's work.
#
# Two concrete failure modes from MEMORY.md:
#   1. Remote moved while we worked. `git push` rejects, model panics, runs
#      `git push --force` and drops a deployed commit.
#   2. Two sessions push to vps/main back-to-back; the second wipes the first
#      from PM2 because the build script exits 0 on identical content.
#
# Behavior:
#   - Force pushes (`--force`, `--force-with-lease`) to main / vps / vps-staging
#     branches are blocked unconditionally. Operator override is "run it
#     yourself outside of claude".
#   - Normal pushes: fetch the target ref via `git ls-remote` and check
#     local HEAD's relationship to it. If we're behind the remote (remote has
#     commits we don't have locally), block with rebase guidance.
#
# Falls through (exit 0) for:
#   - Non-push git commands
#   - Pushes to anything that isn't main / vps / vps-staging on origin/vps/vps-staging
#   - Pushes where local HEAD is at or ahead of remote (the normal case)

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

PAYLOAD="$(cat)"
COMMAND="$(echo "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")"

# Only intercept `git push` invocations.
echo "$COMMAND" | grep -qE '\bgit[[:space:]]+push\b' || exit 0

# Hard-block force-push to deploy / shared branches.
if echo "$COMMAND" | grep -qE '(--force(-with-lease)?|[[:space:]]-f([[:space:]]|$))'; then
  if echo "$COMMAND" | grep -qE '\b(origin|vps|vps-staging|vps-production)[[:space:]]+(main|master|staging:main)\b'; then
    cat >&2 <<EOF
Refusing force-push to a shared branch.

Force-push to \`main\` / \`vps\` / \`vps-staging\` from a Claude session is blocked because parallel sessions can drop each other's deployed commits (see MEMORY.md "Remote force-push from parallel session can drop already-deployed commits").

If you genuinely need to force-push: run the command yourself outside the Claude session, after \`git fetch\` and confirming the remote SHA is what you expect.
EOF
    exit 2
  fi
fi

# Parse remote + ref from the command. Defaults: remote=origin, ref=current branch.
# Examples handled:
#   git push
#   git push origin
#   git push origin main
#   git push origin HEAD:main
#   git push vps-staging staging:main
#   git push -u origin feature/foo
REMOTE=""
REF_SPEC=""
# Tokenize after `git push`.
TOKENS=$(echo "$COMMAND" | sed -E 's/.*\bgit[[:space:]]+push[[:space:]]*//')
# Strip flags (-u, --tags, --set-upstream, etc.) — we only care about positional args.
NON_FLAG=$(echo "$TOKENS" | tr ' ' '\n' | grep -vE '^(-|$)' | head -2)
REMOTE=$(echo "$NON_FLAG" | sed -n '1p')
REF_SPEC=$(echo "$NON_FLAG" | sed -n '2p')

[[ -z "$REMOTE" ]] && REMOTE="origin"
if [[ -z "$REF_SPEC" ]]; then
  REF_SPEC="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
fi
[[ -z "$REF_SPEC" ]] && exit 0

# Extract destination branch from refspec (after the colon, or the whole thing).
DST_BRANCH="${REF_SPEC##*:}"

# Only enforce divergence checks on shared deploy branches; per-feature branches
# can be force-pushed freely (no one else relies on them).
case "$DST_BRANCH" in
  main|master|staging:main) ;;
  *) exit 0 ;;
esac

# Fetch remote SHA via ls-remote (no working-tree side effects).
REMOTE_SHA="$(git ls-remote "$REMOTE" "refs/heads/${DST_BRANCH}" 2>/dev/null | awk '{print $1}' | head -1)"
if [[ -z "$REMOTE_SHA" ]]; then
  # Branch doesn't exist on remote yet, or remote unreachable. Allow.
  exit 0
fi

LOCAL_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"
[[ -z "$LOCAL_SHA" ]] && exit 0

# If remote SHA is in our history, we're at-or-ahead — safe to push.
if git merge-base --is-ancestor "$REMOTE_SHA" "$LOCAL_SHA" 2>/dev/null; then
  exit 0
fi

# Remote has commits we don't have. Block.
cat >&2 <<EOF
Refusing \`git push ${REMOTE} ${REF_SPEC}\`: remote has commits not in local HEAD.

Remote ${REMOTE}/${DST_BRANCH}: ${REMOTE_SHA:0:8}
Local HEAD:                     ${LOCAL_SHA:0:8}

Pushing now would either be rejected as non-fast-forward (you'd then likely retry with --force, dropping someone else's deployed commit), or, with --force-with-lease, would silently overwrite the remote.

Fix:
  git fetch ${REMOTE}
  git rebase ${REMOTE}/${DST_BRANCH}
  # resolve any conflicts, then re-run the push.

If the remote commits are not relevant to your work (e.g. another session
pushed a docs change), \`git rebase\` will replay your commits cleanly on top.
EOF
exit 2
