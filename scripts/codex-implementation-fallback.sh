#!/usr/bin/env bash
# codex-implementation-fallback.sh — safe dispatcher for the Opus-Fallback
# Implementation Protocol (~/.claude/rules/opus-fallback-implementation.md).
#
# When a Claude session has fallen back from Fable (normally to Opus), Claude
# delegates non-trivial IMPLEMENTATION but keeps orchestration, git, review
# gates, and memory. This wrapper is the ONLY sanctioned dispatch path — there
# is no raw fallback; if this file is missing, the protocol fails closed and
# the orchestrator implements itself (the ai-config audit enforces that this
# wrapper exists and is executable).
#
# ENGINE LADDER (user directive 2026-07-18: Kimi outranks gpt-5.5):
#   1. Codex gpt-5.6-sol (or --model override)
#   2. Kimi K-series      — managed subscription + native Extra Usage. Bare
#                           `kimi` CLI run
#                           headless IN the worktree (NOT the read-only
#                           kimi-review wrapper). No OS sandbox — containment is
#                           the sentinel constraints + this wrapper's git guard
#                           + worktree isolation. The Kimi rung's prompt adds:
#                           no package installs / no writes through the
#                           node_modules|dist|.next symlinks (they point into
#                           canonical and kimi has no sandbox to stop it).
#   3. Kimi Open Platform — ONLY after exact managed-quota exhaustion, using
#                           kimi-k3 and a key injected from macOS Keychain.
#   4. Codex gpt-5.5      — when Kimi is unavailable (unauthenticated "LLM not
#                           set" exit-0 gotcha; missing binary; error), or its
#                           paid API retry fails.
#   5. (caller)           — all engines exhausted: the orchestrator implements
#                           itself and reports the degradation.
#   EVERY rung gets one exit-137 retry (transient memory pressure) on the same
#   engine. Every retry/rung change requires an UNTOUCHED workspace — partial
#   edits stop the ladder (exit 5) so a rerun can never duplicate work, and
#   that guard is checked again before declaring all-engines-exhausted.
#
#   The REVIEW waterfall (codex-reviewer: sol → gpt-5.5) is separate/unchanged.
#
# ENFORCED INVARIANTS
#   1. WORKTREE ONLY — refuses the canonical <project> checkout (exit 4).
#   2. SAFE PROMPT PASSING — task from --task-file, passed as one argv, stdin
#      from /dev/null (heredoc-to-stdin hangs codex; inline interpolation would
#      execute backticks/$() in the OUTER shell).
#   3. SENTINEL — prepends "[OPUS-FALLBACK DISPATCH]" + role constraints.
#   4. GIT-STATE GUARD — HEAD/branch snapshot before/after; a commit or branch
#      switch by ANY engine = exit 3, loud, never auto-reset.
#   5. ENGINE REPORT — prints which engine produced the diff; the review gates
#      need it to pick the authored-diff advisory row.
#
# EXIT CODES
#   0 success   2 usage error          3 git-state violation (commit/branch moved)
#   4 refused (canonical / not a worktree)   5 partial edits present — ladder stopped
#   6 all engines exhausted (orchestrator implements itself)
#   other: the final engine's own exit code
#
# TEST HOOKS: CODEX_BIN, KIMI_BIN, KIMI_API_BIN, BB_CANONICAL, BB_DISPATCH_TIMEOUT,
#             KIMI_API_KEY, KIMI_API_KEY_SERVICE
set -uo pipefail

