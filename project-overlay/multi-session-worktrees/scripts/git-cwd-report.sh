#!/usr/bin/env bash
# Summarize ~/.claude/logs/${PROJECT_SLUG}-git-cwd.jsonl: how many git mutations,
# how many were in the canonical checkout while parallel sessions were active
# (= worktree-rule violations), and the recent offenders.
#
# Usage:
#   scripts/claude-hooks/git-cwd-report.sh           # all-time
#   scripts/claude-hooks/git-cwd-report.sh --today   # since UTC midnight
#   scripts/claude-hooks/git-cwd-report.sh --tail N  # last N events

set -uo pipefail

LOG="${HOME}/.claude/logs/${PROJECT_SLUG}-git-cwd.jsonl"

if [[ ! -f "$LOG" ]]; then
  echo "No log yet at $LOG — hook hasn't fired or wasn't installed."
  exit 0
fi

FILTER='.'
case "${1:-}" in
  --today)
    TODAY="$(date -u +%Y-%m-%d)"
    FILTER='select(.ts | startswith("'"$TODAY"'"))'
    ;;
  --tail)
    N="${2:-20}"
    jq -c "$FILTER" "$LOG" | tail -n "$N"
    exit 0
    ;;
esac

TOTAL="$(jq -c "$FILTER" "$LOG" | wc -l | tr -d ' ')"
if [[ "$TOTAL" -eq 0 ]]; then
  echo "No matching events."
  exit 0
fi

VIOLATIONS="$(jq -c "$FILTER | select(.should_be_in_worktree == true)" "$LOG" | wc -l | tr -d ' ')"
COMPLIANT=$((TOTAL - VIOLATIONS))
RATE="$(awk "BEGIN { printf \"%.1f\", ($COMPLIANT * 100) / $TOTAL }")"

echo "git mutations logged: $TOTAL"
echo "  compliant (worktree, or solo session in canonical): $COMPLIANT"
echo "  violations (canonical + parallel sessions):         $VIOLATIONS"
echo "  compliance rate: ${RATE}%"

if [[ "$VIOLATIONS" -gt 0 ]]; then
  echo
  echo "Last 5 violations:"
  jq -c "$FILTER | select(.should_be_in_worktree == true)" "$LOG" \
    | tail -n 5 \
    | jq -r '"  \(.ts)  pid=\(.pid)  sessions=\(.sessions)  git \(.verb)  \(.command[0:80])"'
fi
