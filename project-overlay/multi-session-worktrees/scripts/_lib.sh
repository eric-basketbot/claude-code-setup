#!/usr/bin/env bash
# Shared helpers for the multi-session hygiene hooks. Source with:
#   source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
#
# Designed to be sourced into `set -uo pipefail` scripts without surprises.

CANONICAL="<repo>"
# Keep Claude's established log location by default, while allowing test and
# non-Claude hosts to isolate hook audit output without changing semantics.
LOG_DIR="${BB_LOG_DIR:-${HOME}/.claude/logs}"
REGISTRY_FILE="/tmp/wt-auto-registry.txt"
PURPOSE_FILE_NAME="WORKTREE_PURPOSE.md"
REVIEW_QUEUE_LOG="${LOG_DIR}/myproject-review-queue.log"
ORPHAN_FILES_DIR="${LOG_DIR}/myproject-orphan-files"
CLEANUP_LOG="${LOG_DIR}/myproject-worktree-cleanup.log"

# Base directory for new auto-worktrees. Defaults to ~/.agent-worktrees/,
# which survives macOS reboot (unlike /tmp/, which Apple wipes on every boot
# — that wipe is what caused the 2026-05-20 PR6 work loss). Override via
# BB_WORKTREE_BASE in tests or for ephemeral setups.
#
# Legacy worktrees in /tmp/wt-auto-* are still recognized by all path-checking
# code so a transition session can clean them up; only NEW worktrees land
# under WORKTREE_BASE.
WORKTREE_BASE="${BB_WORKTREE_BASE:-${HOME}/.agent-worktrees}"

# Log/orphan dirs are best-effort; failures here are harmless. WORKTREE_BASE
# is load-bearing — without it the next auto-worktree creation will fail
# with a confusing `git worktree add: parent dir doesn't exist`. Surface a
# warning so the failure mode is obvious in stderr (CodeRabbit r1).
mkdir -p "$LOG_DIR" "$ORPHAN_FILES_DIR" 2>/dev/null || true
if ! mkdir -p "$WORKTREE_BASE" 2>/dev/null; then
  echo "warn: could not create WORKTREE_BASE at $WORKTREE_BASE — auto-worktree creation will fail until this is fixed (check permissions / disk space / BB_WORKTREE_BASE override)" >&2
fi

# Path-matcher: returns 0 if $1 looks like an auto-worktree directory.
# Recognizes BOTH the new WORKTREE_BASE/wt-auto-* paths AND the legacy
# /tmp/wt-auto-* / /private/tmp/wt-auto-* paths (transition window).
# Centralizes the pattern so every consumer agrees on what "auto" means.
bb_is_auto_worktree_path() {
  local p="${1:-}"
  case "$p" in
    /tmp/wt-auto-*|/private/tmp/wt-auto-*) return 0 ;;
  esac
  # Match the resolved WORKTREE_BASE (handles ~/ expansion) plus any
  # /private-prefixed symlink-resolved form macOS hands back from `pwd -P`.
  # The /private branch is dormant for the default ~/.agent-worktrees
  # base (macOS doesn't /private-prefix $HOME paths). It's defensive for the
  # BB_WORKTREE_BASE override case where the user might point at a path
  # that IS resolved through the /private symlink tree (e.g. /var/tmp/…,
  # /tmp/… overrides).
  local base="$WORKTREE_BASE"
  case "$p" in
    "${base}/wt-auto-"*|"/private${base}/wt-auto-"*) return 0 ;;
  esac
  return 1
}

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

# ----------------------------------------------------------------------------
# Git-command extraction (used by track-git-cwd.sh and check-remote-push.sh)
#
# Both hooks previously did `echo "$COMMAND" | grep -qE '\bgit[[:space:]]+<verb>\b'`,
# which has three known gaps:
#   1. Misses `git -C <path> <verb>` / `git --git-dir=X <verb>` — the regex
#      wants git directly followed by the verb.
#   2. Misses `bash -c '<inner git push>'` because the inner command is wrapped.
#   3. False-positives on phrase-mentions of `git <verb>` inside argument
#      values (e.g. `gh pr create --body "...git merge..."`).
#
# `bb_extract_git_invocation` tokenizes properly:
#   - splits the command on shell separators (; && || | & newline)
#   - per segment, optionally skips a leading `cd <path>` prefix
#   - recognizes `bash -c '<inner>'` / `sh -c "..."` wrappers and recurses
#   - matches `git` as a freestanding command, skipping its flags (-C, -c,
#     --git-dir, --work-tree, etc.) to reach the verb
#   - sets BB_GIT_VERB to the verb and BB_GIT_ARGS to the space-joined
#     remaining tokens, then returns 0
#   - sets BB_GIT_TARGET to the explicit worktree path the command operates
#     against, recovered from a leading `cd <path>` prefix or a `git -C <path>`
#     flag. Empty when the command is bare.
#   - sets BB_GIT_TARGET_SOURCE to "cd" when the target came from a `cd`
#     (carries forward across persist-separated segments in the chain) or
#     "C" when from a `git -C` flag (applies only to that one invocation —
#     does NOT carry to chained `git ...` segments that follow).
#   - sets BB_GIT_TARGET_TAINTED=1 when the matching git invocation contains
#     `--git-dir` or `--work-tree`, OR when there is a SUBSEQUENT mutating
#     git verb after a -C-sourced first match (those subsequent verbs would
#     run from the shell's natural cwd, not the -C target). The hook MUST
#     refuse to allow when tainted; the `cd /wt && git --git-dir=$CANONICAL
#     --work-tree=/wt add foo` and `git -C /wt add foo && git commit -m x`
#     bypasses Codex flagged 2026-05-19 both surface here.
#
#     `cd` carry-over respects bash separator semantics: persist across
#     `&&`, `;`, and `\n`; reset across `||`, `|`, and `&` (subshell spawn
#     or failed-cd branch). Without this distinction, `cd /tmp/wt | git add
#     canonical-file` would falsely pass the explicit-target allow path.
# Returns 1 (with all BB_GIT_* globals empty / 0) when no match.
#
# Known remaining limitations (the tokenizer is intentionally NOT a full
# shell parser):
#
# A. Fail-CLOSED limitations (legitimate commands get false-blocked, never
#    falsely allowed):
#   1. Multi-line argument values whose lines happen to be valid git
#      commands (e.g. a markdown code block containing `git add foo` on its
#      own line inside a PR body) parse as if they were chained
#      invocations. Workaround: pass long bodies via --body-file.
#   2. Shell separators (`&&`, `||`, `;`, `|`, `&`, `\n`) inside quoted
#      argument values are also normalized, e.g. `git commit -m "fix; tail"`
#      truncates the message body at `;`. Confirmed pre-existing (same
#      behavior in the original tokenizer); the failure mode is fail-CLOSED
#      — the truncated parse produces an empty BB_GIT_TARGET, the hook falls
#      through to the canonical block, the legitimate command is refused
#      until the model rewrites it without inline separators. Gemini flagged
#      this 2026-05-19; severity adjusted from CRITICAL (Gemini's call) to
#      KNOWN-LIMITATION because no exploit could be constructed against it.
#
# B. Fail-OPEN limitations (adversarial bash forms can bypass the canonical
#    block). None appear in real Claude usage per the block log, but a
#    deliberately-crafted command can exploit any of these. Three rounds of
#    cross-vendor review (Codex + CodeRabbit + Gemini + Claude) on 2026-05-19
#    surfaced these classes:
#   1. `(git add foo)` / `((...))` — subshell parens. Tokenizer treats `(git`
#      as a non-git first token; helper returns no match; hook exits 0.
#   2. `{ git add foo; }` — brace group. Same root cause as 1.
#   3. `env git add foo`, `command git ...`, `exec git ...`, `time git ...`,
#      `pushd ... ; git ...` — utility prefixes. Tokenizer expects `git` as
#      first token (or after `cd`/`bash -c` wrapper).
#   4. `GIT_DIR=$CANONICAL/.git git add foo`, `FOO=bar git add foo`, generally
#      any `VAR=val git ...` — env-var prefix. Same as 3. The `GIT_*=`
#      variants additionally let canonical's index be the actual write target
#      even when the worktree path looks innocent.
#   5. `cd /wt && git add foo && cd $CANONICAL && git commit` — chained cd
#      where a later segment cds into canonical. Helper records the FIRST
#      cd target and doesn't propagate later cd retargets.
#   6. `false && cd /wt ; git add foo` — `&&` short-circuit means the cd
#      never executed, but the helper sees a `cd /wt` segment and trusts it.
#      Symmetric form: `cd /wt bogus ; git add foo` where `cd` fails with
#      "too many arguments" but the helper still records /wt as target.
#   7. `cd /wt ; pushd $CANONICAL ; git add foo` — bash builtins that change
#      cwd (`pushd`, `popd`, `source`) aren't modeled.
#
# The fix space for B is large: a complete bash-grammar-aware tokenizer in
# pure bash isn't tractable. The hook is intentionally a workflow guardrail,
# not a security boundary against an adversarial Claude. If the model
# generates one of these B-class forms, that's a model-behavior issue to
# investigate separately, not a hook-design failure to keep iterating.
# ----------------------------------------------------------------------------

