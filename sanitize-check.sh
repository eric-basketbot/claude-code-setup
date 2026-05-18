#!/usr/bin/env bash
# sanitize-check.sh — grep gate against project-specific strings leaking into the public repo.
# Exits 0 if clean, 1 if any forbidden pattern is found. Designed to run pre-commit.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 2

# Patterns that should never appear in the shareable repo.
# Each pattern is grep -E compatible. Add to this list as you find new leakage paths.
PATTERNS=(
  # absolute home paths
  '/Users/ericstonerpersonal'
  '~/.claude/projects/-Users-ericstonerpersonal'
  # project name
  'Basket-?Bot'
  'basketbot\.ai'
  'basket-bot\.com'
  # VPS / Tailscale IPs
  '163\.245\.218\.145'
  '100\.127\.222\.116'
  # OS / VPS users
  'ericstonerpersonal'
  '\bstonerer\b'
  'stonervbakkt@gmail\.com'
  # internal tools / agent names that are project-specific
  '\bOpenClaw\b'
  '\bGandalf\b'
  '\bCCBB\b'
  '\bPenny\b'
  'Cart Captain'
  'Scraper Agent'
  'Search Sage'
  'Brand Analyst'
  # retailer names used as concrete examples
  '\bMeijer\b'
  '\bKroger\b'
  "\bSam's Club\b"
  '\bWalmart\b'
  '\bCostco\b'
  '\bPublix\b'
  '\bWegmans\b'
  'Whole Foods'
  'Trader Joe'
  'Stater Bros'
  "Raley's"
  'Harris Teeter'
  'Food Lion'
  'Giant Eagle'
  'Hannaford'
  'Grocery Outlet'
  'Smart & Final'
  'Fresh Thyme'
  'Lunds & Byerlys'
  'Sprouts'
  '\bALDI\b'
  'Fresh Market'
  '\bTops\b'
  'BJ.?s Wholesale'
  '\bSafeway\b'
  '\bTarget\b'
  # external service-specific IDs
  'basketbot-pg-backups'
  'basketbot-promote-worker'
  'basketbot-scraper'
  'opt/basketbot'
  '@basket-bot\.com'
)

EXCLUDE_DIRS='.git'
EXCLUDE_FILES='sanitize-check.sh'

FOUND=0
for pat in "${PATTERNS[@]}"; do
  hits=$(grep -RIEn --color=never \
    --exclude-dir="$EXCLUDE_DIRS" \
    --exclude="$EXCLUDE_FILES" \
    "$pat" . 2>/dev/null || true)
  if [ -n "$hits" ]; then
    if [ $FOUND -eq 0 ]; then
      echo "sanitize-check.sh: forbidden patterns found:"
      echo ""
    fi
    echo "--- pattern: $pat"
    echo "$hits"
    echo ""
    FOUND=1
  fi
done

if [ $FOUND -eq 1 ]; then
  echo "FAIL: scrub these references before committing."
  exit 1
fi

echo "OK: no forbidden patterns found."
exit 0
