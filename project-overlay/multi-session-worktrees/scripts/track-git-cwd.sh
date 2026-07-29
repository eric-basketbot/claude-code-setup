#!/usr/bin/env bash
# PreToolUse hook on Bash: blocks git mutations attempted in the canonical
# checkout when isolation policy requires it. Claude keeps the existing
# multi-session behavior; Codex always protects canonical from mutations.
# The error message names the exact worktree the session should `cd` into,
# read from the global registry, so the model retries with the right path
# instead of looping.
#
# Behavior matrix:
#   in_canonical=false                 → log only, exit 0
#   Claude + canonical + sessions == 1 → log + warn (soft), exit 0
#   Claude + canonical + sessions >= 2 → log + block, exit 2
#   Codex  + canonical                  → log + block, exit 2
#
# Read-only verbs are always allowed. `git fetch` / `git status` / `git log`
# / `git diff` / `git show` / `git branch` / `git worktree list` etc. fall
# through.
#
# Audit log lives at ~/.claude/logs/myproject-git-cwd.jsonl as JSON-Lines.
# Use scripts/claude-hooks/git-cwd-report.sh for a quick compliance summary.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

LOG="${LOG_DIR}/myproject-git-cwd.jsonl"

PAYLOAD="$(cat)"
COMMAND="$(echo "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")"
HOOK_HOST="${BB_HOOK_HOST:-claude}"
SESSION_ID="$(echo "$PAYLOAD" | jq -r '.session_id // .conversation_id // .thread_id // "unknown"' 2>/dev/null || echo "unknown")"

# Codex has no Claude auto-worktree/session registry, so its project hook is
# deliberately fail-shut for canonical mutations. The explicit env flag in
# ~/.codex project hooks documents the policy and also supports future hosts.
ALWAYS_BLOCK_CANONICAL="false"
case "${BB_ALWAYS_BLOCK_CANONICAL:-}" in
  1|true|TRUE|yes|YES|on|ON) ALWAYS_BLOCK_CANONICAL="true" ;;
esac
[[ "$HOOK_HOST" == "codex" ]] && ALWAYS_BLOCK_CANONICAL="true"

# Match git verbs that mutate the index / working tree / refs via the shared
# tokenizer. The tokenizer handles `git -C <path> <verb>`, `bash -c "..."`
# wrappers, and cd-chained invocations — and avoids false-positives on
# phrase mentions of `git <verb>` inside argument values (e.g. inside a long
# `gh pr create --body "..."` string). `git fetch` and read-only verbs are
# intentionally excluded. `git push` is gated by a separate hook
# (check-remote-push.sh) that handles divergence + force.
#
# Claude retains its historical verb filter. Codex uses the argument-aware
# mutation profile in _lib.sh, which scans past read-only commands in a chain
# and catches porcelain plus lower-level index/ref/config mutators.
_CLAUDE_VERB_FILTER="add|commit|cherry-pick|reset|rm|merge|rebase|restore|stash"
if [[ "$HOOK_HOST" == "codex" ]]; then
  if ! bb_extract_git_invocation "$COMMAND" "" "" "codex"; then
    _CODEX_RISK_VERBS="add|am|apply|bisect|branch|bundle|checkout|checkout-index|clean|clone|commit|commit-graph|commit-tree|config|fast-import|filter-branch|fsck|gc|hash-object|index-pack|init|maintenance|merge|merge-file|merge-index|merge-one-file|merge-tree|mktag|mktree|multi-pack-index|mv|notes|pack-objects|pack-refs|prune|prune-packed|pull|read-tree|rebase|receive-pack|reflog|refs|remote|repack|replace|replay|reset|restore|revert|rm|rerere|sparse-checkout|stash|submodule|switch|symbolic-ref|tag|unpack-file|unpack-objects|update-index|update-ref|update-server-info|worktree|write-tree"
    bb_command_has_unparsed_git_risk "$COMMAND" "$_CODEX_RISK_VERBS" || exit 0
    BB_GIT_TARGET_TAINTED=1
    BB_GIT_VERB="<unparsed-mutator>"
    BB_GIT_ARGS=""
  fi