# Return 0 when a parsed git invocation can mutate the current repository,
# and 1 when it is read-only. This profile is intentionally broader than the
# legacy Claude guard: Codex always protects canonical, while Claude keeps its
# established verb set. Mixed read/write verbs are classified by subcommand or
# option so inspection commands remain usable.
bb_git_is_codex_mutation() {
  local verb="${1:-}" args="${2:-}"
  case "$verb" in
    am|cherry-pick|checkout|checkout-index|clone|commit-tree|fast-import|\
    filter-branch|gc|index-pack|init|maintenance|merge|merge-file|merge-index|\
    merge-one-file|mktag|mktree|pack-objects|pack-refs|prune-packed|pull|\
    read-tree|rebase|receive-pack|repack|replay|reset|restore|revert|switch|\
    unpack-file|unpack-objects|update-index|update-ref|write-tree)
      return 0
      ;;
    add) _bb_codex_short_dry_run_mutates "$args"; return $? ;;
    commit) _bb_codex_long_dry_run_mutates "$args"; return $? ;;
    mv|rm|prune) _bb_codex_short_dry_run_mutates "$args"; return $? ;;
    apply) _bb_codex_apply_mutates "$args"; return $? ;;
    clean) _bb_codex_clean_mutates "$args"; return $? ;;
    branch) _bb_codex_branch_mutates "$args"; return $? ;;
    tag) _bb_codex_tag_mutates "$args"; return $? ;;
    stash)
      local stash_args=()
      read -ra stash_args <<<"$args"
      case "$(_bb_strip_quotes "${stash_args[0]:-}")" in
        list|show) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    notes) _bb_codex_notes_mutates "$args"; return $? ;;
    worktree) _bb_codex_worktree_mutates "$args"; return $? ;;
    remote) _bb_codex_remote_mutates "$args"; return $? ;;
    config) _bb_codex_config_mutates "$args"; return $? ;;
    sparse-checkout)
      local sparse_args=()
      read -ra sparse_args <<<"$args"
      case "$(_bb_strip_quotes "${sparse_args[0]:-}")" in
        list|check-rules) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    submodule) _bb_codex_submodule_mutates "$args"; return $? ;;
    replace)
      local replace_args=()
      read -ra replace_args <<<"$args"
      case "$(_bb_strip_quotes "${replace_args[0]:-}")" in
        ""|-l|--list) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    reflog)
      local reflog_args=()
      read -ra reflog_args <<<"$args"
      case "$(_bb_strip_quotes "${reflog_args[0]:-}")" in
        ""|show|list|exists) return 1 ;;
        expire) _bb_codex_long_dry_run_mutates "$args"; return $? ;;
        *) return 0 ;;
      esac
      ;;
    rerere)
      local rerere_args=()
      read -ra rerere_args <<<"$args"
      case "$(_bb_strip_quotes "${rerere_args[0]:-}")" in
        status|diff|remaining) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    bisect)
      local bisect_args=()
      read -ra bisect_args <<<"$args"
      case "$(_bb_strip_quotes "${bisect_args[0]:-}")" in
        log|view) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    symbolic-ref) _bb_codex_symbolic_ref_mutates "$args"; return $? ;;
    hash-object)
      local hash_args=() hash_tok
      read -ra hash_args <<<"$args"
      for hash_tok in "${hash_args[@]+"${hash_args[@]}"}"; do
        hash_tok="$(_bb_strip_quotes "$hash_tok")"
        case "$hash_tok" in -w|--literally) return 0 ;; esac
      done
      return 1
      ;;
    fsck) _bb_codex_fsck_mutates "$args"; return $? ;;
    bundle) _bb_codex_bundle_mutates "$args"; return $? ;;
    refs) _bb_codex_refs_mutates "$args"; return $? ;;
    archive|diff|diff-files|diff-index|diff-tree|log|range-diff|shortlog|show|\
    whatchanged)
      _bb_codex_output_option_mutates "$args"
      return $?
      ;;
    commit-graph) _bb_codex_named_subcommand_mutates "$args" "verify"; return $? ;;
    multi-pack-index) _bb_codex_named_subcommand_mutates "$args" "verify"; return $? ;;
    merge-tree) _bb_codex_merge_tree_mutates "$args"; return $? ;;
    update-server-info) return 0 ;;
    # Explicit read-only allowlist. Unknown verbs fail closed so newly added
    # Git porcelain/plumbing cannot silently bypass canonical protection.
    # `push` is handled by check-remote-push.sh. `fetch` remains an allowed
    # synchronization command by longstanding <project> hook policy.
    annotate|blame|cat-file|check-attr|check-ignore|check-mailmap|\
    check-ref-format|cherry|column|count-objects|describe|\
    fetch|for-each-ref|grep|help|ls-files|ls-remote|ls-tree|merge-base|\
    name-rev|patch-id|push|rev-list|rev-parse|show-branch|\
    show-index|show-ref|status|stripspace|verify-commit|verify-pack|\
    verify-tag|version)
      return 1
      ;;
    *) return 0 ;;
  esac
}

_bb_codex_short_dry_run_mutates() {
  local args="${1:-}" tokens=() token short dry_run=0
  read -ra tokens <<<"$args"
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    token="$(_bb_strip_quotes "$token")"
    case "$token" in
      --) break ;;
      --no-dry*) return 0 ;;
      -n|--dry|--dry-run) dry_run=1 ;;
      -*)
        short="${token#-}"
        [[ "$short" != -* && "$short" == *n* ]] && dry_run=1
        ;;
    esac
  done
  [[ $dry_run -eq 1 ]] && return 1
  return 0
}

_bb_codex_long_dry_run_mutates() {
  local args="${1:-}" tokens=() token dry_run=0
  read -ra tokens <<<"$args"
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    token="$(_bb_strip_quotes "$token")"
    case "$token" in
      --) break ;;
      --no-dry*) return 0 ;;
      --dry|--dry-run) dry_run=1 ;;
    esac
  done
  [[ $dry_run -eq 1 ]] && return 1
  return 0
}

_bb_codex_fsck_mutates() {
  local args="${1:-}" tokens=() token
  read -ra tokens <<<"$args"
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    token="$(_bb_strip_quotes "$token")"
    [[ "$token" == --lost* ]] && return 0
  done
  return 1
}

_bb_codex_bundle_mutates() {
  local args="${1:-}" tokens=() token subcommand=""
  read -ra tokens <<<"$args"
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    token="$(_bb_strip_quotes "$token")"
    case "$token" in -*) ;; *) subcommand="$token"; break ;; esac
  done
  case "$subcommand" in verify|list-heads) return 1 ;; *) return 0 ;; esac
}

_bb_codex_refs_mutates() {
  local args="${1:-}" tokens=() token subcommand=""
  read -ra tokens <<<"$args"
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    token="$(_bb_strip_quotes "$token")"
    case "$token" in
      --dry-run|--no-dry-run) ;;
      -*) ;;
      *) [[ -z "$subcommand" ]] && subcommand="$token" ;;
    esac
  done
  case "$subcommand" in
    verify|list) return 1 ;;
    migrate) _bb_codex_long_dry_run_mutates "$args"; return $? ;;
    *) return 0 ;;
  esac
}

_bb_codex_submodule_mutates() {
  local args="${1:-}" tokens=() token subcommand=""
  read -ra tokens <<<"$args"
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    token="$(_bb_strip_quotes "$token")"
    case "$token" in
      -q|--quiet|--cached) ;;
      -*) return 0 ;;
      *) subcommand="$token"; break ;;
    esac
  done
  case "$subcommand" in ""|status|summary) return 1 ;; *) return 0 ;; esac
}

_bb_codex_output_option_mutates() {
  local args="${1:-}" tokens=() token
  read -ra tokens <<<"$args"
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    token="$(_bb_strip_quotes "$token")"
    case "$token" in
      --) break ;;
      -o|-o?*|--output|--output=*) return 0 ;;
    esac
  done
  return 1
}

_bb_codex_apply_mutates() {
  local args="${1:-}" tokens=() token
  local preview=0 explicit_apply=0
  read -ra tokens <<<"$args"
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    token="$(_bb_strip_quotes "$token")"
    case "$token" in
      --) break ;;
      --no-apply) explicit_apply=0 ;;
      --apply|--app*) explicit_apply=1 ;;
      --check|--stat|--numstat|--summary) preview=1 ;;
      --verbose|--quiet) ;;
      --*) return 0 ;;
    esac
  done
  [[ $preview -eq 1 && $explicit_apply -eq 0 ]] && return 1
  return 0
}

