#!/usr/bin/env bash
# Hourly launchd job. For every wt-auto-* worktree (both legacy /tmp/wt-auto-*
# and new ~/.agent-worktrees/wt-auto-*):
#   - if a live claude PID owns it (per registry) → skip
#   - if branch tip is unchanged for >= IDLE_HOURS → run cleanup-worktree.sh
#
# Catches sessions that crashed without firing SessionEnd. cleanup-worktree.sh
# preserves WIP via stash/orphan-move so nothing is lost.
#
# KNOWN LIMITATION: macOS TCC blocks launchd-spawned bash from reading files
# under ~/Downloads. If this script lives in the canonical repo there, every
# hourly fire errors "Operation not permitted" and the safety net silently
# breaks. See docs/launchd-safety-net-tcc.md for the FDA-grant workaround
# that lets the launchd path succeed.

set -uo pipefail

IDLE_HOURS="${BB_IDLE_HOURS:-4}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

# Compact the registry so dead PIDs are dropped.
bb_registry_compact || true

NOW="$(date +%s)"
THRESHOLD="$((NOW - IDLE_HOURS * 3600))"

# Live worktree paths (claude PID still alive).
LIVE_PATHS_TMP="$(mktemp -t bb-live.XXXXXX)"
bb_registry_live_lines | awk -F'|' '{print $2}' > "$LIVE_PATHS_TMP" 2>/dev/null || true

# Scan BOTH the new WORKTREE_BASE/wt-auto-* (reboot-survivable) and the
# legacy /tmp/wt-auto-* paths (macOS resolves /tmp → /private/tmp, so check
# both /tmp prefixes).
for d in "${WORKTREE_BASE}"/wt-auto-* /tmp/wt-auto-* /private/tmp/wt-auto-*; do
  [[ -d "$d" ]] || continue
  # Resolve to physical path for comparison.
  REAL="$(cd "$d" 2>/dev/null && pwd -P)" || continue
  ALIAS="${REAL/#\/private\/tmp/\/tmp}"

  # Skip if any registry-live entry points at this worktree.
  if grep -Fxq "$REAL" "$LIVE_PATHS_TMP" 2>/dev/null \
     || grep -Fxq "$ALIAS" "$LIVE_PATHS_TMP" 2>/dev/null; then
    continue
  fi

  # Idle check: branch tip's commit time, OR the worktree dir's mtime,
  # whichever is more recent. We want the most-recent activity signal.
  BRANCH_FILE="$d/.git"
  [[ -e "$BRANCH_FILE" ]] || continue

  LAST_COMMIT_TS="$(git -C "$d" log -1 --pretty=%ct 2>/dev/null || echo 0)"
  DIR_TS="$(stat -f '%m' "$d" 2>/dev/null || echo 0)"
  PURPOSE_TS="$(stat -f '%m' "$d/${PURPOSE_FILE_NAME}" 2>/dev/null || echo 0)"

  RECENT="$LAST_COMMIT_TS"
  [[ "$DIR_TS" -gt "$RECENT" ]] && RECENT="$DIR_TS"
  [[ "$PURPOSE_TS" -gt "$RECENT" ]] && RECENT="$PURPOSE_TS"

  if [[ "$RECENT" -lt "$THRESHOLD" ]]; then
    bb_log "info" "idle-reaper: ${d} idle since $(date -r "$RECENT" -u +%Y-%m-%dT%H:%M:%SZ) — cleaning"
    bash "$LIB_DIR/cleanup-worktree.sh" "$d" "idle-reaper" || true
  fi
done

rm -f "$LIVE_PATHS_TMP"
exit 0
