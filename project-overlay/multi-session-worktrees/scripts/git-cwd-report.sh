#!/usr/bin/env bash
# Summarize ~/.claude/logs/myproject-git-cwd.jsonl: how many git mutations,
# how many were in the canonical checkout while parallel sessions were active
# (= worktree-rule violations), and the recent offenders.
#
# Usage:
#   scripts/claude-hooks/git-cwd-report.sh           # all-time
#   scripts/claude-hooks/git-cwd-report.sh --today   # since UTC midnight
#   scripts/claude-hooks/git-cwd-report.sh --tail N  # last N events

set -uo pipefail

LOG="${BB_LOG_DIR:-${HOME}/.claude/logs}/myproject-git-cwd.jsonl"
SAFE_EVENT='{ts: (.ts // "unknown"), pid: (.pid // 0), hook_host: (.hook_host // "legacy"), session_id: (.session_id // "unknown"), cwd: (.cwd // "unknown"), top: (.top // "unknown"), verb: (.verb // "unknown"), sessions: (.sessions // 0), in_canonical: (.in_canonical // false), action: (.action // "unknown")}'
VIOLATION_FILTER='select(.action == "blocked" or .should_be_in_worktree == true)'

if [[ ! -f "$LOG" ]]; then
  echo "No log yet at $LOG — hook hasn't fired or wasn't installed."
  exit 0
fi

FILTER='.'
case "${1:-}" in
  --today)
    TODAY="$(date -u +%Y-%m-%d)"
    FILTER='select(.ts | strings | startswith("'"$TODAY"'"))'
    ;;
  --tail)
    N="${2:-20}"
    if ! jq -c "$FILTER | $SAFE_EVENT" "$LOG" | tail -n "$N"; then
      echo "Unable to parse audit log: $LOG" >&2
      exit 1
    fi
    exit 0
    ;;
esac

TOTAL="$(jq -c "$FILTER" "$LOG" | wc -l | tr -d ' ')"
if [[ "$TOTAL" -eq 0 ]]; then
  echo "No matching events."
  exit 0
fi

VIOLATIONS="$(jq -c "$FILTER | $VIOLATION_FILTER" "$LOG" | wc -l | tr -d ' ')"
COMPLIANT=$((TOTAL - VIOLATIONS))
RATE="$(awk "BEGIN { printf \"%.1f\", ($COMPLIANT * 100) / $TOTAL }")"

echo "git mutations logged: $TOTAL"
echo "  compliant (worktree, or solo session in canonical): $COMPLIANT"
echo "  violations (blocked canonical mutations):           $VIOLATIONS"
echo "  compliance rate: ${RATE}%"

if [[ "$VIOLATIONS" -gt 0 ]]; then
  echo
  echo "Last 5 violations:"
  jq -c "$FILTER | $VIOLATION_FILTER" "$LOG" \
    | tail -n 5 \
    | jq -r '
        def clean: tostring | gsub("[\u0000-\u001f\u007f]"; "?");
        "  \(.ts // "unknown" | clean)  host=\(.hook_host // "legacy" | clean)  session=\(.session_id // "unknown" | clean)  pid=\(.pid // 0)  sessions=\(.sessions // 0)  git \(.verb // "unknown" | clean)  action=\(.action // "unknown" | clean)"
      '
fi
