#!/usr/bin/env bash
# Backs the /sessions slash command. Output is plain-text, designed to be
# scanned in a terminal: one section per concern, with leading icons / chars
# so the eye can find issues quickly.
#
# Sections:
#   ACTIVE CLAUDE SESSIONS    — registry-live entries with worktree + dirty status
#   REVIEW QUEUE              — branches with unpushed commits (review-queue.log)
#   FILE OVERLAP              — files touched by 2+ sessions concurrently
#   STASH BACKLOG             — top 5 stashes, oldest first
#   WEEK SUMMARY              — counts from audit logs
#
# No flags, no args. Re-run any time.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

bb_registry_compact || true

echo "=== ACTIVE CLAUDE SESSIONS ==="
echo
LIVE="$(bb_registry_live_lines)"
COUNT_LIVE=0
[[ -n "$LIVE" ]] && COUNT_LIVE="$(printf '%s\n' "$LIVE" | wc -l | tr -d ' ')"

if [[ "$COUNT_LIVE" -eq 0 ]]; then
  echo "(none registered)"
else
  printf '%s\n' "$LIVE" | while IFS='|' read -r pid path branch iso; do
    [[ -z "$pid" ]] && continue
    DIRTY_COUNT=0
    if [[ -d "$path" ]]; then
      DIRTY_COUNT="$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    fi
    AHEAD=0
    if [[ -d "$path" ]] && git -C "$path" rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1; then
      AHEAD="$(git -C "$path" rev-list --count "main..HEAD" 2>/dev/null || echo 0)"
    fi
    PURPOSE_PROMPT=""
    if [[ -f "$path/${PURPOSE_FILE_NAME}" ]]; then
      PURPOSE_PROMPT="$(grep -E '^- Prompt:' "$path/${PURPOSE_FILE_NAME}" 2>/dev/null | sed -E 's/^- Prompt: ?//' | head -1)"
    fi
    DIRTY_STR="clean"
    [[ "$DIRTY_COUNT" -gt 0 ]] && DIRTY_STR="${DIRTY_COUNT} dirty"
    AHEAD_STR=""
    [[ "$AHEAD" -gt 0 ]] && AHEAD_STR=", ${AHEAD} ahead"
    printf '  PID %-6s  %s\n' "$pid" "$path"
    printf '              branch %-32s  started %s  %s%s\n' "$branch" "$iso" "$DIRTY_STR" "$AHEAD_STR"
    if [[ -n "$PURPOSE_PROMPT" && "$PURPOSE_PROMPT" != *"set by model"* ]]; then
      printf '              "%s"\n' "$PURPOSE_PROMPT"
    fi
  done
fi

# Detect canonical sessions (claude PID alive but no registry entry, or
# registry path == canonical).
CANON_PIDS=()
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  CWD="$(lsof -p "$p" 2>/dev/null | awk '$4 == "cwd" {print $NF; exit}')"
  if [[ "$CWD" == "$CANONICAL" ]]; then
    if ! grep -qE "^${p}\|" "$REGISTRY_FILE" 2>/dev/null; then
      CANON_PIDS+=("$p")
    fi
  fi
done < <(pgrep -f 'claude --output-format stream-json' 2>/dev/null)

if [[ "${#CANON_PIDS[@]}" -gt 0 ]]; then
  for p in "${CANON_PIDS[@]}"; do
    printf '  PID %-6s  %s  (canonical, no worktree — read-only or BB_STAY_IN_CANONICAL=1)\n' "$p" "$CANONICAL"
  done
fi

echo
echo "=== REVIEW QUEUE ==="
echo
if [[ -s "$REVIEW_QUEUE_LOG" ]]; then
  # Format: iso|branch|wt_path|ahead_count|subject
  awk -F'|' '{
    printf("  %-32s  %s commit(s)  last: \"%s\"  (queued %s)\n", $2, $4, $5, $1)
  }' "$REVIEW_QUEUE_LOG" | tail -10
  TOTAL_QUEUE="$(wc -l < "$REVIEW_QUEUE_LOG" | tr -d ' ')"
  echo
  echo "  ($TOTAL_QUEUE total in queue at $REVIEW_QUEUE_LOG)"
  echo "  Use /wt rm <name> after merging, or git push the branch and let daily-janitor delete it."
else
  echo "(empty)"
fi