else
  bb_extract_git_invocation "$COMMAND" "$_CLAUDE_VERB_FILTER" "$_CLAUDE_VERB_FILTER" || exit 0
fi

VERB="$BB_GIT_VERB"
if [[ "$HOOK_HOST" == "codex" ]]; then
  case "$VERB" in
    add|am|apply|bisect|branch|bundle|checkout|checkout-index|clean|clone|\
    commit|commit-graph|commit-tree|config|fast-import|filter-branch|fsck|gc|\
    hash-object|index-pack|init|maintenance|merge|merge-file|merge-index|\
    merge-one-file|merge-tree|mktag|mktree|multi-pack-index|mv|notes|\
    pack-objects|pack-refs|prune|prune-packed|pull|read-tree|rebase|\
    receive-pack|reflog|refs|remote|repack|replace|replay|reset|restore|\
    revert|rm|rerere|sparse-checkout|stash|submodule|switch|symbolic-ref|\
    tag|unpack-file|unpack-objects|update-index|update-ref|\
    update-server-info|worktree|write-tree)
      ;;
    *) VERB="<unknown-mutator>" ;;
  esac
fi
if [[ "$HOOK_HOST" != "codex" ]]; then
  case "$VERB" in
    add|commit|cherry-pick|reset|rm|merge|rebase|restore) ;;
    stash)
      read -ra _stash_args <<<"$BB_GIT_ARGS"
      # Preserve Claude's existing behavior: only the historically guarded
      # explicit subcommands are intercepted; bare/legacy forms are unchanged.
      case "${_stash_args[0]:-}" in
        push|pop|drop|apply) ;;
        *) exit 0 ;;
      esac
      ;;
    *) exit 0 ;;
  esac
fi

CWD="$(pwd)"
TOP="$(git rev-parse --show-toplevel 2>/dev/null || echo none)"
COUNT="$(bb_count_claude_sessions)"

IN_CANONICAL="false"
[[ "$TOP" == "$CANONICAL" ]] && IN_CANONICAL="true"

# If the command explicitly redirects to a non-canonical worktree (via a
# leading `cd <path>` or a `git -C <path>` flag), allow it. Claude Code
# spawns this hook with pwd=canonical regardless of where the Bash tool's
# persisted shell sits, so $(pwd) alone is unreliable — we have to trust
# the command's own target when it's explicit.
#
# Only the literal-path forms are honored here. Variable-substituted
# targets (e.g. `git -C "$WT" add foo`) can't be resolved at hook time and
# fall through to the canonical block; the model should inline the path.
#
# BB_GIT_TARGET_TAINTED is set by the tokenizer when:
#   1. --git-dir or --work-tree appeared (those decouple index from
#      worktree and can bypass the apparent target)
#   2. Any later mutation in the command resolves to a different/unknown
#      target (including a later `cd` or `git -C` back to canonical)
# When tainted, we refuse to take the explicit-target allow path even when
# BB_GIT_TARGET resolves to a non-canonical worktree, and fall through to
# the standard canonical block.
if [[ "${BB_GIT_TARGET_TAINTED:-0}" == "1" ]]; then
  # Redirecting Git environment variables and --git-dir/--work-tree can point
  # back at canonical even when this hook was launched from a worktree. Codex
  # cannot prove the effective index is isolated, so treat it as canonical.
  IN_CANONICAL="true"
  TOP="<tainted-git-target>"
