#!/usr/bin/env bash
# Daily 04:00 launchd job. Defense in depth on top of the hourly idle reaper.
# - Anything still in wt-auto-* (legacy /tmp/ or new WORKTREE_BASE) older
#   than MAX_AGE_DAYS days: cleanup
# - `git worktree prune` to drop dead worktree pointers
# - Delete `wt/auto-*` branches that are merged into main and have no worktree
# - Compact the registry
#
# Subject to the same macOS TCC limitation as idle-reaper.sh when the script
# lives under ~/Downloads — see docs/launchd-safety-net-tcc.md.

set -uo pipefail

MAX_AGE_DAYS="${BB_MAX_AGE_DAYS:-3}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

bb_registry_compact || true

NOW="$(date +%s)"
THRESHOLD="$((NOW - MAX_AGE_DAYS * 86400))"

# 1. Force-clean any wt-auto-* worktree older than MAX_AGE_DAYS, regardless
#    of which base directory it lives in.
LIVE_PATHS_TMP="$(mktemp -t bb-live.XXXXXX)"
bb_registry_live_lines | awk -F'|' '{print $2}' > "$LIVE_PATHS_TMP" 2>/dev/null || true

for d in "${WORKTREE_BASE}"/wt-auto-* /tmp/wt-auto-* /private/tmp/wt-auto-*; do
  [[ -d "$d" ]] || continue
  REAL="$(cd "$d" 2>/dev/null && pwd -P)" || continue
  ALIAS="${REAL/#\/private\/tmp/\/tmp}"

  if grep -Fxq "$REAL" "$LIVE_PATHS_TMP" 2>/dev/null \
     || grep -Fxq "$ALIAS" "$LIVE_PATHS_TMP" 2>/dev/null; then
    continue
  fi

  DIR_TS="$(stat -f '%m' "$d" 2>/dev/null || echo 0)"
  if [[ "$DIR_TS" -lt "$THRESHOLD" ]]; then
    bb_log "info" "daily-janitor: ${d} older than ${MAX_AGE_DAYS}d — cleaning"
    bash "$LIB_DIR/cleanup-worktree.sh" "$d" "daily-janitor" || true
  fi
done
rm -f "$LIVE_PATHS_TMP"

# 2. Prune dead worktree pointers.
git -C "$CANONICAL" worktree prune 2>/dev/null || true

# 3. Delete merged wt/auto-* branches with no worktree.
ALL_WT_PATHS="$(git -C "$CANONICAL" worktree list --porcelain 2>/dev/null \
  | awk '/^worktree / {print $2}')"

git -C "$CANONICAL" branch --merged main 2>/dev/null \
  | sed -E 's/^[*[:space:]]+//' \
  | grep -E '^wt/auto-' \
  | while IFS= read -r br; do
      # Skip if any worktree is on this branch.
      if git -C "$CANONICAL" worktree list --porcelain 2>/dev/null \
           | grep -qE "^branch refs/heads/${br}$"; then
        continue
      fi
      git -C "$CANONICAL" branch -d "$br" >/dev/null 2>&1 \
        && bb_log "info" "daily-janitor: deleted merged branch ${br}"
    done

bb_log "info" "daily-janitor complete"
exit 0