CODEX="${CODEX_BIN:-$HOME/.npm-global/bin/codex}"
KIMI="${KIMI_BIN:-$HOME/.local/bin/kimi}"
KIMI_API_BIN="${KIMI_API_BIN:-$HOME/.kimi-code/bin/kimi}"
# K3 = long-horizon coding flagship (implementer profile; reasoning default max).
# The Kimi CLI needs the provider-namespaced ID — bare "k3" fails as "LLM not set"
# (verified 2026-07-18). Review stays on the account default (K2.7 Code).
KIMI_MODEL="${KIMI_IMPL_MODEL:-kimi-code/k3}"
KIMI_API_KEY_SERVICE="${KIMI_API_KEY_SERVICE:-ai-config.kimi.MOONSHOT_API_KEY}"
KIMI_API_BASE_URL="${KIMI_API_BASE_URL:-https://api.moonshot.ai/v1}"
KIMI_API_MODEL_NAME="${KIMI_API_MODEL_NAME:-kimi-k3}"
KIMI_API_CONTEXT_SIZE="${KIMI_API_CONTEXT_SIZE:-1048576}"
KIMI_API_CAPABILITIES="${KIMI_API_CAPABILITIES:-thinking,image_in,video_in,tool_use}"
PAID_API_KEY=""
# Your canonical checkout — the one the wrapper REFUSES to dispatch into.
# Set AI_CANONICAL_REPO (or the legacy BB_CANONICAL) in your shell profile.
CANONICAL="${AI_CANONICAL_REPO:-${BB_CANONICAL:-$HOME/src/your-project}}"
REPO="$PWD"
TASK=""
TASK_FILE=""
MODEL=""
TIMEOUT="${BB_DISPATCH_TIMEOUT:-0}"

usage() { sed -n '2,50p' "$0"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:-}"; shift 2 ;;
    --task)      TASK="${2:-}"; shift 2 ;;
    --task-file) TASK_FILE="${2:-}"; shift 2 ;;
    --model)     MODEL="${2:-}"; shift 2 ;;
    --timeout)   TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "[dispatch] unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$TASK_FILE" ]; then
  [ -f "$TASK_FILE" ] || { echo "[dispatch] task file not found: $TASK_FILE" >&2; exit 2; }
  TASK="$(cat "$TASK_FILE")"
fi
[ -n "${TASK// /}" ] || { echo "[dispatch] empty task (use --task or --task-file)" >&2; exit 2; }
[ -x "$CODEX" ] || { echo "[dispatch] codex not found at $CODEX" >&2; exit 2; }

# --- Worktree validation (refuse canonical, refuse non-repo) -----------------
ROOT="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "[dispatch] REFUSED: $REPO is not inside a git worktree" >&2; exit 4; }
ROOT_PHYS="$(cd "$ROOT" && pwd -P)"
CANON_PHYS="$(cd "$CANONICAL" 2>/dev/null && pwd -P || echo "/nonexistent")"
case "$ROOT_PHYS/" in
  "$CANON_PHYS/"*)
    echo "[dispatch] REFUSED: $ROOT_PHYS is the canonical checkout (or inside it)." >&2
    echo "[dispatch] Dispatch only from a session worktree (e.g. ~/.agent-worktrees/...)." >&2
    exit 4 ;;
esac

# --- Sentinel + task ----------------------------------------------------------
PROMPT="[OPUS-FALLBACK DISPATCH] You are the dispatched implementer under the
Opus-Fallback Implementation Protocol (see the rule in AGENTS.md). Implement
ONLY within this worktree. Do NOT run git commit, git push, or any
branch/remote/stash operation, and do not deploy. Run builds/tests as needed.
End with a summary of changes and the list of files touched.

--- TASK ---
$TASK"

# The Kimi rung has no OS sandbox, and node_modules/dist/.next are symlinks
# into the canonical checkout — forbid the writes the sandbox would have blocked.
KIMI_PROMPT="$PROMPT

[KIMI RUNG CONSTRAINTS] You have no sandbox. Edit source files only. Do NOT run
package installs or builds, and do NOT write into node_modules/, dist/,
client/dist/, or .next/ (they are symlinks that leave this worktree)."

# --- Git-state snapshot -------------------------------------------------------
snap_head()   { git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo NONE; }
snap_branch() { git -C "$ROOT" branch --show-current 2>/dev/null || echo ""; }
snap_status() { git -C "$ROOT" status --porcelain 2>/dev/null || echo ""; }
HEAD0="$(snap_head)"; BRANCH0="$(snap_branch)"; STATUS0="$(snap_status)"