_bb_codex_clean_mutates() {
  local args="${1:-}" tokens=() token short dry_run=0
  read -ra tokens <<<"$args"
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    token="$(_bb_strip_quotes "$token")"
    case "$token" in
      --) break ;;
      --no-dry*) return 0 ;;
      -n|--dry|--dry-run) dry_run=1 ;;
      -*)
        short="${token#-}"
        [[ "$token" != --* && "$short" == *n* ]] && dry_run=1
        ;;
    esac
  done
  [[ $dry_run -eq 1 ]] && return 1
  return 0
}

_bb_codex_branch_mutates() {
  local args="${1:-}" tokens=() token
  local i=0 n list_mode=0
  read -ra tokens <<<"$args"
  n=${#tokens[@]}
  [[ $n -eq 0 ]] && return 1
  while [[ $i -lt $n ]]; do
    token="$(_bb_strip_quotes "${tokens[$i]}")"
    if [[ "$token" == -?* && "$token" != --* ]]; then
      local short_cluster="${token#-}"
      [[ "$short_cluster" == *[dDmMcCftu]* ]] && return 0
      if [[ "$short_cluster" =~ ^[arlivq]+$ ]]; then
        [[ "$short_cluster" == *[arl]* ]] && list_mode=1
        i=$((i + 1))
        continue
      fi
    fi
    case "$token" in
      -d|-D|-m|-M|-c|-C|-f|--delete|--move|--copy|--edit-description|\
      --unset-upstream|--no-track|--recurse-submodules|--set-upstream-to=*|\
      --track|--track=*|--force)
        return 0
        ;;
      --set-upstream-to) return 0 ;;
      -a|--all|-r|--remotes|-l|--list|-a*|-r*|--show-current)
        list_mode=1
        ;;
      -i|-v|-vv|-q|--quiet|--verbose|--no-verbose|--no-quiet|--ignore-case|\
      --no-ignore-case|--omit-empty|--no-omit-empty|--no-abbrev|--no-sort|\
      --no-format|--no-color|--no-column|\
      --color|--column|--abbrev|--color=*|--column=*|--format=*|--sort=*|--abbrev=*)
        ;;
      --contains=*|--no-contains=*|--merged=*|--no-merged=*|--points-at=*)
        list_mode=1
        ;;
      --no-points-at) list_mode=0 ;;
      --contains|--no-contains|--merged|--no-merged|--points-at)
        list_mode=1
        i=$((i + 1))
        ;;
      --format|--sort)
        i=$((i + 1))
        ;;
      --)
        i=$((i + 1))
        [[ $i -lt $n && $list_mode -eq 0 ]] && return 0
        return 1
        ;;
      -*) return 0 ;;
      *) [[ $list_mode -eq 1 ]] || return 0 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

_bb_codex_tag_mutates() {
  local args="${1:-}" tokens=() token
  local i=0 n list_mode=0 verify_mode=0
  read -ra tokens <<<"$args"
  n=${#tokens[@]}
  [[ $n -eq 0 ]] && return 1
  while [[ $i -lt $n ]]; do
    token="$(_bb_strip_quotes "${tokens[$i]}")"
    case "$token" in
      -d|--delete|-f|--force|-a|--annotate|-s|--sign|-u|--local-user|-m|--message|-F|--file|--cleanup|--create-reflog|\
      --local-user=*|--message=*|--file=*|--cleanup=*)
        return 0
        ;;
      -v|--verify) verify_mode=1 ;;
      -l|--list)
        list_mode=1
        ;;
      -n|-n[0-9]*)
        list_mode=1
        ;;
      -i|--ignore-case|--no-ignore-case|--omit-empty|\
      --no-omit-empty|--no-sort|--no-format|\
      --no-create-reflog|--no-column|--no-color|\
      --column|--color|--column=*|--format=*|--sort=*|--color=*)
        ;;
      --contains=*|--no-contains=*|--merged=*|--no-merged=*|--points-at=*)
        list_mode=1
        ;;
      --no-points-at) list_mode=0 ;;
      --contains|--no-contains|--merged|--no-merged|--points-at)
        list_mode=1
        i=$((i + 1))
        ;;
      --format|--sort)
        i=$((i + 1))
        ;;
      --)
        i=$((i + 1))
        [[ $i -lt $n && $list_mode -eq 0 && $verify_mode -eq 0 ]] && return 0
        return 1
        ;;
      -*) return 0 ;;
      *) [[ $list_mode -eq 1 || $verify_mode -eq 1 ]] || return 0 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

_bb_codex_notes_mutates() {
  local args="${1:-}" tokens=() token subcommand=""
  local i=0 n subcommand_idx=-1
  read -ra tokens <<<"$args"
  n=${#tokens[@]}
  while [[ $i -lt $n ]]; do
    token="$(_bb_strip_quotes "${tokens[$i]}")"
    case "$token" in
      --ref|--notes-ref) i=$((i + 1)) ;;
      --ref=*|--notes-ref=*) ;;
      -*) ;;
      *) subcommand="$token"; subcommand_idx=$i; break ;;
    esac
    i=$((i + 1))
  done
  case "$subcommand" in
    ""|list|show|get-ref) return 1 ;;
    prune)
      _bb_codex_short_dry_run_mutates "$args"
      return $?
      ;;
    *) return 0 ;;
  esac
}

_bb_codex_worktree_mutates() {
  local args="${1:-}" tokens=() token subcommand=""
  local i=0 n subcommand_idx=-1
  read -ra tokens <<<"$args"
  n=${#tokens[@]}
  while [[ $i -lt $n ]]; do
    token="$(_bb_strip_quotes "${tokens[$i]}")"
    case "$token" in
      -h|--help) return 1 ;;
      -*) ;;
      *) subcommand="$token"; subcommand_idx=$i; break ;;
    esac
    i=$((i + 1))
  done
  case "$subcommand" in
    ""|list) return 1 ;;
    prune)
      _bb_codex_short_dry_run_mutates "$args"
      return $?
      ;;
    *) return 0 ;;
  esac
}

_bb_codex_remote_mutates() {
  local args="${1:-}" tokens=() token subcommand=""
  local i=0 n
  read -ra tokens <<<"$args"
  n=${#tokens[@]}
  while [[ $i -lt $n ]]; do
    token="$(_bb_strip_quotes "${tokens[$i]}")"
    case "$token" in
      -v|--verbose) ;;
      -h|--help) return 1 ;;
      -*) return 0 ;;
      *) subcommand="$token"; break ;;
    esac
    i=$((i + 1))
  done
  case "$subcommand" in
    ""|show|get-url) return 1 ;;
    prune) _bb_codex_short_dry_run_mutates "$args"; return $? ;;
    *) return 0 ;;
  esac
}

_bb_codex_config_mutates() {
  local args="${1:-}" tokens=() token
  local i=0 n positional=0 read_action=0 saw_subcommand=0
  read -ra tokens <<<"$args"
  n=${#tokens[@]}
  while [[ $i -lt $n ]]; do
    token="$(_bb_strip_quotes "${tokens[$i]}")"
    case "$token" in
      --add|--replace-all|--unset|--unset-all|--rename-section|--remove-section|-e|--edit)
        return 0
        ;;
      --get|--get-all|--get-regexp|--get-urlmatch|--get-color|--get-colorbool|-l|--list)
        read_action=1
        ;;
      --show-origin|--show-names|--show-scope|--bool|--int|--bool-or-int|\
      --bool-or-str|--path|--expiry-date)
        ;;
      --file|-f|--blob|--type|--default|--comment) i=$((i + 1)) ;;
      --file=*|--blob=*|--type=*|--default=*|--comment=*|--global|--system|--local|--worktree|--includes|--no-includes|--null|-z|--name-only|--fixed-value|--all|--regexp|--value=*)
        ;;
      --) ;;
      -*) return 0 ;;
      *)
        if [[ $saw_subcommand -eq 0 ]]; then
          case "$token" in
            get|list) read_action=1; saw_subcommand=1 ;;
            set|unset|rename-section|remove-section|edit) return 0 ;;
            *) positional=$((positional + 1)); saw_subcommand=1 ;;
          esac
        else
          positional=$((positional + 1))
        fi
        ;;
    esac
    i=$((i + 1))
  done
  [[ $read_action -eq 1 ]] && return 1
  [[ $positional -ge 2 ]] && return 0
  return 1
}

_bb_codex_named_subcommand_mutates() {
  local args="${1:-}" read_subcommands="${2:-}" tokens=() token subcommand=""
  local i=0 n
  read -ra tokens <<<"$args"
  n=${#tokens[@]}
  while [[ $i -lt $n ]]; do
    token="$(_bb_strip_quotes "${tokens[$i]}")"
    case "$token" in
      --object-dir) i=$((i + 1)) ;;
      --object-dir=*) ;;
      -h|--help) return 1 ;;
      -*) ;;
      *) subcommand="$token"; break ;;
    esac
    i=$((i + 1))
  done
  case "|$read_subcommands|" in
    *"|$subcommand|"*) return 1 ;;
  esac
  [[ -z "$subcommand" ]] && return 1
  return 0
}