elif [[ -n "${BB_GIT_TARGET:-}" ]]; then
  TARGET_ABS="$BB_GIT_TARGET"
  case "$TARGET_ABS" in
    *'$'*|*'`'*|*'{'*|*'}'*|*"'"*|*'"'*) TARGET_TOP="" ;;
    *)
      # Codex hook cwd is the command's actual cwd. Claude normally launches
      # project hooks at canonical, making the same base correct there too.
      [[ "${TARGET_ABS:0:1}" == "/" ]] || TARGET_ABS="${CWD}/${TARGET_ABS}"
      TARGET_TOP="$(git -C "$TARGET_ABS" rev-parse --show-toplevel 2>/dev/null || true)"
      ;;
  esac
  if [[ "$TARGET_TOP" == "$CANONICAL" ]]; then
    IN_CANONICAL="true"
    TOP="$CANONICAL"
  elif [[ -n "$TARGET_TOP" ]]; then
    jq -n -c \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg cwd "$CWD" \
      --arg top "$TARGET_TOP" \
      --arg verb "$VERB" \
      --arg hook_host "$HOOK_HOST" \
      --arg session_id "$SESSION_ID" \
      --argjson sessions "${COUNT:-0}" \
      --argjson pid "$$" \
      '{ts: $ts, pid: $pid, hook_host: $hook_host, session_id: $session_id, cwd: $cwd, top: $top, verb: $verb, sessions: $sessions, in_canonical: true, action: "allowed-explicit-target"}' \
      >> "$LOG" 2>/dev/null || true
    exit 0
  else
    # An unresolved or dynamic explicit target cannot establish isolation.
    # Fail closed even when the hook process itself started in a worktree.
    IN_CANONICAL="true"
    TOP="<unresolved-git-target>"
  fi
fi

# Audit log (always written, regardless of block decision).
ACTION="allowed"
SHOULD_BLOCK="false"
if [[ "$IN_CANONICAL" == "true" && "$ALWAYS_BLOCK_CANONICAL" == "true" ]]; then
  ACTION="blocked"
  SHOULD_BLOCK="true"
elif [[ "$IN_CANONICAL" == "true" && "${COUNT:-0}" -ge 2 ]]; then
  ACTION="blocked"
  SHOULD_BLOCK="true"
elif [[ "$IN_CANONICAL" == "true" ]]; then
  ACTION="warned"
fi

jq -n -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg cwd "$CWD" \
  --arg top "$TOP" \
  --arg verb "$VERB" \
  --arg hook_host "$HOOK_HOST" \
  --arg session_id "$SESSION_ID" \
  --arg action "$ACTION" \
  --argjson sessions "${COUNT:-0}" \
  --argjson pid "$$" \
  --argjson in_canonical "$([[ "$IN_CANONICAL" == "true" ]] && echo true || echo false)" \
  '{ts: $ts, pid: $pid, hook_host: $hook_host, session_id: $session_id, cwd: $cwd, top: $top, verb: $verb, sessions: $sessions, in_canonical: $in_canonical, action: $action}' \
  >> "$LOG" 2>/dev/null || true

# Allow if not in canonical.
[[ "$IN_CANONICAL" == "true" ]] || exit 0

# Find the worktree this session was assigned to (set up at SessionStart).
TARGET_WT="$(bb_my_worktree_path)"
TARGET_BRANCH="$(bb_my_worktree_branch)"

if [[ "$SHOULD_BLOCK" == "true" ]]; then
  # BLOCK. Stderr message goes back to the model.
  if [[ "$HOOK_HOST" == "codex" ]]; then
    cat >&2 <<EOF
Refusing \`git ${VERB}\` in the canonical checkout (Codex isolation policy).

Codex always protects canonical's shared index. Use an existing isolated
worktree (\`git worktree list\`) or create one, then run the mutation there:

  git worktree add ${WORKTREE_BASE}/bb-<slug> -b codex/<slug> main
  cd ${WORKTREE_BASE}/bb-<slug>

An explicit \`cd <worktree> && git ...\` or \`git -C <worktree> ...\` is
allowed. Read-only git commands are also allowed in canonical.
EOF
    exit 2
  fi
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
  1. Create one: /wt <slug>   (or: git worktree add ${WORKTREE_BASE}/bb-<slug> -b wt/<slug> main)
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