workspace_untouched() {
  [ "$(snap_head)" = "$HEAD0" ] && [ "$(snap_status)" = "$STATUS0" ]
}

maybe_timeout() {
  if [ "${TIMEOUT:-0}" -gt 0 ] 2>/dev/null && command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TIMEOUT" "$@"
  else
    "$@"
  fi
}

LAST_OUTPUT=""; LAST_RC=0
run_codex() { # $1 = model override ("" = config default)
  local model="$1" out rc
  local -a cmd=("$CODEX" exec --sandbox workspace-write)
  [ -n "$model" ] && cmd+=(-m "$model")
  cmd+=("$PROMPT")
  out="$(cd "$ROOT" && maybe_timeout "${cmd[@]}" < /dev/null 2>&1)"; rc=$?
  printf '%s\n' "$out"
  LAST_OUTPUT="$out"; LAST_RC=$rc
}
load_paid_api_key() {
  if [ -n "${KIMI_API_KEY:-}" ]; then
    PAID_API_KEY="$KIMI_API_KEY"
  elif command -v security >/dev/null 2>&1; then
    PAID_API_KEY="$(security find-generic-password -a "$(id -un)" -s "$KIMI_API_KEY_SERVICE" -w 2>/dev/null || true)"
  fi
  [ -n "$PAID_API_KEY" ]
}

run_kimi() { # $1 = managed|api
  local mode="${1:-managed}" out rc
  if [ "$mode" = "api" ]; then
    out="$(cd "$ROOT" && maybe_timeout env \
      KIMI_MODEL_BASE_URL="$KIMI_API_BASE_URL" \
      KIMI_MODEL_API_KEY="$PAID_API_KEY" \
      KIMI_MODEL_NAME="$KIMI_API_MODEL_NAME" \
      KIMI_MODEL_MAX_CONTEXT_SIZE="$KIMI_API_CONTEXT_SIZE" \
      KIMI_MODEL_CAPABILITIES="$KIMI_API_CAPABILITIES" \
      "$KIMI_API_BIN" -p "$KIMI_PROMPT" < /dev/null 2>&1)"; rc=$?
  else
    out="$(cd "$ROOT" && maybe_timeout "$KIMI" -m "$KIMI_MODEL" --quiet -p "$KIMI_PROMPT" < /dev/null 2>&1)"; rc=$?
  fi
  printf '%s\n' "$out"
  LAST_OUTPUT="$out"; LAST_RC=$rc
}

# One exit-137 retry per engine invocation, same engine, untouched-only.
run_engine() { # $1 = "codex"|"kimi"|"kimi-api", $2 = model (codex only)
  local kind="$1" model="${2:-}"
  case "$kind" in
    kimi)     run_kimi managed ;;
    kimi-api) run_kimi api ;;
    *)        run_codex "$model" ;;
  esac
  if [ $LAST_RC -eq 137 ]; then
    if workspace_untouched; then
      echo "[dispatch] exit 137 (transient memory pressure) — retrying once, same engine ($kind)" >&2
      case "$kind" in
        kimi)     run_kimi managed ;;
        kimi-api) run_kimi api ;;
        *)        run_codex "$model" ;;
      esac
    else
      stop_ladder_partial "exit 137"
    fi
  fi
}

hit_usage_limit() { printf '%s' "$LAST_OUTPUT" | grep -qi "hit your usage limit"; }
kimi_soft_failure() {
  # Kimi failure phrases regardless of exit code (unauth "LLM not set" exits 0;
  # assume quota/rate-limit text may too).
  printf '%s' "$LAST_OUTPUT" | grep -qiE "LLM not set|quota exceeded|rate limit|usage limit"
}
kimi_managed_quota_exhausted() {
  printf '%s' "$LAST_OUTPUT" | grep -qiE "reached your usage limit|usage limit for this billing cycle|monthly usage limit|quota exceeded|access_terminated_error"
}

stop_ladder_partial() {
  echo "[dispatch] $1 AFTER partial edits — ladder stopped (rerun could duplicate work)." >&2
  echo "[dispatch] Inspect the diff and continue manually. Exit 5." >&2
  exit 5
}