_bb_codex_merge_tree_mutates() {
  local args="${1:-}" tokens=() token
  local i=0 n positional=0 write_mode=0 trivial_mode=0
  read -ra tokens <<<"$args"
  n=${#tokens[@]}
  while [[ $i -lt $n ]]; do
    token="$(_bb_strip_quotes "${tokens[$i]}")"
    case "$token" in
      --write-tree|--stdin|--std*) write_mode=1 ;;
      --trivial-merge) trivial_mode=1 ;;
      --merge-base|-X|--strategy-option) i=$((i + 1)) ;;
      --merge-base=*|--strategy-option=*|--messages|--no-messages|--quiet|-z|--name-only|--allow-unrelated-histories) ;;
      -*) ;;
      *) positional=$((positional + 1)) ;;
    esac
    i=$((i + 1))
  done
  [[ $trivial_mode -eq 1 ]] && return 1
  [[ $write_mode -eq 1 || $positional -eq 2 ]] && return 0
  return 1
}

_bb_codex_symbolic_ref_mutates() {
  local args="${1:-}" tokens=() token positional=0
  read -ra tokens <<<"$args"
  for token in "${tokens[@]+"${tokens[@]}"}"; do
    token="$(_bb_strip_quotes "$token")"
    case "$token" in
      -d|--delete) return 0 ;;
      -q|--quiet|--short) ;;
      -*) return 0 ;;
      *) positional=$((positional + 1)) ;;
    esac
  done
  [[ $positional -ge 2 ]] && return 0
  return 1
}

# Report how a standalone shell segment changes Git repository/index redirect
# state for later persist-separated commands. The result is "taint" or
# "none". Taint is deliberately monotonic within one parsed command: a later
# `unset` of one variable cannot prove that every earlier redirect was cleared.
_bb_segment_git_env_effect() {
  local seg="${1:-}" tokens=() token name first
  # Conservatively recognize redirect assignments anywhere in a shell-grammar
  # segment (`then export ...`, case arms, function bodies). This helper only
  # influences a later Git mutation; a false positive therefore asks the agent
  # to split the command rather than allowing an ambiguous index target.
  case "$seg" in
    *GIT_DIR=*|*GIT_COMMON_DIR=*|*GIT_WORK_TREE=*|*GIT_INDEX_FILE=*|*GIT_OBJECT_DIRECTORY=*|*GIT_ALTERNATE_OBJECT_DIRECTORIES=*)
      printf '%s' taint
      return
      ;;
  esac
  read -ra tokens <<<"$seg"
  [[ ${#tokens[@]} -gt 0 ]] || { printf '%s' none; return; }
  first="$(_bb_strip_quotes "${tokens[0]}")"
  first="${first#\(}"
  first="${first#\{}"
  case "$first" in
    export)
      for token in "${tokens[@]:1}"; do
        token="$(_bb_strip_quotes "$token")"
        [[ "$token" == -* ]] && continue
        name="${token%%=*}"
        case "$name" in
          GIT_DIR|GIT_COMMON_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES)
            printf '%s' taint
            return
            ;;
        esac
      done
      ;;
    declare|typeset)
      local saw_export_flag=0
      for token in "${tokens[@]:1}"; do
        token="$(_bb_strip_quotes "$token")"
        if [[ "$token" == -?* && "$token" != --* ]]; then
          [[ "${token#-}" == *x* ]] && saw_export_flag=1
          continue
        fi
        [[ "$saw_export_flag" == "1" ]] || continue
        name="${token%%=*}"
        case "$name" in
          GIT_DIR|GIT_COMMON_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES)
            printf '%s' taint
            return
            ;;
        esac
      done
      ;;
    [A-Za-z_]=*|[A-Za-z_][A-Za-z0-9_]*=*)
      for token in "${tokens[@]}"; do
        token="$(_bb_strip_quotes "$token")"
        case "$token" in
          [A-Za-z_]=*|[A-Za-z_][A-Za-z0-9_]*=*) name="${token%%=*}" ;;
          *) break ;;
        esac
        case "$name" in
          GIT_DIR|GIT_COMMON_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES)
            printf '%s' taint
            return
            ;;
        esac
      done
      ;;
  esac
  printf '%s' none
}

# Return 0 when a command contains a literal Git executable plus one of the
# supplied verbs, but the structured parser could not explain it. This is the
# final fail-closed boundary for unusual shell grammar. Pure display/PR-body
# commands remain exempt when they contain no execution control syntax.
bb_command_has_unparsed_git_risk() {
  local cmd="${1:-}" verbs="${2:-}" tokens=() first="" verb _risk_verbs=()
  [[ -n "$cmd" && -n "$verbs" ]] || return 1
  read -ra tokens <<<"$cmd"
  [[ ${#tokens[@]} -gt 0 ]] || return 1
  first="$(_bb_strip_quotes "${tokens[0]}")"
  case "$first" in
    git|*/git)
      # A single ordinary Git invocation was already parsed and classified as
      # read-only by the argument-aware Codex profile. Only re-enter the risk
      # backstop when shell control syntax can hide a later invocation.
      case "$cmd" in
        *';'*|*'|'*|*'&'*|*'$('*|*'`'*|*$'\n'*) ;;
        *) return 1 ;;
      esac
      ;;
    echo|printf)
      case "$cmd" in
        *';'*|*'|'*|*'&'*|*'$('*|*'`'*|*$'\n'*) ;;
        *) return 1 ;;
      esac
      ;;
    gh)
      case "$cmd" in
        *';'*|*'|'*|*'&'*|*'$('*|*'`'*|*$'\n'*) ;;
        *) return 1 ;;
      esac
      ;;
  esac
  [[ "$cmd" =~ (^|[^A-Za-z0-9_-])([^[:space:];|\&(){}]*/)?git([[:space:]]|$) ]] || return 1
  local _old_ifs="$IFS"
  IFS='|'
  read -ra _risk_verbs <<<"$verbs"
  IFS="$_old_ifs"
  for verb in "${_risk_verbs[@]}"; do
    [[ "$cmd" =~ (^|[[:space:];|\&(){}])${verb}([[:space:];|\&(){}]|$) ]] && return 0
  done
  return 1
}

