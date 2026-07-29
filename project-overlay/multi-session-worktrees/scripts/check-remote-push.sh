#!/usr/bin/env bash
# PreToolUse hook on Bash for `git push`. Layered on top of the worktree
# isolation: worktrees fix the local .git/index race; this hook addresses
# the remote-side race where two sessions independently push to origin/main
# (or vps/main) and one ends up overwriting the other's work.
#
# Three failure modes from MEMORY.md:
#   1. Remote moved while we worked. `git push` rejects, model panics, runs
#      `git push --force` and drops a deployed commit.
#   2. Two sessions push to vps/main back-to-back; the second wipes the first
#      from PM2 because the build script exits 0 on identical content.
#   3. A session on wt/auto-* merges main locally (or rebases), then pushes
#      main directly. Any commits the session inherited from main —
#      including unreviewed work from a concurrent session — ride along.
#      One push deploys multiple sessions' worth of unrelated code.
#
# Behavior:
#   - Force pushes (`--force`, `--force-with-lease`) to main / vps / vps-staging
#     are blocked unconditionally, with ONE owner-approved exception
#     (2026-07-14): `--force-with-lease` to vps-staging main when the pushed
#     sha is merged history on origin/main AND staging's current tip is
#     backed up on some origin ref (safe resync of a parked staging).
#     Operator override for everything else stays "run it yourself".
#   - DEPLOY-BY-REF (owner-approved 2026-07-14): pushing <src>:main to the
#     vps / vps-staging deploy remotes is allowed from any session when
#     <src> is an ancestor of origin/main per GitHub — merged history
#     sweeps nothing unreviewed.
#   - Direct pushes to main / master / staging:main from an auto-worktree
#     session are blocked. "Auto-worktree session" = current branch matches
#     `wt/auto-*` OR PWD is inside `/tmp/wt-auto-*` (the second signal covers
#     detached-HEAD state, where `git rev-parse --abbrev-ref HEAD` returns
#     the literal string "HEAD" and the branch check would otherwise miss).
#   - `--mirror` / `--all` from auto-worktree sessions are blocked too:
#     those push every local ref (including main) regardless of refspec.
#   - Normal pushes (canonical user on main, manual `wt/<slug>` worktrees):
#     fetch the target ref via `git ls-remote` and check local HEAD's
#     relationship to it. If behind, block with rebase guidance.
#
# Falls through (exit 0) for:
#   - Non-push git commands
#   - Pushes from non-auto contexts where DST_BRANCH isn't a shared deploy ref
#   - Pushes from canonical or manual /wt worktrees where local HEAD is at or
#     ahead of remote (the normal case)
#
# Parsing portability note:
#   This used to call `sed -E 's/.*\bgit[[:space:]]+push[[:space:]]*//'`, but
#   BSD sed on macOS does NOT honor GNU `\b` word boundaries. The substitution
#   matched nothing on Darwin and downstream parsing yielded REMOTE=git,
#   REF_SPEC=push — silently disabling every guard below the case statement.
#   Tokenization is now pure bash; no sed, no portability gotchas.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

PAYLOAD="$(cat)"
COMMAND="$(echo "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")"
HOOK_HOST="${BB_HOOK_HOST:-claude}"
SESSION_ID="$(echo "$PAYLOAD" | jq -r '.session_id // .conversation_id // .thread_id // "unknown"' 2>/dev/null || echo "unknown")"
HOOK_DISPLAY="Claude"
[[ "$HOOK_HOST" == "codex" ]] && HOOK_DISPLAY="Codex"

# Detect git push invocations via the shared tokenizer in _lib.sh. The
# tokenizer handles:
#   - bare:           `git push ...`
#   - cd-prefix:      `cd /path && git push ...`
#   - flag-before-verb: `git -C /path push ...`, `git --git-dir=X push ...`
#   - sh/bash -c wrapper: `bash -c "git push ..."`
#   - shell-separated chains and multi-line commands
# It avoids false-positives on phrase-mentions of `git push` inside argument
# values (e.g. `gh pr create --body "...push to main..."`).
#
# The "push" verb filter forces the helper to scan every segment for a real
# `git push` rather than short-circuiting on an earlier non-push git command
# (e.g. `git status && git push origin main`).
if ! bb_extract_git_invocation "$COMMAND" "push"; then
  if [[ "$COMMAND" == *"$'"* && "$COMMAND" == *"push"* ]]; then
    printf '%s\n' 'Refusing an ANSI-C-quoted push wrapper that cannot be statically validated.' >&2
    exit 2
  fi
  if bb_command_has_unparsed_git_risk "$COMMAND" "push"; then
    printf '%s\n' 'Refusing a git push command whose shell grammar could not be statically validated.' >&2
    exit 2
  fi
  exit 0
