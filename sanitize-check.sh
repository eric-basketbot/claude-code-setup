#!/usr/bin/env bash
# sanitize-check.sh — grep gate against private strings leaking into the public repo.
# Exits 0 if clean, 1 if any forbidden pattern is found. Run it pre-commit.
#
# Two classes of pattern:
#   IDENTITY  — home paths, usernames, hosts, org/project names, domains
#   SECRETS   — credential VALUES for every provider this pack talks to
#
# The secret patterns are the important half: this repo ships wrappers for five
# AI vendors, and each wrapper documents how to store its key. A copy-paste
# mistake that pastes the key instead of the instruction is exactly the failure
# this gate exists to catch.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 2

PATTERNS=(
  # ---- identity: absolute home paths / usernames --------------------------
  '/Users/ericstonerpersonal'
  'ericstonerpersonal'
  '\bstonerer\b'
  'stonervbakkt@gmail\.com'
  'projects/-Users-'

  # ---- identity: project / org / domain ----------------------------------
  'Basket-?Bot'
  'basketbot'
  'eric-basketbot'
  'basketbot\.ai'
  'basket-bot\.com'
  'opt/basketbot'
  '\bbb-(auto|reviewer|deploy)'

  # ---- identity: hosts / IPs ---------------------------------------------
  '163\.245\.218\.145'
  '100\.127\.222\.116'
  '\.grafana\.net'

  # ---- identity: internal agent / product names ---------------------------
  '\bOpenClaw\b'
  '\bGandalf\b'
  '\bCCBB\b'
  'Cart Captain'
  'Scraper Agent'
  'Search Sage'
  'Brand Analyst'
  'Penny Sage'
  'SKU Whisperer'
  'Price Professor'
  'Store Sherpa'
  'Deal Detective'
  'Pantry Coach'
  'Checkout Pilot'

  # ---- identity: retailer names (domain-specific examples) ----------------
  # Anchored to grocery context where the bare word is also generic English,
  # so "Target:" as a label and "target branch" do not false-positive.
  '\bMeijer\b'
  '\bKroger\b'
  "Sam's Club"
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
  '\bSprouts\b'
  '\bALDI\b'
  'Fresh Market'
  'BJ.?s Wholesale'
  '\bSafeway\b'
  'Target\.com'
  '\bTarget (store|stores|price|prices|API|scraper|zip)'

  # ---- SECRETS: credential values, never instructions --------------------
  'sk-[A-Za-z0-9_-]{20,}'                       # OpenAI / generic
  'sk-ant-[A-Za-z0-9_-]{20,}'                   # Anthropic
  'glsa_[A-Za-z0-9]{10,}'                       # Grafana service account
  'gh[pousr]_[A-Za-z0-9]{20,}'                  # GitHub tokens
  'xox[baprs]-[A-Za-z0-9-]{10,}'                # Slack
  'AIza[0-9A-Za-z_-]{30,}'                      # Google API
  'ey[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.'  # JWT
  '[0-9a-f]{32}\.[A-Za-z0-9]{16,}'              # z.ai / GLM "{key id}.{secret}"
  '-----BEGIN [A-Z ]*PRIVATE KEY'
  # a literal assigned to a known credential var — "${VAR}" references and the
  # empty-string initialisers the wrappers use are deliberately not matched
  '(ZAI_API_KEY|ZAI_AUTH_TOKEN|MOONSHOT_API_KEY|KIMICODE_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|GRAFANA_SERVICE_ACCOUNT_TOKEN|STITCH_API_KEY)=["'"'"']?[A-Za-z0-9][A-Za-z0-9._-]{15,}'
)

FOUND=0
for pat in "${PATTERNS[@]}"; do
  hits=$(grep -RIEn --color=never \
    --exclude-dir='.git' \
    --exclude-dir='__pycache__' \
    --exclude='sanitize-check.sh' \
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

echo "OK: no forbidden patterns found (${#PATTERNS[@]} patterns checked)."
exit 0