bb_extract_git_invocation() {
  BB_GIT_VERB=""
  BB_GIT_ARGS=""
  BB_GIT_TARGET=""
  BB_GIT_TARGET_SOURCE=""
  BB_GIT_TARGET_TAINTED=0
  BB_GIT_MULTIPLE_MATCHES=0
  local cmd="${1:-}"
  # Optional second argument: pipe-separated whitelist of verbs to match.
  # Empty / unset = match any verb (back-compat with the original API).
  # When set, the helper scans every segment and returns only when it finds
  # a `git <verb>` whose verb is in the filter — this prevents a non-target
  # git invocation earlier in a chain (e.g. `git status && git push origin
  # main`) from short-circuiting the search and leaving the real target
  # invocation unchecked.
  local verb_filter="${2:-}"
  # Optional third argument: verbs considered mutating when deciding whether
  # a later bare invocation taints an earlier `git -C <worktree>` match.
  # Default preserves Claude's established guard behavior; Codex supplies its
  # broader mutation set from track-git-cwd.sh.
  local taint_verbs="${3:-add|commit|cherry-pick|reset|rm|merge|rebase|restore|stash}"
  # Optional fourth argument enables argument-aware mutation classification.
  # `codex` scans past read-only invocations in mixed chains and matches only
  # actual mutations.
  local mutation_profile="${4:-}"
  [[ -z "$cmd" ]] && return 1

  # Tokenize the command into segments, tracking whether each segment's
  # preceding separator preserves the parent shell's cwd or not. This matters
  # for cd carry-over across segments:
  #
  #   `&&`, `;`, `\n`  → persist:  `cd /a && git push` → git runs from /a
  #   `||`            → break:    if git appears on the right of `||`, it
  #                                only runs when cd FAILED — meaning the
  #                                parent's cwd is unchanged. carrying /a
  #                                across would falsely allow a canonical
  #                                mutation (Claude's own round-2 pass).
  #   `|`, `&`        → break:    `cd /a | git push` runs cd in a subshell,
  #                                so the parent's cwd is untouched and git
  #                                runs from the original cwd. carry-over
  #                                across these would be a hook bypass.
  #
  # Without this distinction, an attacker (or, more realistically, an
  # adversarial AI) could write `cd /tmp/bb-x | git add canonical-file` and
  # the hook would allow it. Codex flagged this 2026-05-19.
  #
  # Two sentinels: \x01 = persist (cd survives), \x02 = break (cd resets).
  # BSD tr on macOS does not interpret \xNN inside argument strings, so we
  # bind via ANSI-C quoting and re-expand into the tr set1.
  local persist=$'\x01'
  local breakx=$'\x02'
  local normalized="$cmd"
  normalized="${normalized//&&/$persist}"
  normalized="${normalized//||/$breakx}"
  normalized="$(printf '%s' "$normalized" | tr ";${persist}" "${persist}${persist}")"
  normalized="$(printf '%s' "$normalized" | tr $'\n' "${persist}")"
  normalized="$(printf '%s' "$normalized" | tr '|&' "${breakx}${breakx}")"

  # Walk char-by-char, building (segment, preceded-by-break) pairs. The first
  # segment is treated as preceded-by-persist (no break separator before it).
  local -a _segs=()
  local -a _is_break=()
  local cur=""
  local sep_was_break=0
  local _i=0 _len=${#normalized}
  while (( _i < _len )); do
    local _ch="${normalized:$_i:1}"
    if [[ "$_ch" == "$persist" ]]; then
      _segs+=("$cur"); _is_break+=("$sep_was_break"); cur=""; sep_was_break=0
    elif [[ "$_ch" == "$breakx" ]]; then
      _segs+=("$cur"); _is_break+=("$sep_was_break"); cur=""; sep_was_break=1
    else
      cur+="$_ch"
    fi
    _i=$(( _i + 1 ))
  done
  _segs+=("$cur"); _is_break+=("$sep_was_break")

  # Track the most recent `cd <path>` seen across persist-separated segments
  # so a later git invocation in the same chain can inherit it. A break
  # separator (|, &) resets the carry — `cd /a | git push` does NOT change
  # git's cwd in bash.
  local pending_cd_target=""
  local pending_git_redirect_taint=0

  # Strategy: scan ALL segments end-to-end so we can detect chained git
  # invocations where a -C-sourced first match would mutate the worktree
  # but a SUBSEQUENT bare git verb falls back to the shell's natural cwd
  # (canonical for our purposes). Codex flagged that bypass 2026-05-19.
  #
  # We track the first matching segment (under verb_filter, if any) and
  # also count subsequent mutating git verbs in the chain. If the first
  # match was -C-sourced AND any subsequent mutating verb exists, taint
  # the result so the hook refuses to allow.
  #
  # Mutating-verb set used for the "subsequent" detection: matches the set
  # in track-git-cwd.sh exactly so the helper's tainting decision lines up
  # with what the hook would block on its own. Kept in sync via this
  # constant.
  local _mut_verbs="$taint_verbs"

  local _first_verb="" _first_args="" _first_target="" _first_source=""
  local _first_tainted=0 _first_idx=-1 _multiple_filter_hits=0
  local _saw_subsequent_mutator=0 _subsequent_target_mismatch=0

  local _idx
  for _idx in "${!_segs[@]}"; do
    local seg="${_segs[$_idx]}"
    local was_break="${_is_break[$_idx]}"
    # Reset pending cd when a break separator preceded this segment.
    if [[ "$was_break" == "1" ]]; then
      pending_cd_target=""
      pending_git_redirect_taint=0
    fi
    [[ -z "$seg" ]] && continue
    # Reset per-iteration so a rejected match doesn't leak globals into the
    # next iteration.
    BB_GIT_VERB=""
    BB_GIT_ARGS=""
    BB_GIT_TARGET=""
    BB_GIT_TARGET_SOURCE=""
    BB_GIT_TARGET_TAINTED=0
    BB_GIT_MULTIPLE_MATCHES=0
    [[ "$pending_git_redirect_taint" == "1" ]] && BB_GIT_TARGET_TAINTED=1
    if _bb_segment_match_git "$seg" "$verb_filter" "$taint_verbs" "$mutation_profile"; then
      [[ "${BB_GIT_MULTIPLE_MATCHES:-0}" == "1" ]] && _multiple_filter_hits=1
      # If the matched segment didn't supply its own target (no -C, no
      # leading cd-prefix in the same segment), fall back to the pending cd
      # from an earlier persist-separated segment in this chain.
      if [[ -z "$BB_GIT_TARGET" && -n "$pending_cd_target" ]]; then
        BB_GIT_TARGET="$pending_cd_target"
        BB_GIT_TARGET_SOURCE="cd"
      fi

      # Per-segment match. Decide whether this is the FIRST match (under
      # the filter, if any) or a SUBSEQUENT one.
      local _is_filter_hit=1
      if [[ -n "$verb_filter" ]]; then
        case "|$verb_filter|" in
          *"|$BB_GIT_VERB|"*) _is_filter_hit=1 ;;
          *)                  _is_filter_hit=0 ;;
        esac
      fi
      if [[ "$mutation_profile" == "codex" ]] && ! bb_git_is_codex_mutation "$BB_GIT_VERB" "$BB_GIT_ARGS"; then
        _is_filter_hit=0
      fi

      if [[ $_first_idx -lt 0 && "$_is_filter_hit" == "1" ]]; then
        # First match under filter — remember its full state.
        _first_verb="$BB_GIT_VERB"
        _first_args="$BB_GIT_ARGS"
        _first_target="$BB_GIT_TARGET"
        _first_source="$BB_GIT_TARGET_SOURCE"
        _first_tainted="$BB_GIT_TARGET_TAINTED"
        _first_idx=$_idx
      elif [[ $_first_idx -ge 0 ]]; then
        [[ "$_is_filter_hit" == "1" ]] && _multiple_filter_hits=1
        # Subsequent git invocation in the chain. If it's a mutating verb,
        # remember that so we can taint the first match (which was -C-sourced
        # and thus only covers itself) on the way out.
        local _is_mutator=0
        if [[ "$mutation_profile" == "codex" ]]; then
          bb_git_is_codex_mutation "$BB_GIT_VERB" "$BB_GIT_ARGS" && _is_mutator=1
        else
          case "|$_mut_verbs|" in
            *"|$BB_GIT_VERB|"*) _is_mutator=1 ;;
          esac
        fi
        if [[ "$_is_mutator" == "1" ]]; then
          _saw_subsequent_mutator=1
          if [[ "${BB_GIT_TARGET_TAINTED:-0}" == "1" || "${BB_GIT_TARGET:-}" != "$_first_target" ]]; then
            _subsequent_target_mismatch=1
          fi
        fi
      fi
    else
      # Non-matching segment — if it's a pure `cd <path>`, remember the path
      # for later persist-separated segments. Anything else (echo, ls, etc.)
      # leaves the pending cd untouched, which mirrors bash's actual chain
      # semantics.
      local _cd_path
      _cd_path="$(_bb_extract_cd_only_target "$seg")"
      if [[ -n "$_cd_path" ]]; then
        pending_cd_target="$_cd_path"
      fi
      local _env_effect
      _env_effect="$(_bb_segment_git_env_effect "$seg")"
      case "$_env_effect" in
        taint) pending_git_redirect_taint=1 ;;
      esac
    fi
  done

  if [[ $_first_idx -ge 0 ]]; then
    BB_GIT_VERB="$_first_verb"
    BB_GIT_ARGS="$_first_args"
    BB_GIT_TARGET="$_first_target"
    BB_GIT_TARGET_SOURCE="$_first_source"
    BB_GIT_TARGET_TAINTED="$_first_tainted"
    BB_GIT_MULTIPLE_MATCHES="$_multiple_filter_hits"
    # Every mutating invocation in an explicitly-targeted chain must resolve
    # to the same target. This catches later cd/-C retargeting to canonical
    # while allowing repeated explicit operations against the same worktree.
    if [[ "$_saw_subsequent_mutator" == "1" && "$_subsequent_target_mismatch" == "1" ]]; then
      BB_GIT_TARGET_TAINTED=1
    fi
    return 0
  fi

  # Inspect command substitutions explicitly. The outer segment starts with
  # another command (for example `echo $(git add ...)`), so the normal
  # executable-position parser cannot see the nested Git invocation.
  local _substitution_rest="$cmd"
  while [[ "$_substitution_rest" == *'$('* ]]; do
    _substitution_rest="${_substitution_rest#*'$('}"
    local _substitution="${_substitution_rest%%')'*}"
    if [[ -n "$_substitution" ]]; then
      bb_extract_git_invocation "$_substitution" "$verb_filter" "$taint_verbs" "$mutation_profile" && return 0
    fi
    [[ "$_substitution_rest" == *')'* ]] || break
    _substitution_rest="${_substitution_rest#*')'}"
  done

  # Legacy backtick substitutions execute nested commands just like $(...).
  # Inspect complete pairs so `echo \`git add file\`` cannot hide a mutation.
  local _backtick_rest="$cmd"
  while [[ "$_backtick_rest" == *'`'* ]]; do
    _backtick_rest="${_backtick_rest#*'`'}"
    [[ "$_backtick_rest" == *'`'* ]] || break
    local _backtick_substitution="${_backtick_rest%%'`'*}"
    if [[ -n "$_backtick_substitution" ]]; then
      bb_extract_git_invocation "$_backtick_substitution" "$verb_filter" "$taint_verbs" "$mutation_profile" && return 0
    fi
    _backtick_rest="${_backtick_rest#*'`'}"
  done

  BB_GIT_VERB=""
  BB_GIT_ARGS=""
  BB_GIT_TARGET=""
  BB_GIT_TARGET_SOURCE=""
  BB_GIT_TARGET_TAINTED=0
  BB_GIT_MULTIPLE_MATCHES=0
  return 1
}

