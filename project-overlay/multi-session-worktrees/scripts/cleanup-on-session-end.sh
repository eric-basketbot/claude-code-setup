#!/usr/bin/env bash
# SessionEnd hook: identify the worktree assigned to the exiting Claude
# session (via the registry) and run cleanup-worktree.sh on it.
#
# Note: SessionEnd is best-effort. The harness fires it on graceful exit
# but not on Ctrl-C, terminal close, kernel kill, or network drop. The
# hourly idle-reaper.sh launchd job catches everything this misses.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

# Read SessionEnd payload (we don't actually use any fields right now, but
# the harness writes one to stdin and may include the session ID in future).
PAYLOAD="$(cat 2>/dev/null || true)"
_=$PAYLOAD

CLAUDE_PID="$(bb_find_claude_pid)"
if [[ -z "$CLAUDE_PID" ]]; then
  bb_log "skip" "session-end: could not find claude PID; idle-reaper will catch it"
  exit 0
fi

LINE="$(bb_registry_lookup_by_pid "$CLAUDE_PID")"
if [[ -z "$LINE" ]]; then
  # Session was launched with BB_STAY_IN_CANONICAL=1 or in a manual worktree.
  exit 0
fi

WT_PATH="$(awk -F'|' '{print $2}' <<<"$LINE")"
[[ -z "$WT_PATH" ]] && exit 0

bb_log "info" "session-end: cleaning ${WT_PATH} (claude_pid=${CLAUDE_PID})"
bash "$LIB_DIR/cleanup-worktree.sh" "$WT_PATH" "session-end" || true
exit 0