fi

# A chained command can contain destinations with different safety profiles.
# Refuse multiple parsed Git pushes rather than counting the ordinary English
# word "push" elsewhere in the command.
if [[ "${BB_GIT_MULTIPLE_MATCHES:-0}" == "1" ]]; then
  printf '%s\n' 'Refusing a command containing multiple git push invocations; run and validate each push separately.' >&2
  exit 2
fi

# Remote and refspec values must be literal. Shell variables, command
# substitutions, backticks, and brace expansion can resolve to `main` only
# after the hook has run, making static destination validation unsound.
case "$BB_GIT_ARGS" in
  *'$'*|*'`'*|*'{'*|*'}'*|*"'"*|*'"'*)
    printf '%s\n' 'Refusing git push with dynamic shell syntax in its arguments; use a literal remote and refspec.' >&2
    exit 2
    ;;
esac

# Repository/index redirects make the effective push context ambiguous. A
# literal cd/-C target is safe to inspect; --git-dir/--work-tree or Git's
# redirecting environment variables are not, and dynamic targets cannot be
# resolved before execution. Refuse those forms instead of inspecting the
# hook process's repository by mistake.
if [[ "${BB_GIT_TARGET_TAINTED:-0}" == "1" ]]; then
  printf '%s\n' 'Refusing git push with a tainted Git repository/index target; use a literal cd or git -C path.' >&2
  exit 2
fi

GIT_CONTEXT=()
if [[ -n "${BB_GIT_TARGET:-}" ]]; then
  case "$BB_GIT_TARGET" in
    *'$'*|*'`'*|*'{'*|*'}'*|*"'"*|*'"'*)
      printf '%s\n' 'Refusing git push with a dynamic repository target; use a literal cd or git -C path.' >&2
      exit 2
      ;;
  esac
  GIT_CONTEXT=(-C "$BB_GIT_TARGET")
fi

if ! git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" rev-parse --show-toplevel >/dev/null 2>&1; then
  printf '%s\n' 'Refusing git push because the effective repository could not be inspected.' >&2
  exit 2
fi

# Record which host/session evaluated a real push invocation. Do not persist
# the raw command here: a user-authored push URL can contain credentials.
jq -n -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg hook_host "$HOOK_HOST" \
  --arg session_id "$SESSION_ID" \
  --arg cwd "$PWD" \
  --argjson pid "$$" \
  '{ts: $ts, pid: $pid, hook_host: $hook_host, session_id: $session_id, cwd: $cwd, action: "push-evaluated"}' \
  >> "${LOG_DIR}/myproject-remote-push.jsonl" 2>/dev/null || true

# Re-tokenize the post-push args (helper returns them space-joined).
ALL_TOKENS=()
TOKENS_AFTER_PUSH=()
_raw_tokens=()
read -ra _raw_tokens <<<"$BB_GIT_ARGS"
for tok in "${_raw_tokens[@]+"${_raw_tokens[@]}"}"; do
  TOKENS_AFTER_PUSH+=("$(_bb_strip_quotes "$tok")")
done

# A dry-run push does not update the remote. Only inspect options before `--`;
# later tokens are refspecs, and an explicit negation fails closed.
_push_dry_run="false"
for tok in "${TOKENS_AFTER_PUSH[@]+"${TOKENS_AFTER_PUSH[@]}"}"; do
  case "$tok" in
    --) break ;;
    --no-dry*) _push_dry_run="false"; break ;;
    --dry-run|-n) _push_dry_run="true" ;;
  esac
done
[[ "$_push_dry_run" == "true" ]] && exit 0