# Private: if `seg` is a bare `cd <path>` (optionally with trailing tokens
# like `2>/dev/null`), echo the path; otherwise echo nothing.
_bb_extract_cd_only_target() {
  local seg="${1:-}"
  local tokens=()
  read -ra tokens <<<"$seg"
  local n=${#tokens[@]}
  [[ $n -ge 2 ]] || return 0
  local first
  first="$(_bb_strip_quotes "${tokens[0]}")"
  [[ "$first" == "cd" ]] || return 0
  _bb_strip_quotes "${tokens[1]}"
}

# Private: try one segment as a git invocation. Sets BB_GIT_VERB / BB_GIT_ARGS
# on match and returns 0; returns 1 otherwise.
_bb_segment_match_git() {
  local seg="$1" verb_filter="${2:-}" taint_verbs="${3:-}" mutation_profile="${4:-}"
  local tokens=()
  read -ra tokens <<<"$seg"
  local n=${#tokens[@]}
  [[ $n -eq 0 ]] && return 1

  # Optionally skip a leading `cd <path>` prefix. Capture the path so
  # callers can tell when the command explicitly targets a non-canonical
  # worktree. cd-prefix is "cd"-sourced (carries forward across persist
  # separators).
  local start=0
  local first
  first="$(_bb_strip_quotes "${tokens[0]}")"
  if [[ "$first" == "cd" && $n -ge 2 ]]; then
    BB_GIT_TARGET="$(_bb_strip_quotes "${tokens[1]}")"
    BB_GIT_TARGET_SOURCE="cd"
    start=2
    [[ $start -ge $n ]] && return 1
    first="$(_bb_strip_quotes "${tokens[$start]}")"
  fi

  # Skip common command-position wrappers and environment assignments. These
  # do not change which executable runs, but otherwise hide Git from the
  # parser (`env git ...`, `FOO=bar git ...`, `command /usr/bin/git ...`).
  while [[ $start -lt $n ]]; do
    first="$(_bb_strip_quotes "${tokens[$start]}")"
    first="${first#\(}"
    first="${first#\{}"
    # Reserved words may be immediately followed by a subshell opener without
    # whitespace (`then(git ...)`, `do(git ...)`). Peel the grammar prefix and
    # rescan the executable suffix as its own command-position token.
    local _grammar _peeled_grammar=0
    for _grammar in "if" "then" "elif" "else" "while" "until" "do"; do
      if [[ "$first" == "${_grammar}("* ]]; then
        tokens[start]="${first#"$_grammar"}"
        _peeled_grammar=1
        break
      fi
    done
    [[ "$_peeled_grammar" == "1" ]] && continue

    # POSIX-style function declaration with whitespace: `name () { ... }`.
    if [[ $((start + 1)) -lt $n ]]; then
      local _next_token
      _next_token="$(_bb_strip_quotes "${tokens[$((start + 1))]}")"
      if [[ "$_next_token" == "()" ]]; then
        start=$((start + 2))
        continue
      fi
    fi
    case "$first" in
      "") start=$((start + 1)); continue ;;
      [A-Za-z_]=*|[A-Za-z_][A-Za-z0-9_]*=*)
        # Git's repository/index redirect variables can make a command mutate
        # a different checkout than either the hook cwd or a literal `-C`
        # target. Preserve the match, but mark it unsafe for any explicit-
        # worktree allow path.
        case "${first%%=*}" in
          GIT_DIR|GIT_COMMON_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES)
            BB_GIT_TARGET_TAINTED=1
            ;;
        esac
        start=$((start + 1))
        continue
        ;;
      # Shell grammar may occupy command position before the command that is
      # actually executed. Skipping these words lets us see grouped and
      # conditional invocations such as `(git push ...)`, `then git push`,
      # `while git push`, and `! git push`.
      if|then|elif|else|while|until|do|!) start=$((start + 1)); continue ;;
      case)
        # Skip the case expression and its first arm label (`case x in x)`).
        # Later arms begin their own semicolon-separated segment and are
        # handled by the generic `*)` grammar case below.
        start=$((start + 1))
        while [[ $start -lt $n ]]; do
          first="$(_bb_strip_quotes "${tokens[$start]}")"
          if [[ "$first" == *')'* ]]; then
            local _case_suffix="${first#*)}"
            if [[ -n "$_case_suffix" ]]; then
              tokens[start]="$_case_suffix"
            else
              start=$((start + 1))
            fi
            break
          fi
          start=$((start + 1))
        done
        continue
        ;;
      function)
        # `function name { command; }`
        start=$((start + 2))
        continue
        ;;
      *'(){'|*'()') start=$((start + 1)); continue ;;
      *')'*)
        local _case_suffix="${first#*)}"
        if [[ -n "$_case_suffix" ]]; then
          tokens[start]="$_case_suffix"
        else
          start=$((start + 1))
        fi
        continue
        ;;
      env|/usr/bin/env)
        start=$((start + 1))
        while [[ $start -lt $n ]]; do
          first="$(_bb_strip_quotes "${tokens[$start]}")"
          case "$first" in
            -S|--split-string)
              start=$((start + 1))
              [[ $start -lt $n ]] || return 1
              local split_inner="${tokens[*]:$start}"
              split_inner="$(_bb_strip_quotes "$split_inner")"
              local split_outer_taint="${BB_GIT_TARGET_TAINTED:-0}"
              if bb_extract_git_invocation "$split_inner" "$verb_filter" "$taint_verbs" "$mutation_profile"; then
                [[ "$split_outer_taint" == "1" ]] && BB_GIT_TARGET_TAINTED=1
                return 0
              fi
              return 1
              ;;
            --split-string=*)
              local split_inner="${tokens[$start]#*=}"
              if [[ $((start + 1)) -lt $n ]]; then
                split_inner+=" ${tokens[*]:$((start + 1))}"
              fi
              split_inner="$(_bb_strip_quotes "$split_inner")"
              local split_outer_taint="${BB_GIT_TARGET_TAINTED:-0}"
              if bb_extract_git_invocation "$split_inner" "$verb_filter" "$taint_verbs" "$mutation_profile"; then
                [[ "$split_outer_taint" == "1" ]] && BB_GIT_TARGET_TAINTED=1
                return 0
              fi
              return 1
              ;;
            -u|-C|--unset|--chdir) start=$((start + 2)) ;;
            [A-Za-z_]=*|[A-Za-z_][A-Za-z0-9_]*=*)
              case "${first%%=*}" in
                GIT_DIR|GIT_COMMON_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES)
                  BB_GIT_TARGET_TAINTED=1
                  ;;
              esac
              start=$((start + 1))
              ;;
            --unset=*|--chdir=*|-*) start=$((start + 1)) ;;
            *) break ;;
          esac
        done
        continue
        ;;
      command|builtin|exec|time|/usr/bin/time|nice|/usr/bin/nice|nohup|/usr/bin/nohup)
        start=$((start + 1))
        while [[ $start -lt $n ]]; do
          first="$(_bb_strip_quotes "${tokens[$start]}")"
          case "$first" in
            -a|-n|--adjustment) start=$((start + 2)) ;;
            --adjustment=*|-*) start=$((start + 1)) ;;
            *) break ;;
          esac
        done
        continue
        ;;
    esac
    break
  done
  [[ $start -lt $n ]] || return 1
  first="$(_bb_strip_quotes "${tokens[$start]}")"
  first="${first#\(}"
  first="${first#\{}"
  first="${first//\\/}"

  # Wrapper form: bash/sh/dash/zsh -c '<inner>' → recurse on inner string.
  case "$first" in
    eval)
      local eval_i=$((start + 1))
      [[ $eval_i -lt $n ]] || return 1
      local eval_inner="${tokens[$eval_i]}"
      local eval_quote="${eval_inner:0:1}"
      if [[ "$eval_quote" == "'" || "$eval_quote" == '"' ]]; then
        while [[ "${eval_inner: -1}" != "$eval_quote" && $((eval_i + 1)) -lt $n ]]; do
          eval_i=$((eval_i + 1))
          eval_inner+=" ${tokens[$eval_i]}"
        done
      fi
      eval_inner="$(_bb_strip_quotes "$eval_inner")"
      local eval_outer_taint="${BB_GIT_TARGET_TAINTED:-0}"
      if bb_extract_git_invocation "$eval_inner" "$verb_filter" "$taint_verbs" "$mutation_profile"; then
        [[ "$eval_outer_taint" == "1" ]] && BB_GIT_TARGET_TAINTED=1
        return 0
      fi
      return 1
      ;;
    bash|sh|dash|zsh|/bin/bash|/bin/sh|/bin/zsh|/usr/bin/bash|/usr/bin/sh|/usr/bin/zsh|/usr/local/bin/bash)
      local i=$((start + 1))
      local saw_c=0
      while [[ $i -lt $n ]]; do
        local t="${tokens[$i]}"
        case "$t" in
          -c|-lc|-cl|--command) saw_c=1; i=$((i + 1)); break ;;
          -o|+o|-O|+O|--rcfile|--init-file) i=$((i + 2)) ;;
          --rcfile=*|--init-file=*) i=$((i + 1)) ;;
          -*)
            if [[ "$t" != --* && "${t#-}" == *c* ]]; then
              saw_c=1
              i=$((i + 1))
              break
            fi
            i=$((i + 1))
            ;;
          *) break ;;
        esac
      done
      [[ $saw_c -eq 1 && $i -lt $n ]] || return 1
      # `bash -c` executes exactly one command-string token; later tokens are
      # $0/$1 arguments and must not be concatenated into the command body.
      # `read -a` leaves shell quotes attached, so reconstruct only through
      # the matching closing quote when the command string contains spaces.
      local inner="${tokens[$i]}"
      local quote="${inner:0:1}"
      if [[ "$quote" == "'" || "$quote" == '"' ]]; then
        while [[ "${inner: -1}" != "$quote" && $((i + 1)) -lt $n ]]; do
          i=$((i + 1))
          inner+=" ${tokens[$i]}"
        done
      fi
      inner="$(_bb_strip_quotes "$inner")"
      local wrapper_outer_taint="${BB_GIT_TARGET_TAINTED:-0}"
      if bb_extract_git_invocation "$inner" "$verb_filter" "$taint_verbs" "$mutation_profile"; then
        [[ "$wrapper_outer_taint" == "1" ]] && BB_GIT_TARGET_TAINTED=1
        return 0
      fi
      return 1
      ;;
  esac

  # xargs executes the command that follows its options. Locate a literal Git
  # executable and recurse from there; dynamic xargs command construction is
  # intentionally outside the allow path.
  case "$first" in
    xargs|/usr/bin/xargs)
      local j=$((start + 1))
      while [[ $j -lt $n ]]; do
        local candidate
        candidate="$(_bb_strip_quotes "${tokens[$j]}")"
        case "$candidate" in
          git|*/git)
            local xargs_inner="${tokens[*]:$j}"
            local xargs_outer_taint="${BB_GIT_TARGET_TAINTED:-0}"
            if bb_extract_git_invocation "$xargs_inner" "$verb_filter" "$taint_verbs" "$mutation_profile"; then
              [[ "$xargs_outer_taint" == "1" ]] && BB_GIT_TARGET_TAINTED=1
              return 0
            fi
            return 1
            ;;
        esac
        j=$((j + 1))
      done
      return 1
      ;;
  esac

  # Normal form.
  case "$first" in git|*/git) ;; *) return 1 ;; esac

  # Walk forward, skipping git-level flags, to find the verb.
  local i=$((start + 1))
  while [[ $i -lt $n ]]; do
    local t
    t="$(_bb_strip_quotes "${tokens[$i]}")"
    case "$t" in
      # Worktree-redirecting -C: capture the path so callers can allow
      # commands targeting a non-canonical worktree. `git -C <path>` wins
      # over any earlier `cd <path>` because git applies it last. -C is
      # "C"-sourced (per-invocation only; does NOT carry to subsequent
      # chained git invocations — the helper detects that case and taints).
      -C)
        if [[ $((i + 1)) -lt $n ]]; then
          BB_GIT_TARGET="$(_bb_strip_quotes "${tokens[$((i + 1))]}")"
          BB_GIT_TARGET_SOURCE="C"
        fi
        i=$((i + 2))
        continue
        ;;
      # --git-dir / --work-tree decouple the index location from the working
      # tree. They are intentionally NOT trusted as allow-listed targets:
      # `git --git-dir=$CANONICAL/.git --work-tree=/tmp/bb-x add foo` would
      # mutate canonical's index even though --work-tree looks "safe", AND
      # `cd /tmp/wt && git --git-dir=$CANONICAL/.git --work-tree=/tmp/wt add
      # foo` inherits the cd target while still writing to canonical's index.
      # Mark the result TAINTED so the hook refuses regardless of what cd /
      # -C provided. Codex flagged both shapes 2026-05-19.
      --git-dir|--work-tree)
        BB_GIT_TARGET_TAINTED=1
        i=$((i + 2))
        continue
        ;;
      --git-dir=*|--work-tree=*)
        BB_GIT_TARGET_TAINTED=1
        i=$((i + 1))
        continue
        ;;
      # Non-redirecting flags that take a separate value argument.
      -c|--config|--exec-path|--namespace|--super-prefix|--list-cmds)
        i=$((i + 2))
        continue
        ;;
      # Equals-form non-redirecting flags (single token).
      --config=*|-c=*|--namespace=*|--super-prefix=*|--exec-path=*|--list-cmds=*)
        i=$((i + 1))
        continue
        ;;
      # Other git-level flags that take no value.
      --no-pager|--bare|--paginate|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--version|--help|-h|-P|-p)
        i=$((i + 1))
        continue
        ;;
      --*|-*)
        # Unknown flag: assume single token. Edge case where it actually
        # takes a value would misalign by one — git's documented flags are
        # enumerated above, so this is rare.
        i=$((i + 1))
        continue
        ;;
      *)
        while [[ "$t" == *')' || "$t" == *'}' ]]; do
          t="${t%?}"
        done
        BB_GIT_VERB="$t"
        # Collect post-verb tokens. Guard against empty-array expansion under
        # set -u on bash 3.2 (macOS default) — `${arr[*]}` errors when arr
        # is empty.
        local args_start=$((i + 1))
        if [[ $args_start -lt $n ]]; then
          local args_arr=("${tokens[@]:$args_start}")
          # Grouping delimiters are shell syntax, not part of the final
          # refspec/path token. `read -a` retains a closing `)` in forms such
          # as `(git push origin main)`, which previously normalized to
          # destination `main)` and bypassed the shared-branch guard.
          local _arg_i _arg
          for _arg_i in "${!args_arr[@]}"; do
            _arg="${args_arr[$_arg_i]}"
            while [[ "$_arg" == *')' || "$_arg" == *'}' ]]; do
              _arg="${_arg%?}"
            done
            args_arr[_arg_i]="$_arg"
          done
          BB_GIT_ARGS="${args_arr[*]}"
        fi
        return 0
        ;;
    esac
  done
  return 1
}