# --- Rung 1: Codex sol (or explicit --model) ---------------------------------
ENGINE="codex:${MODEL:-gpt-5.6-sol(default)}"
run_engine codex "$MODEL"

if hit_usage_limit; then
  workspace_untouched || stop_ladder_partial "usage limit"
  # --- Rung 2: Kimi (user directive: outranks gpt-5.5; exceedingly rare) ----
  if [ -x "$KIMI" ]; then
    echo "[dispatch] Codex usage limit — escalating to Kimi (rung 2, $KIMI_MODEL)" >&2
    ENGINE="kimi:$KIMI_MODEL"
    run_engine kimi
    KIMI_SUCCEEDED=1
    if [ $LAST_RC -ne 0 ] || kimi_soft_failure; then
      workspace_untouched || stop_ladder_partial "Kimi failure"
      KIMI_SUCCEEDED=0
      if kimi_managed_quota_exhausted; then
        if [ ! -x "$KIMI_API_BIN" ]; then
          echo "[dispatch] native Kimi paid-API binary missing at $KIMI_API_BIN" >&2
        elif load_paid_api_key; then
          echo "[dispatch] Kimi subscription and Extra Usage exhausted — escalating to PAID Open Platform API (rung 3, $KIMI_API_MODEL_NAME)" >&2
          ENGINE="kimi-api:$KIMI_API_MODEL_NAME"
          run_engine kimi-api
          if [ $LAST_RC -eq 0 ] && ! kimi_soft_failure; then
            KIMI_SUCCEEDED=1
          else
            workspace_untouched || stop_ladder_partial "Kimi paid API failure"
            echo "[dispatch] Kimi paid API rung failed — continuing without another paid retry" >&2
          fi
        else
          echo "[dispatch] Kimi subscription and Extra Usage exhausted; Keychain service '$KIMI_API_KEY_SERVICE' has no paid API key" >&2
        fi
      fi
    fi
    if [ "$KIMI_SUCCEEDED" = 0 ]; then
      echo "[dispatch] Kimi rung failed/unavailable — falling to codex -m gpt-5.5 (rung 4)" >&2
      ENGINE="codex:gpt-5.5"
      run_engine codex "gpt-5.5"
    fi
  else
    echo "[dispatch] kimi binary missing at $KIMI — skipping Kimi rungs, trying -m gpt-5.5" >&2
    ENGINE="codex:gpt-5.5"
    run_engine codex "gpt-5.5"
  fi
  if hit_usage_limit; then
    workspace_untouched || stop_ladder_partial "final-rung usage limit"
    echo "[dispatch] ALL ENGINES EXHAUSTED (sol, Kimi managed/Extra Usage, Kimi paid API when available, gpt-5.5) — the orchestrator implements this task itself and reports the degradation (rule: opus-fallback-implementation.md § Engine ladder). Exit 6." >&2
    exit 6
  fi
fi

# --- Post-dispatch git-state guard -------------------------------------------
HEAD1="$(snap_head)"; BRANCH1="$(snap_branch)"
if [ "$HEAD1" != "$HEAD0" ] || [ "$BRANCH1" != "$BRANCH0" ]; then
  echo "[dispatch] GIT-STATE VIOLATION: HEAD or branch changed during dispatch (engine: $ENGINE)" >&2
  echo "[dispatch]   HEAD:   $HEAD0 -> $HEAD1" >&2
  echo "[dispatch]   branch: $BRANCH0 -> $BRANCH1" >&2
  echo "[dispatch] NOT auto-resetting — inspect with: git -C $ROOT log --oneline -3; git -C $ROOT reflog -5" >&2
  exit 3
fi

echo "[dispatch] --- post-dispatch report ---"
echo "[dispatch] engine: $ENGINE   exit: $LAST_RC"
echo "[dispatch] workspace changes (git status --porcelain):"
snap_status | sed 's/^/[dispatch]   /'
echo "[dispatch] verify next: git -C $ROOT diff   (and git -C $ROOT status)"
exit $LAST_RC