# Hard-block force-push to deploy / shared branches. Inspect the parsed args
# (not raw COMMAND) so phrase-mentions of `--force` inside a long quoted
# argument can't false-fire the block.
# Match the equals-form `--force-with-lease=<value>` too — the prior regex
# caught it via substring match, but the exact-token version above would not.
HAS_FORCE="false"
HAS_BARE_FORCE="false"
HAS_DELETE="false"
for tok in "${TOKENS_AFTER_PUSH[@]+"${TOKENS_AFTER_PUSH[@]}"}"; do
  case "$tok" in
    --force|-f) HAS_FORCE="true"; HAS_BARE_FORCE="true" ;;
    --force-with-lease|--force-with-lease=*) HAS_FORCE="true" ;;
    --delete|--del*|-d) HAS_DELETE="true" ;;
    -?*)
      _short_flags="${tok#-}"
      [[ "$_short_flags" != -* && "$_short_flags" == *f* ]] && { HAS_FORCE="true"; HAS_BARE_FORCE="true"; }
      [[ "$_short_flags" != -* && "$_short_flags" == *d* ]] && HAS_DELETE="true"
      ;;
  esac
done

# Shared helper for the two owner-approved deploy carve-outs (2026-07-14).
# Proves a sha is MERGED history on origin/main, then checks ancestry.
#
# Uses the LOCAL refs/remotes/origin/main tracking ref, NOT an authenticated
# `ls-remote origin` (2026-07-15 fix): the hook runs in a non-interactive
# subprocess that often cannot authenticate to a private HTTPS origin
# (no keychain/credential-helper access), so the ls-remote gate silently
# failed and blocked every legitimate deploy on its first real use. The local
# tracking ref needs no network or credentials and is kept fresh by the
# session's own `git fetch` before it deploys (worktrees share refs/remotes
# with canonical). A best-effort fetch freshens it further but is never
# required. ls-remote remains a fallback only when no local ref exists.
#
# Safety: a stale tracking ref can only REJECT a valid deploy (fail-closed) or
# approve a sha that WAS merged as of the last fetch — never approve unmerged
# history. Any failure returns non-zero so callers fall through to the block.
bb_sha_is_merged_on_origin_main() {
  local sha="$1" origin_main
  git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" fetch --quiet origin main >/dev/null 2>&1 || true
  origin_main="$(git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" rev-parse --verify --quiet refs/remotes/origin/main 2>/dev/null)"
  if [[ -z "$origin_main" ]]; then
    # No local tracking ref — fall back to an authenticated ls-remote.
    origin_main="$(git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" ls-remote origin refs/heads/main 2>/dev/null | awk '{print $1}' | head -1)"
    [[ -n "$origin_main" ]] || return 1
    git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" cat-file -e "${origin_main}^{commit}" 2>/dev/null || return 1
  fi
  git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" merge-base --is-ancestor "$sha" "$origin_main" 2>/dev/null
}