# Strip one layer of matching outer quotes (single or double) from a string.
_bb_strip_quotes() {
  local s="${1:-}"
  local n=${#s}
  if [[ $n -lt 2 ]]; then
    printf '%s' "$s"
    return
  fi
  local first="${s:0:1}" last="${s:$((n-1)):1}"
  if [[ "$first" == "'" && "$last" == "'" ]]; then
    printf '%s' "${s:1:$((n-2))}"
  elif [[ "$first" == '"' && "$last" == '"' ]]; then
    printf '%s' "${s:1:$((n-2))}"
  else
    printf '%s' "$s"
  fi
}

# 0 if gh is installed and authenticated, 1 otherwise.
bb_gh_ready() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 1
  return 0
}

# Echo existing PR URL for the given branch, or empty.
# Costs one `gh pr view` per call; callers should cache.
#
# Runs gh inside $CANONICAL so callers without a repo-relative CWD (launchd
# reapers, daily plist) still get a correct lookup.
bb_pr_url_for_branch() {
  local branch="$1"
  [[ -z "$branch" ]] && return 0
  bb_gh_ready || return 0
  (cd "$CANONICAL" 2>/dev/null && gh pr view "$branch" --json url --jq .url 2>/dev/null) || true
}

# Echo PR state ("OPEN", "CLOSED", "MERGED") for the given branch, or empty.
# Used by stale-shipping-digest.sh to skip already-shipped queue rows.
bb_pr_state_for_branch() {
  local branch="$1"
  [[ -z "$branch" ]] && return 0
  bb_gh_ready || return 0
  (cd "$CANONICAL" 2>/dev/null && gh pr view "$branch" --json state --jq .state 2>/dev/null) || true
}

