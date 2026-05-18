#!/usr/bin/env bash
# install.sh — drop the user-level pieces into ~/.claude/.
# Idempotent. Re-running is safe. Use --dry-run to preview, --uninstall to reverse.
#
# What gets installed (under $HOME/.claude/):
#   rules/codex-adversarial-review.md        the flagship 3-vendor review gate
#   rules/{development-workflow,agents,git-workflow,performance,...}.md
#   agents/codex-reviewer.md                 wraps `codex exec review`
#   agents/coderabbit-reviewer.md            wraps `coderabbit review --plain`
#   hooks/memory_health_audit.py             memory lifecycle (launchd-driven)
#   hooks/session_snapshot.py                15-min rolling session snapshots
#   hooks/precompact_session_log.py          one-line breadcrumb on every compact
#   hooks/cc-{write-injection-guard,context-monitor,read-injection-scanner,statusline}.js
#   scripts/cross-ai-review.sh               manual 3-vendor review aggregator
#   settings.json fragment merged into ~/.claude/settings.json
#   ~/.claude/projects/<slug>/memory/ skeleton (for whichever project you point us at)
#
# Does NOT install:
#   - The project-overlay/multi-session-worktrees/ harness — run that separately
#     via ./project-overlay/multi-session-worktrees/install-in-project.sh <path>
#   - Any upstream/marketplace skills — see upstream-skills.md for install commands

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

DRY_RUN=0
FORCE=0
UNINSTALL=0
BOOTSTRAP_PROJECT=""

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--force] [--bootstrap-project <path>] [--uninstall]

  --dry-run                 print every action without executing
  --force                   overwrite existing files instead of skipping
  --bootstrap-project PATH  create the memory dir skeleton under
                            ~/.claude/projects/<encoded-slug>/memory/
  --uninstall               reverse the install (files removed, settings backup kept)
  -h, --help                this help

Default behavior:
  - Copies files into ~/.claude/{rules,agents,hooks,scripts}/ (skipping existing files)
  - Backs up ~/.claude/settings.json to settings.json.bak.<iso> before any change
  - Merges this repo's settings.json.fragment into ~/.claude/settings.json (deduped)
  - chmods +x the hook scripts
  - Prints next steps
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --bootstrap-project) BOOTSTRAP_PROJECT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say()    { printf '  %s\n' "$*"; }
banner() { printf '\n== %s ==\n' "$*"; }
run() {
  if (( DRY_RUN )); then
    say "[dry-run] $*"
  else
    eval "$@"
  fi
}

# ---- preflight ------------------------------------------------------------
banner "Preflight"
have_claude=1; have_jq=1; have_python3=1
command -v claude  >/dev/null 2>&1 || have_claude=0
command -v jq      >/dev/null 2>&1 || have_jq=0
command -v python3 >/dev/null 2>&1 || have_python3=0

(( have_claude  )) || say "WARN: claude CLI not found in PATH — hooks won't fire until it's installed."
(( have_jq      )) || say "WARN: jq not found — settings.json merge will fall back to print-fragment-for-manual-merge."
(( have_python3 )) || say "WARN: python3 not found — Python hooks will fail at runtime."

