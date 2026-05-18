#!/usr/bin/env bash
# One-shot (idempotent) cleanup for the canonical checkout's backlog of
# dirty / untracked files left over from the pre-v2 hook regime.
#
# Behavior:
#   - Modified tracked files → one stash named pre-cleanup-<date>
#   - Untracked files (excluding gitignored) → moved to
#     ~/.claude/logs/${PROJECT_SLUG}-orphan-files/canonical-<date>/
#   - Nothing is deleted; everything is recoverable.
#
# Idempotent: re-running on a clean canonical is a no-op.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/_lib.sh"

DATE_STR="$(date +%Y-%m-%d)"
ORPHAN_DIR="${ORPHAN_FILES_DIR}/canonical-${DATE_STR}"

cd "$CANONICAL" || { echo "canonical missing: $CANONICAL" >&2; exit 1; }

PORCELAIN="$(git status --porcelain 2>/dev/null || echo "")"
if [[ -z "$PORCELAIN" ]]; then
  echo "Canonical is already clean. Nothing to triage."
  exit 0
fi

HAS_DIRTY_TRACKED="false"
HAS_UNTRACKED="false"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  case "$line" in
    \?\?*) HAS_UNTRACKED="true" ;;
    *)     HAS_DIRTY_TRACKED="true" ;;
  esac
done <<<"$PORCELAIN"

# 1. Stash modified tracked files (does NOT include untracked unless -u).
if [[ "$HAS_DIRTY_TRACKED" == "true" ]]; then
  STASH_MSG="pre-cleanup-${DATE_STR} canonical modified-files"
  if git stash push -m "$STASH_MSG" >/dev/null 2>&1; then
    echo "Stashed modified tracked files: \"${STASH_MSG}\""
    bb_log "triage" "canonical: stashed tracked changes as \"${STASH_MSG}\""
  else
    echo "WARNING: stash push failed; leaving modified files in place." >&2
  fi
fi

# 2. Move untracked files into orphan dir. Skip gitignored.
if [[ "$HAS_UNTRACKED" == "true" ]]; then
  mkdir -p "$ORPHAN_DIR"
  COUNT=0
  # Re-fetch porcelain because stash may have changed status.
  while IFS= read -r line; do
    [[ "$line" == "??"* ]] || continue
    rel="${line:3}"
    src="${CANONICAL}/${rel}"
    [[ -e "$src" ]] || continue
    parent="$(dirname "${ORPHAN_DIR}/${rel}")"
    mkdir -p "$parent" 2>/dev/null || true
    mv "$src" "${ORPHAN_DIR}/${rel}" 2>/dev/null && COUNT=$((COUNT + 1)) || true
  done < <(git status --porcelain)
  if [[ "$COUNT" -gt 0 ]]; then
    echo "Moved ${COUNT} untracked file(s) to ${ORPHAN_DIR}"
    bb_log "triage" "canonical: moved ${COUNT} untracked → ${ORPHAN_DIR}"
  fi
fi

# 3. Final status report.
RESIDUAL="$(git status --porcelain 2>/dev/null || echo "")"
if [[ -z "$RESIDUAL" ]]; then
  echo
  echo "Canonical is now clean."
  echo
  echo "Recovery instructions:"
  if [[ "$HAS_DIRTY_TRACKED" == "true" ]]; then
    echo "  • View stashed changes:   git stash show -p stash@{0}"
    echo "  • Restore stash:          git stash pop          # or git stash apply stash@{0}"
    echo "  • Drop without applying:  git stash drop stash@{0}"
  fi
  if [[ "$HAS_UNTRACKED" == "true" ]]; then
    echo "  • Inspect orphans:        ls ${ORPHAN_DIR}"
    echo "  • Restore orphans:        cp -r ${ORPHAN_DIR}/* ${CANONICAL}/"
    echo "  • Discard orphans:        rm -rf ${ORPHAN_DIR}"
  fi
else
  echo
  echo "Canonical still has residual changes (likely .gitignored or new since triage started):"
  echo "$RESIDUAL"
fi