if [[ "$HAS_FORCE" == "true" ]]; then
  # Walk the positional args to see if the destination is a shared branch.
  _fp_positional=()
  for tok in "${TOKENS_AFTER_PUSH[@]+"${TOKENS_AFTER_PUSH[@]}"}"; do
    case "$tok" in
      --*|-*) ;;
      "") ;;
      *) _fp_positional+=("$tok") ;;
    esac
  done
  _fp_remote="${_fp_positional[0]:-origin}"
  _fp_dst="${_fp_positional[1]:-}"
  _fp_dst="${_fp_dst##*:}"
  _fp_dst="${_fp_dst#+}"
  _fp_dst="${_fp_dst#refs/heads/}"
  # Owner-approved carve-out (2026-07-14): staging RESYNC.
  # vps-staging can be left pointing at squash-orphaned test commits by a
  # dead session; clearing that requires force. Allow --force-with-lease
  # (NEVER bare --force/-f) to vps-staging main ONLY when BOTH:
  #   (a) the pushed source is merged history on origin/main, and
  #   (b) staging's current tip is reachable from some origin ref (every
  #       commit being discarded is backed up on GitHub).
  # Prod (vps) and origin force-pushes remain unconditionally blocked.
  _fp_spec_full="${_fp_positional[1]:-}"
  # Codex P1: exactly ONE refspec — a second refspec (e.g. <x>:master) would
  # ride the exit 0 past the multi-refspec shared-branch guard below.
  if [[ ${#_fp_positional[@]} -eq 2 && \
        "$_fp_remote" == "vps-staging" && "$_fp_dst" == "main" && \
        "$HAS_BARE_FORCE" == "false" && "$_fp_spec_full" == *:* && \
        "$_fp_spec_full" != +* ]]; then
    _sr_src="${_fp_spec_full%%:*}"
    _sr_sha="$(git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" rev-parse "${_sr_src}^{commit}" 2>/dev/null || echo "")"
    if [[ -n "$_sr_sha" ]] && bb_sha_is_merged_on_origin_main "$_sr_sha"; then
      _sr_tip="$(git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" ls-remote vps-staging refs/heads/main 2>/dev/null | awk '{print $1}' | head -1)"
      _sr_backed="false"
      if [[ -z "$_sr_tip" ]]; then
        _sr_backed="true"
      else
        git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" cat-file -e "${_sr_tip}^{commit}" 2>/dev/null || \
          git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" fetch --quiet vps-staging main >/dev/null 2>&1 || true
        if git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" cat-file -e "${_sr_tip}^{commit}" 2>/dev/null; then
          # Codex P1: backup proof must come from LIVE origin refs (ls-remote),
          # never from local refs/remotes/origin tracking refs — a branch
          # deleted on GitHub leaves a stale tracking ref behind (fetch does
          # not prune) that would vouch for a commit no longer backed up.
          # ls-remote failure -> no live refs -> _sr_backed stays false
          # (fail closed). Objects for live tips are fetched with --prune;
          # tips whose objects still can't be resolved are skipped (a sha we
          # cannot inspect proves nothing).
          _sr_live_refs="$(git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" ls-remote --heads origin 2>/dev/null | awk '{print $1}')"
          if [[ -n "$_sr_live_refs" ]]; then
            git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" fetch --quiet --prune origin >/dev/null 2>&1 || true
            while IFS= read -r _sr_ref; do
              [[ -n "$_sr_ref" ]] || continue
              git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" cat-file -e "${_sr_ref}^{commit}" 2>/dev/null || continue
              if git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" merge-base --is-ancestor "$_sr_tip" "$_sr_ref" 2>/dev/null; then
                _sr_backed="true"
                break
              fi
            done <<<"$_sr_live_refs"
          fi
        fi
      fi
      if [[ "$_sr_backed" == "true" ]]; then
        jq -n -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg hook_host "$HOOK_HOST" \
          --arg session_id "$SESSION_ID" --arg sha "$_sr_sha" --arg tip "${_sr_tip:-none}" \
          '{ts:$ts, hook_host:$hook_host, session_id:$session_id, sha:$sha, replaced_tip:$tip, action:"staging-resync-allowed"}' \
          >> "${LOG_DIR}/myproject-remote-push.jsonl" 2>/dev/null || true
        exit 0
      fi
    fi
  fi

  case "$_fp_remote" in
    origin|vps|vps-staging|vps-production)
      case "$_fp_dst" in
        main|master|staging:main)
          cat >&2 <<EOF
Refusing force-push to a shared branch.