# ---- uninstall (reverse the install) -------------------------------------
if (( UNINSTALL )); then
  banner "Uninstall"
  for d in rules agents hooks scripts; do
    if [[ -d "$SELF_DIR/$d" ]]; then
      for f in "$SELF_DIR/$d"/*; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f")"
        target="$CLAUDE_DIR/$d/$base"
        if [[ -f "$target" ]]; then
          # Only remove if content matches (don't delete user-edited files)
          if cmp -s "$f" "$target"; then
            run "rm -f '$target'"
          else
            say "SKIP $target (modified locally)"
          fi
        fi
      done
    fi
  done
  say "Settings.json backups under $CLAUDE_DIR/ are preserved. Manually unmerge hooks if desired."
  echo ""
  echo "Done."
  exit 0
fi

# ---- backup settings.json -------------------------------------------------
banner "Backup"
if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  bak="$CLAUDE_DIR/settings.json.bak.$ts"
  run "cp '$CLAUDE_DIR/settings.json' '$bak'"
  say "settings.json -> $bak"
else
  say "no existing settings.json — fragment will seed a fresh one"
fi

# ---- copy files -----------------------------------------------------------
banner "Copy files"
copy_dir() {
  local src_subdir="$1"
  local dst_subdir="$2"
  local src="$SELF_DIR/$src_subdir"
  local dst="$CLAUDE_DIR/$dst_subdir"
  [[ -d "$src" ]] || return 0
  run "mkdir -p '$dst'"
  local skipped=0
  for f in "$src"/*; do
    [[ -e "$f" ]] || continue
    local base; base="$(basename "$f")"
    local target="$dst/$base"
    if [[ -e "$target" ]] && (( ! FORCE )); then
      say "SKIP $target (exists; pass --force to overwrite)"
      skipped=$((skipped+1))
      continue
    fi
    run "cp '$f' '$target'"
  done
  say "$src_subdir -> $dst (skipped=$skipped)"
}

copy_dir "rules"   "rules"
copy_dir "agents"  "agents"
copy_dir "hooks"   "hooks"
copy_dir "scripts" "scripts"

# chmod +x all hooks and scripts
if (( ! DRY_RUN )); then
  find "$CLAUDE_DIR/hooks"   -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.js' \) -exec chmod +x {} \; 2>/dev/null || true
  find "$CLAUDE_DIR/scripts" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
fi

# ---- merge settings.json --------------------------------------------------
banner "Merge settings.json"
FRAGMENT_SRC="$SELF_DIR/settings.json.fragment"
if [[ ! -f "$FRAGMENT_SRC" ]]; then
  say "ERROR: missing $FRAGMENT_SRC — aborting settings merge."
else
  # Expand __HOME__ -> actual $HOME in fragment
  FRAGMENT_RENDERED="$(mktemp)"
  trap 'rm -f "$FRAGMENT_RENDERED"' EXIT
  sed "s|__HOME__|$HOME|g" "$FRAGMENT_SRC" > "$FRAGMENT_RENDERED"

  if (( ! have_jq )); then
    say "no jq — printing rendered fragment; merge manually into $CLAUDE_DIR/settings.json"
    say ""
    cat "$FRAGMENT_RENDERED"
  elif (( DRY_RUN )); then
    say "[dry-run] would merge $FRAGMENT_RENDERED into $CLAUDE_DIR/settings.json (deduped by command)"
  else
    mkdir -p "$CLAUDE_DIR"
    if [[ ! -f "$CLAUDE_DIR/settings.json" ]]; then
      jq 'del(._comment)' "$FRAGMENT_RENDERED" > "$CLAUDE_DIR/settings.json"
      say "seeded $CLAUDE_DIR/settings.json from fragment"
    else
      tmp="$(mktemp)"
      # Merge .hooks per-event, concat arrays, dedupe by hook command string.
      jq -s '
        .[0] as $cur | .[1] as $frag |
        ($frag.hooks // {}) as $fh |
        ($cur.hooks // {}) as $ch |
        ($ch | keys + ($fh | keys) | unique) as $events |
        ($events | map({
          (.): (
            (($ch[.] // []) + ($fh[.] // []))
            | unique_by(.hooks | map(.command) | tostring)
          )
        }) | add) as $merged |
        $cur + { hooks: $merged }
      ' "$CLAUDE_DIR/settings.json" "$FRAGMENT_RENDERED" > "$tmp" && mv "$tmp" "$CLAUDE_DIR/settings.json"
      say "merged hooks into $CLAUDE_DIR/settings.json (deduped by command)"
    fi
  fi
fi

# ---- bootstrap memory dir for a project -----------------------------------
if [[ -n "$BOOTSTRAP_PROJECT" ]]; then
  banner "Bootstrap memory for $BOOTSTRAP_PROJECT"
  PROJECT_PATH="$(cd "$BOOTSTRAP_PROJECT" && pwd 2>/dev/null || true)"
  if [[ -z "$PROJECT_PATH" || ! -d "$PROJECT_PATH" ]]; then
    say "ERROR: $BOOTSTRAP_PROJECT is not a valid directory"
  else
    SLUG="-$(printf '%s' "$PROJECT_PATH" | sed -E 's|^/||; s|/|-|g')"
    MEM="$CLAUDE_DIR/projects/$SLUG/memory"
    if [[ -d "$MEM" ]]; then
      say "memory dir already exists: $MEM (skipping)"
    else
      run "mkdir -p '$MEM/meta/session_snapshots' '$MEM/user' '$MEM/feedback' '$MEM/project' '$MEM/reference' '$MEM/infrastructure' '$MEM/testing' '$MEM/frontend' '$MEM/security' '$MEM/completed'"
      run "cp '$SELF_DIR/memory-system/MEMORY.md.template' '$MEM/MEMORY.md'"
      say "memory skeleton -> $MEM"
    fi
  fi
fi

# ---- next steps -----------------------------------------------------------
banner "Next steps"
cat <<'EOF'

The user-level pieces are installed. A few external setup tasks remain:

  1. Codex auth (for the codex-reviewer agent):
       codex login                # or export OPENAI_API_KEY=...

  2. CodeRabbit auth (for the coderabbit-reviewer agent):
       coderabbit auth login
     AND install the CodeRabbit GitHub App on your repo's org/account:
       https://github.com/apps/coderabbitai

  3. (Optional) Multi-session worktree harness — installs into ONE project:
       ./project-overlay/multi-session-worktrees/install-in-project.sh /path/to/your/repo
     Add --launchd at the end for hourly idle-reaper + daily janitor (macOS).

  4. Browse rules/ — most ship as-is, but coding-style.md / security.md /
     testing.md / patterns.md / hooks.md are TypeScript/JS opinionated starter
     templates. Edit or remove the ones that don't match your stack.

  5. Restart any active Claude Code sessions to pick up the new hooks/rules.

To verify:
  - Open a fresh Claude session and ask "what rules are active?"
  - Trigger a non-trivial change and watch for the 3-vendor planning gate to fire.

EOF