# Try to open a draft PR for an auto-worktree's branch. Echoes the PR URL on
# success (existing or newly opened), empty on failure. Never blocks the
# caller — all network ops are best-effort.
#
# Usage: bb_open_draft_pr <wt_path> <branch> <title>
bb_open_draft_pr() {
  local wt_path="$1" branch="$2" title="$3"
  [[ -z "$wt_path" || -z "$branch" ]] && return 0
  bb_gh_ready || return 0

  # Already has a PR? Reuse the URL.
  local existing
  existing="$(bb_pr_url_for_branch "$branch")"
  if [[ -n "$existing" ]]; then
    echo "$existing"
    return 0
  fi

  # Push branch (creates the upstream the first time). Skip if push fails;
  # work is preserved either way via the review queue path.
  if ! git -C "$wt_path" push --quiet -u origin "$branch" 2>/dev/null; then
    bb_log "warn" "auto-pr: push failed for ${branch}; skipping PR open"
    return 0
  fi

  # Sanitize title: trim to 70 chars, default if empty.
  local pr_title="${title:-Auto-PR for ${branch}}"
  pr_title="${pr_title:0:70}"

  local pr_body
  pr_body=$(cat <<EOF
Auto-opened draft PR from worktree cleanup.

- **Branch:** \`${branch}\`
- **Worktree:** \`${wt_path}\`
- **Auto-cleanup reason:** see \`~/.claude/logs/myproject-worktree-cleanup.log\`

This PR was opened by the auto-PR-on-green path in \`scripts/claude-hooks/cleanup-worktree.sh\`. Convert to ready-for-review when CI is green, or close to abandon.
EOF
)

  # Capture stdout (URL on success) without letting failures abort the caller.
  local url=""
  url="$(cd "$wt_path" && gh pr create --draft --base main --head "$branch" \
    --title "$pr_title" --body "$pr_body" 2>/dev/null || true)"

  # gh prints the URL as the last line. Strip anything else and validate shape.
  url="$(printf '%s\n' "$url" | grep -Eo 'https://github\.com/[^[:space:]]+/pull/[0-9]+' | tail -1 || true)"
  if [[ -n "$url" ]]; then
    echo "$url"
    return 0
  fi

  # Fallback: gh may have created the PR but failed to print a URL we could
  # parse. Do one more view to be sure.
  bb_pr_url_for_branch "$branch"
}

# ---------------------------------------------------------------------------
# Resolve the ref that a NEW auto-worktree should branch FROM.
#
# v1/v2 branched from local `main`, which silently inherits however stale
# canonical happens to be — canonical is the user's IDE checkout and only moves
# when they pull. On 2026-07-25 it sat 67 commits behind origin/main, so every
# session that day started from a stale base. One of them "found" a bug that had
# already been fixed upstream, opened a PR that would have REVERTED the landed
# fix, and passed the full five-reviewer panel on the way — reviewers judge the
# diff, not the freshness of its base, so nothing downstream catches this.
#
# So: best-effort fetch, then prefer origin/main — but ONLY when local `main` is
# an ancestor of it. If they diverged, local `main` holds commits the remote does
# not and branching from origin/main would silently drop them; fall back to local
# `main` and say why. Offline / no remote falls back the same way.
#
# Never fails the caller: every git call is best-effort, and the worst case is
# the old v1 behavior (local main) plus an explanatory note.
#
# Echoes one line: "<ref>\t<note>"   (note empty when local main is already current)
# Count commits that are genuinely THIS branch's own work — reachable from the
# branch and from NEITHER local main NOR origin/main.
#
# The obvious `main..$BRANCH` is WRONG once worktrees branch from origin/main
# (2026-07-25): on a canonical that is N commits behind, every untouched session
# would score N and look like it had unpushed work. Three separate tools made that
# mistake — cleanup (pushed phantom branches + opened draft PRs), sessions-status
# (`/bb-sessions` printed a false "N ahead"), and stale-shipping-digest (nagged
# daily about phantom unshipped work). They all call this now.
#
# Echoes an integer on success. Echoes NOTHING and returns 1 when the answer is
# indeterminate (neither base ref resolves) — callers must treat that as UNKNOWN
# and fail closed, never as zero: a 0 there means "no unique work" and can lead to
# deleting a branch that holds unpublished commits.
bb_unique_commits_ahead() {
  local repo="$1" branch="$2" base
  local not_refs=()
  for base in refs/heads/main refs/remotes/origin/main; do
    if git -C "$repo" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
      not_refs+=("$base")
    fi
  done
  if [[ "${#not_refs[@]}" -eq 0 ]]; then
    return 1
  fi
  local count
  count="$(git -C "$repo" rev-list --count "$branch" --not "${not_refs[@]}" 2>/dev/null)" || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$count"
}

bb_resolve_worktree_base() {
  local repo="${1:-$CANONICAL}"
  local ref="main" note="" behind="" t runner="" fetch_ok=0
  local have_local_main=0 have_remote_main=0 stale=""

  git -C "$repo" rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1 && have_local_main=1

  # Non-interactive, hard-bounded fetch. Two separate hazards:
  #   * A credential prompt. SessionStart HAS a controlling terminal, so an
  #     expired PAT or empty keychain makes git open /dev/tty and wait FOREVER,
  #     with output swallowed — the user just sees Claude Code hang. The
  #     GIT_TERMINAL_PROMPT/ASKPASS/BatchMode trio makes git fail instead of ask.
  #   * A dead network. http.lowSpeed* bounds only the TRANSFER phase; DNS and
  #     TCP/TLS connect are governed by libcurl defaults (~300s). So we also need
  #     a real wall-clock bound: timeout(1) if present, else perl's alarm (perl
  #     ships with macOS; timeout/gtimeout do NOT unless coreutils was brewed).
  # NOTE: hardcoding remote "origin" is deliberate — this repo also has `vps` and
  # `vps-staging` remotes (deploy targets), and auto-detecting "the first remote"
  # could branch sessions off a deploy remote. origin is the GitHub source of truth.
  # Array, not a string: a future value containing a space would otherwise be
  # word-split into garbage env vars and the prompt suppression would silently
  # stop applying. Explicit refspec so the tracking ref is updated regardless of
  # how remote.origin.fetch happens to be configured.
  local fetch_env=(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true SSH_ASKPASS=/usr/bin/true
                   "GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=10")
  local refspec='+refs/heads/main:refs/remotes/origin/main'
  for t in timeout gtimeout; do
    if command -v "$t" >/dev/null 2>&1; then runner="$t"; break; fi
  done
  if [[ -n "$runner" ]]; then
    env "${fetch_env[@]}" \
      "$runner" 20 git -C "$repo" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
      fetch origin "$refspec" --quiet >/dev/null 2>&1 && fetch_ok=1
  elif command -v perl >/dev/null 2>&1; then
    env "${fetch_env[@]}" \
      perl -e 'alarm shift; exec @ARGV' 20 git -C "$repo" \
      -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
      fetch origin "$refspec" --quiet >/dev/null 2>&1 && fetch_ok=1
  else
    env "${fetch_env[@]}" \
      git -C "$repo" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
      fetch origin "$refspec" --quiet >/dev/null 2>&1 && fetch_ok=1
  fi

  git -C "$repo" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1 && have_remote_main=1

  # A cached origin/main after a FAILED fetch is not evidence of freshness — say so
  # rather than printing a confident "Base: origin/main" (that false confidence is
  # exactly the 67-commits-behind bug wearing a fresher-looking label).
  (( fetch_ok )) || stale=" NOTE: the fetch did not succeed, so origin/main is whatever was last cached and may itself be behind."

  if (( have_remote_main == 0 )); then
    ref="main"
    note="branched from LOCAL main: origin/main could not be resolved (offline, or no 'origin' remote). This base may be STALE — run: git -C \"${repo}\" fetch origin && git -C \"${repo}\" rev-list --count main..origin/main"
  elif (( have_local_main == 0 )); then
    # No local `main` at all (deleted, or a repo whose default branch differs).
    # Passing the bare name `main` here would trigger git's unique-remote DWIM:
    # it creates a branch literally NAMED main tracking origin/main and silently
    # DISCARDS `-b <branch>` (reproduced on git 2.50.1). The session would then sit
    # on `main` with an upstream of origin/main — one bare `git push` from writing
    # to the shared branch, while the registry recorded a branch that doesn't exist.
    # Fully-qualified refs/remotes/... can never DWIM.
    ref="refs/remotes/origin/main"
    note="canonical has no local 'main' branch — branched from origin/main instead.${stale}"
  elif git -C "$repo" merge-base --is-ancestor refs/heads/main refs/remotes/origin/main >/dev/null 2>&1; then
    ref="refs/remotes/origin/main"
    behind="$(git -C "$repo" rev-list --count refs/heads/main..refs/remotes/origin/main 2>/dev/null || echo 0)"
    if [[ -n "$behind" && "$behind" != "0" ]]; then
      note="canonical's local main is ${behind} commit(s) behind origin/main — this worktree was branched from the REMOTE so it starts current.${stale}"
    elif (( fetch_ok == 0 )); then
      note="branched from origin/main, but the fetch did not succeed, so that ref is whatever was last cached — this base may be STALE. Check: git -C \"${repo}\" fetch origin && git -C \"${repo}\" rev-list --count main..origin/main"
    fi
  else
    ref="main"
    note="branched from LOCAL main: it holds commits that are not on origin/main, so branching from the remote would have dropped them. Inspect with: git -C \"${repo}\" log --oneline origin/main..main"
  fi

  printf '%s\t%s\n' "$ref" "$note"
}