Force-push to \`main\` / \`vps\` / \`vps-staging\` from a ${HOOK_DISPLAY} session is blocked because parallel sessions can drop each other's deployed commits (see MEMORY.md "Remote force-push from parallel session can drop already-deployed commits").

If you genuinely need to force-push: run the command yourself outside the ${HOOK_DISPLAY} session, after \`git fetch\` and confirming the remote SHA is what you expect.
EOF
          exit 2
          ;;
      esac
      ;;
  esac
fi

# Split positionals from flags. Also surface --mirror / --all separately:
# those push every local ref regardless of the positional refspec, so the
# usual DST_BRANCH-based filtering doesn't apply to them.
# Guard the array expansion with `[@]+...` — bare `git push` (upstream
# tracking, no args) leaves TOKENS_AFTER_PUSH empty, and macOS bash 3.2
# under set -u crashes with "unbound variable" on `"${arr[@]}"` for empty
# arrays. The other two loops above already use this pattern.
HAS_MIRROR_OR_ALL="false"
HAS_COMPLEX_OPTION="false"
HAS_UNKNOWN_LONG_OPTION="false"
POSITIONAL=()
for tok in "${TOKENS_AFTER_PUSH[@]+"${TOKENS_AFTER_PUSH[@]}"}"; do
  case "$tok" in
    --mirror|--all) HAS_MIRROR_OR_ALL="true" ;;
    --delete|--del*|-d) HAS_DELETE="true" ;;
    --receive-pack|--exec|--repo|--push-option|-o) HAS_COMPLEX_OPTION="true" ;;
    --receive-pack=*|--exec=*|--repo=*|--push-option=*) HAS_COMPLEX_OPTION="true" ;;
    -o?*) HAS_COMPLEX_OPTION="true" ;;
    --force|--force-with-lease|--force-with-lease=*|--dry-run|--no-dry-run|\
    --atomic|--no-atomic|--tags|--follow-tags|--signed|--signed=*|--no-signed|\
    --set-upstream|--porcelain|--quiet|--verbose|--progress|--thin|--no-thin|\
    --verify|--no-verify|--ipv4|--ipv6|--recurse-submodules=*|\
    --no-recurse-submodules)
      ;;
    --*) HAS_UNKNOWN_LONG_OPTION="true" ;;
    -*) ;;  # short flags are classified above; positionally they are skipped
    "") ;;
    *) POSITIONAL+=("$tok") ;;
  esac
done

if [[ "$HAS_COMPLEX_OPTION" == "true" ]]; then
  printf '%s\n' 'Refusing git push with an option that changes destination parsing; run it manually after review.' >&2
  exit 2
fi

if [[ "$HAS_UNKNOWN_LONG_OPTION" == "true" ]]; then
  printf '%s\n' 'Refusing git push with an abbreviated or unknown long option; use the full supported spelling.' >&2
  exit 2
fi

if [[ "$HAS_MIRROR_OR_ALL" == "true" ]]; then
  printf '%s\n' 'Refusing git push --mirror/--all from an agent session; use an explicit branch refspec.' >&2
  exit 2
fi

REMOTE="${POSITIONAL[0]:-origin}"
case "$REMOTE" in
  origin|vps|vps-staging|vps-production) REMOTE_DISPLAY="$REMOTE" ;;
  *) REMOTE_DISPLAY="<remote>" ;;
esac

# Collect every refspec. Multi-refspec pushes (e.g. `git push origin foo main`)
# push EACH refspec separately; inspecting only the first lets a later refspec
# slip past the shared-branch guard.
REFSPECS=()
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then
  for ((i=1; i<${#POSITIONAL[@]}; i++)); do
    REFSPECS+=("${POSITIONAL[$i]}")
  done
else
  IMPLICIT="$(git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  [[ -n "$IMPLICIT" ]] && REFSPECS+=("$IMPLICIT")
fi

for spec in "${REFSPECS[@]+"${REFSPECS[@]}"}"; do
  _literal_spec="$(_bb_strip_quotes "$spec")"
  if [[ "$_literal_spec" == "HEAD" || "$_literal_spec" == "@" || "$_literal_spec" == "+HEAD" || "$_literal_spec" == "+@" ]]; then
    printf '%s\n' 'Refusing destination-inferred HEAD/@ push; use an explicit source:destination refspec.' >&2
    exit 2
  fi
  if [[ "$_literal_spec" == ":" || "$_literal_spec" == "+:" ]]; then
    printf '%s\n' 'Refusing matching-branch :/+: push; use one explicit source:destination refspec.' >&2
    exit 2
  fi
  if [[ "$spec" == *'*'* || "$spec" == *'?'* || "$spec" == *'['* ]]; then
    printf '%s\n' 'Refusing wildcard git push refspec from an agent session; use one explicit branch.' >&2
    exit 2
  fi
done

# Normalize a refspec to its destination branch: take whatever's after the
# colon (if any), then strip leading + (force-refspec prefix) and refs/heads/
# (long form). Without normalization, `refs/heads/main` and `+main` slip past
# the shared-branch check below.
normalize_dst() {
  local r="$1"
  r="${r##*:}"
  r="${r#+}"
  r="${r#refs/heads/}"
  r="${r#heads/}"
  printf '%s' "$r"
}

# Find ANY refspec that targets a shared deploy branch (multi-refspec safe).
SHARED_TARGET=""
SHARED_REFSPEC=""
for spec in "${REFSPECS[@]+"${REFSPECS[@]}"}"; do
  dst="$(normalize_dst "$spec")"
  case "$dst" in
    main|master|staging:main)
      SHARED_TARGET="$dst"
      SHARED_REFSPEC="$spec"
      break
      ;;
  esac
done

# REF_SPEC / DST_BRANCH are used in error messages + the ls-remote check below.
# Prefer the shared-target refspec so errors name the actual offender;
# otherwise fall back to the first refspec.
if [[ -n "$SHARED_TARGET" ]]; then
  REF_SPEC="$SHARED_REFSPEC"
  DST_BRANCH="$SHARED_TARGET"
else
  REF_SPEC="${REFSPECS[0]:-}"
  DST_BRANCH="$(normalize_dst "$REF_SPEC")"
fi

# Detect auto-worktree session via two independent signals — either suffices:
#   - Current branch matches `wt/auto-*`  (the common case)
#   - PWD is inside a wt-auto-* directory (new ${WORKTREE_BASE}/wt-auto-* OR
#     legacy /tmp/wt-auto-* — covers detached HEAD, where
#     `git rev-parse --abbrev-ref HEAD` returns the literal "HEAD" and the
#     branch check fails open)
CURRENT_BRANCH="$(git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
IS_AUTO_WT="false"
case "$CURRENT_BRANCH" in
  wt/auto-*) IS_AUTO_WT="true" ;;
esac
if bb_is_auto_worktree_path "$PWD"; then
  IS_AUTO_WT="true"
fi
# Third signal: the COMMAND itself references a wt-auto-* path (e.g.
# `cd ${WORKTREE_BASE}/wt-auto-X && git push origin main`). The hook fires
# BEFORE that `cd` has executed, so $PWD and `git rev-parse` still reflect
# the pre-cd state — typically canonical. Without this signal, an inline cd
# would let the push bypass the auto-wt guard entirely.
#
# Build the regex dynamically from $WORKTREE_BASE so non-default
# BB_WORKTREE_BASE overrides are still covered (Codex round-1 found a
# bypass when WORKTREE_BASE didn't contain the literal `.agent-worktrees`
# substring). The hardcoded /tmp/ and /.agent-worktrees/ prefixes stay
# as belt-and-suspenders for default installs + the legacy /tmp/ path.
# Escape every regex metachar that could appear in an arbitrary $HOME
# (paren, brace, bar are rare but possible in macOS app paths).
WT_BASE_RE_ESC="$(printf '%s' "${WORKTREE_BASE:-}" | sed 's:[][\\.*^$/(){}+?|]:\\&:g')"
WT_PATTERNS='(/tmp/|/\.agent-worktrees/'
if [[ -n "$WT_BASE_RE_ESC" ]]; then
  WT_PATTERNS+="|${WT_BASE_RE_ESC}/"
fi
WT_PATTERNS+=')wt-auto-'
if echo "$COMMAND" | grep -qE "$WT_PATTERNS"; then
  IS_AUTO_WT="true"
fi

# Codex always lands shared branches through a PR. Unlike Claude's historical
# auto-worktree policy, this applies to every Codex session/worktree; pushes
# to the current feature branch remain allowed below.
if [[ "$HOOK_HOST" == "codex" ]]; then
  IS_AUTO_WT="true"
fi

# Block bare pushes from EVERY agent session (not only auto-worktree ones —
# the guard below has no IS_AUTO_WT condition on purpose). When the push has no
# explicit positional refspec, the actual destination depends on git's
# `push.default` config plus `branch.<name>.merge` upstream tracking —
# neither of which the hook can reliably resolve from a different working
# tree (PWD doesn't follow inline cd; the hook fires before chained cd
# runs). Rather than risk an implicit push silently landing on `main`
# (e.g. if a user once set upstream to origin/main), auto-wt sessions
# must always specify destination explicitly. This is also consistent
# with the PR-required spirit of this hook — auto-wt work should land
# via `git push origin wt/auto-X` followed by `gh pr create`, never as
# an upstream-driven bare push.
if [[ ${#POSITIONAL[@]} -lt 2 ]]; then
  cat >&2 <<EOF
Refusing bare \`git push\` from an agent session.

Current branch: ${CURRENT_BRANCH:-(detached HEAD)}
Working dir:    ${PWD}

Without an explicit destination, git resolves the push target from upstream tracking (\`branch.${CURRENT_BRANCH:-X}.merge\`) plus \`push.default\`. The hook cannot safely infer that target for every worktree and inline \`git -C\`/\`cd\` form, so agent sessions must specify one remote and one refspec.

  git push -u origin ${CURRENT_BRANCH:-<branch>}
  gh pr create --base main --head ${CURRENT_BRANCH:-<branch>} --fill

If you genuinely need a bare push (e.g. upstream is set to the feature branch and you're pushing follow-up commits), run it yourself in a terminal outside ${HOOK_DISPLAY}.
EOF
  exit 2
fi

# Hard-block --mirror / --all from auto-worktree sessions: these flags push
# every local branch (including main) to the remote regardless of any
# positional refspec, so DST_BRANCH-based filtering doesn't apply.
if [[ "$HAS_MIRROR_OR_ALL" == "true" && "$IS_AUTO_WT" == "true" ]]; then
  cat >&2 <<EOF
Refusing \`git push ${REMOTE_DISPLAY}\` with --mirror/--all from an auto-worktree session.

These flags push every local branch (including \`main\`) to the remote, bypassing per-branch isolation. Open a PR for the specific branch instead:

  git push -u origin ${CURRENT_BRANCH:-<your-branch>}
  gh pr create --base main --head ${CURRENT_BRANCH:-<your-branch>} --fill

If you genuinely need a multi-branch push (e.g. migrating the repo to a new
host), run it yourself in a terminal outside ${HOOK_DISPLAY}.
EOF
  exit 2
fi

# If no refspec in this push targets a shared deploy branch, allow.
# (The multi-refspec scan above already inspected every refspec.)
[[ -n "$SHARED_TARGET" ]] || exit 0

# Deleting or force-updating a shared branch is never safe for an agent
# session. A leading `+` on the refspec is force even without `--force`.
if [[ "$HAS_DELETE" == "true" || "$HAS_FORCE" == "true" || "$SHARED_REFSPEC" == +* || "$SHARED_REFSPEC" == :* ]]; then
  printf '%s\n' 'Refusing force/delete update to a shared branch from an agent session.' >&2
  exit 2
fi

# Owner-approved carve-out (2026-07-14): DEPLOY-BY-REF.
# A push of GitHub-merged history to a DEPLOY remote sweeps nothing — the
# content already went through a PR. Allowed from ANY session:
#   git push vps|vps-staging <src>:main
# iff <src> is an ancestor of origin/main as GitHub reports it right now.
# Force/delete/+ forms never reach this point (blocked above); non-fast-
# forward pushes are rejected by git itself (no force available here).
# origin is deliberately excluded: origin/main changes land via PRs only.
if [[ "$REMOTE" == "vps" || "$REMOTE" == "vps-staging" ]] && \
   [[ ${#REFSPECS[@]} -eq 1 && "$SHARED_REFSPEC" == *:* && "$DST_BRANCH" == "main" ]]; then
  _dbr_src="${SHARED_REFSPEC%%:*}"
  _dbr_sha="$(git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" rev-parse "${_dbr_src}^{commit}" 2>/dev/null || echo "")"
  if [[ -n "$_dbr_sha" ]] && bb_sha_is_merged_on_origin_main "$_dbr_sha"; then
    jq -n -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg hook_host "$HOOK_HOST" \
      --arg session_id "$SESSION_ID" --arg remote "$REMOTE" --arg sha "$_dbr_sha" \
      '{ts:$ts, hook_host:$hook_host, session_id:$session_id, remote:$remote, sha:$sha, action:"deploy-by-ref-allowed"}' \
      >> "${LOG_DIR}/myproject-remote-push.jsonl" 2>/dev/null || true
    exit 0
  fi
fi

# Auto-worktree sessions must open a PR — never push directly to shared
# branches. (See top-of-file failure mode #3 for the threat model.)
if [[ "$IS_AUTO_WT" == "true" ]]; then
  cat >&2 <<EOF
Refusing \`git push ${REMOTE_DISPLAY} ${DST_BRANCH}\`: auto-worktree sessions may not push directly to shared branches.

Current branch: ${CURRENT_BRANCH:-(detached HEAD)}
Working dir:    ${PWD}
Target:         ${REMOTE_DISPLAY}/${DST_BRANCH}

Auto sessions (\`wt/auto-*\`, or any push from inside \`/tmp/wt-auto-*\`) work in isolated worktrees specifically so parallel sessions don't roll each other's work into a single deploy. Pushing this branch straight to \`${DST_BRANCH}\` defeats that: any commits this branch picked up from \`${DST_BRANCH}\` (via merge or rebase from another session's work) ride along, mixing unreviewed work from other sessions into one push.

To land this work, open a PR — it pushes only this branch and merges via GitHub:
  git push -u origin ${CURRENT_BRANCH:-<branch>}
  gh pr create --base ${DST_BRANCH} --head ${CURRENT_BRANCH:-<branch>} --fill

After the PR merges, the cleanup hook will delete this worktree automatically on session end.

If you genuinely need to bypass this (e.g., emergency rollback), run the push yourself in a terminal outside ${HOOK_DISPLAY}.
EOF
  exit 2
fi

# Fetch remote SHA via ls-remote (no working-tree side effects). A missing
# branch is safe; an unreachable or undefined remote is not statically
# verifiable and therefore fails closed.
if ! REMOTE_OUTPUT="$(git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" ls-remote "$REMOTE" "refs/heads/${DST_BRANCH}" 2>/dev/null)"; then
  printf '%s\n' 'Refusing git push because the target remote could not be inspected.' >&2
  exit 2
fi
REMOTE_SHA="$(printf '%s\n' "$REMOTE_OUTPUT" | awk '{print $1}' | head -1)"
if [[ -z "$REMOTE_SHA" ]]; then
  # Branch does not exist on a reachable remote yet.
  exit 0
fi

# Validate the actual source ref from the explicit refspec, in the repository
# targeted by inline `cd`/`git -C` when present. Checking the hook process's
# cwd HEAD can approve a different commit than the one being pushed.
SOURCE_REF="${SHARED_REFSPEC%%:*}"
[[ "$SHARED_REFSPEC" == *:* ]] || SOURCE_REF="$SHARED_REFSPEC"
SOURCE_REF="${SOURCE_REF#+}"
[[ -n "$SOURCE_REF" ]] || {
  printf '%s\n' 'Refusing deletion of a shared branch from an agent session.' >&2
  exit 2
}
LOCAL_SHA="$(git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" rev-parse "${SOURCE_REF}^{commit}" 2>/dev/null || echo "")"
if [[ -z "$LOCAL_SHA" ]]; then
  printf '%s\n' 'Refusing git push because the explicit source ref could not be resolved in the target repository.' >&2
  exit 2
fi

# If remote SHA is in our history, we're at-or-ahead — safe to push.
if git "${GIT_CONTEXT[@]+"${GIT_CONTEXT[@]}"}" merge-base --is-ancestor "$REMOTE_SHA" "$LOCAL_SHA" 2>/dev/null; then
  exit 0
fi

# Remote has commits we don't have. Block.
cat >&2 <<EOF
Refusing \`git push ${REMOTE_DISPLAY} ${DST_BRANCH}\`: remote has commits not in local HEAD.

Remote ${REMOTE_DISPLAY}/${DST_BRANCH}: ${REMOTE_SHA:0:8}
Local HEAD:                     ${LOCAL_SHA:0:8}

Pushing now would either be rejected as non-fast-forward (you'd then likely retry with --force, dropping someone else's deployed commit), or, with --force-with-lease, would silently overwrite the remote.

Fix:
  git fetch ${REMOTE_DISPLAY}
  git rebase ${REMOTE_DISPLAY}/${DST_BRANCH}
  # resolve any conflicts, then re-run the push.

If the remote commits are not relevant to your work (e.g. another session
pushed a docs change), \`git rebase\` will replay your commits cleanly on top.
EOF
exit 2