echo
echo "=== FILE OVERLAP ==="
echo
# For each live worktree, list dirty tracked files. Find any file appearing
# in >= 2 lists.
OVERLAP_TMP="$(mktemp -t bb-overlap.XXXXXX)"
printf '%s\n' "$LIVE" | while IFS='|' read -r pid path branch iso; do
  [[ -z "$pid" || ! -d "$path" ]] && continue
  git -C "$path" status --porcelain 2>/dev/null | awk -v p="$pid" '
    $1 != "??" && NF >= 2 {
      for (i = 2; i <= NF; i++) printf("%s\t%s\n", $i, p)
    }' >> "$OVERLAP_TMP"
done
# Group by file, list ones with >=2 PIDs.
OVERLAPS="$(sort "$OVERLAP_TMP" | awk -F'\t' '
  { files[$1] = files[$1] " " $2 }
  END { for (f in files) {
      n = split(files[f], arr, " ")
      uniq = ""
      for (i = 1; i <= n; i++) {
        if (arr[i] != "" && index(uniq, " " arr[i] " ") == 0) {
          uniq = uniq " " arr[i] " "
        }
      }
      gsub(/^  | $/, "", uniq)
      pid_count = split(uniq, _arr, " ")
      if (pid_count >= 2) printf("%s\t%s\n", f, uniq)
    } }')"
rm -f "$OVERLAP_TMP"

if [[ -z "$OVERLAPS" ]]; then
  echo "(none — no file is dirty in 2+ sessions)"
else
  echo "$OVERLAPS" | while IFS=$'\t' read -r file pids; do
    printf '  %-60s  PID %s  ⚠ resolve before commit\n' "$file" "$pids"
  done
fi

echo
echo "=== STASH BACKLOG ==="
echo
TOTAL_STASH="$(git -C "$CANONICAL" stash list 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$TOTAL_STASH" -eq 0 ]]; then
  echo "(empty)"
else
  echo "Total: $TOTAL_STASH"
  git -C "$CANONICAL" stash list --pretty='format:  %gd %ci %gs' 2>/dev/null | head -5
  if [[ "$TOTAL_STASH" -gt 5 ]]; then
    echo "  ... and $((TOTAL_STASH - 5)) more (git stash list to see all)"
  fi
fi

echo
echo "=== WEEK SUMMARY ==="
echo
GIT_LOG="${LOG_DIR}/${PROJECT_SLUG}-git-cwd.jsonl"
WEEK_AGO="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")"

BLOCKED=0
WARNED=0
if [[ -f "$GIT_LOG" ]]; then
  BLOCKED="$(jq -rc --arg w "$WEEK_AGO" 'select(.ts >= $w) | select(.action == "blocked")' "$GIT_LOG" 2>/dev/null | wc -l | tr -d ' ')"
  WARNED="$(jq -rc --arg w "$WEEK_AGO" 'select(.ts >= $w) | select(.action == "warned")' "$GIT_LOG" 2>/dev/null | wc -l | tr -d ' ')"
fi

PRUNED=0
if [[ -f "$CLEANUP_LOG" ]]; then
  PRUNED="$(awk -v w="$WEEK_AGO" '$1 >= w && /\] (removed|stashed|orphaned|queued) / { c++ } END { print c+0 }' "$CLEANUP_LOG" 2>/dev/null || echo 0)"
fi

QUEUE_GROWTH=0
if [[ -f "$REVIEW_QUEUE_LOG" ]]; then
  QUEUE_GROWTH="$(awk -F'|' -v w="$WEEK_AGO" '$1 >= w' "$REVIEW_QUEUE_LOG" 2>/dev/null | wc -l | tr -d ' ')"
fi

printf '  blocked-in-canonical: %s   warned-in-canonical: %s   worktrees-cleaned: %s   review-queue-growth: %s\n' \
  "$BLOCKED" "$WARNED" "$PRUNED" "$QUEUE_GROWTH"

echo
echo "Logs:"
echo "  ~/.claude/logs/${PROJECT_SLUG}-git-cwd.jsonl       — every git mutation attempt"
echo "  ~/.claude/logs/${PROJECT_SLUG}-worktree-cleanup.log — cleanup actions"
echo "  ~/.claude/logs/${PROJECT_SLUG}-review-queue.log     — branches awaiting review"
echo "  ~/.claude/logs/${PROJECT_SLUG}-orphan-files/        — recovered untracked files"
