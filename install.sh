#!/usr/bin/env bash
# install.sh — drop the user-level pieces into ~/.claude/.
# Idempotent. Re-running is safe. Use --dry-run to preview, --uninstall to reverse.
#
# What gets installed (under $HOME/.claude/):
#   rules/multi-ai-harness.md                THE SHARED CONTRACT (both hosts)
#   rules/codex-adversarial-review.md        the 5-vendor review gate procedure
#   rules/opus-fallback-implementation.md    implementer ladder on host degradation
#   rules/{development-workflow,agents,git-workflow,performance,...}.md
#   agents/{codex,coderabbit,kimi,glm}-reviewer.md   the review panel
#   agents/chatgpt-planner.md                business/strategy planning voice
#   skills/ai-config-audit/                  20-check config audit
#   ai-config/*.template                     sync manifest + topology templates
#   scripts/codex-implementation-fallback.sh the ONLY workspace-write dispatch
#   scripts/keychain-exec.sh                 Keychain -> env broker for MCP
#   scripts/sync-ai-config.py                generate Codex AGENTS.md
#   hooks/memory_health_audit.py             memory lifecycle (launchd-driven)
#   hooks/session_snapshot.py                15-min rolling session snapshots
#   hooks/precompact_session_log.py          one-line breadcrumb on every compact
#   hooks/cc-{write-injection-guard,context-monitor,read-injection-scanner,statusline}.js
#   scripts/cross-ai-review.sh               manual multi-vendor review aggregator
#   settings.json fragment merged into ~/.claude/settings.json
#
# Also installed OUTSIDE ~/.claude/:
#   wrappers/{kimi-review,glm-review,chatgpt-plan} -> ~/.local/bin/ (chmod +x)
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

# The config audit parses TOML. tomllib is stdlib on 3.11+; older interpreters
# (macOS ships 3.9) need the tomli backport.
if (( have_python3 )); then
  if ! python3 -c 'import tomllib' >/dev/null 2>&1 && ! python3 -c 'import tomli' >/dev/null 2>&1; then
    pyver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo '?')"
    say "WARN: python3 is $pyver and has no TOML parser — ai-config-audit will not run."
    say "      Fix with:  python3 -m pip install tomli    (or use Python 3.11+)"
  fi
fi

# ---- uninstall (reverse the install) -------------------------------------
if (( UNINSTALL )); then
  banner "Uninstall"
  for d in rules agents hooks scripts ai-config; do
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

copy_dir "rules"     "rules"
copy_dir "agents"    "agents"
copy_dir "hooks"     "hooks"
copy_dir "scripts"   "scripts"
copy_dir "ai-config" "ai-config"

# skills/ is nested (skills/<name>/SKILL.md + scripts/), so copy the tree wholesale
if [[ -d "$SELF_DIR/skills" ]]; then
  run "mkdir -p '$CLAUDE_DIR/skills'"
  for skill_dir in "$SELF_DIR"/skills/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    if [[ -e "$CLAUDE_DIR/skills/$skill_name" ]] && (( ! FORCE )); then
      say "SKIP $CLAUDE_DIR/skills/$skill_name (exists; pass --force to overwrite)"
      continue
    fi
    run "rm -rf '$CLAUDE_DIR/skills/$skill_name'"
    run "cp -R '$skill_dir' '$CLAUDE_DIR/skills/$skill_name'"
    say "skills/$skill_name -> $CLAUDE_DIR/skills/$skill_name"
  done
fi

# wrappers go on PATH, not under ~/.claude/
banner "Install wrappers to ~/.local/bin"
if [[ -d "$SELF_DIR/wrappers" ]]; then
  run "mkdir -p '$HOME/.local/bin'"
  for w in "$SELF_DIR"/wrappers/*; do
    [[ -f "$w" ]] || continue
    wb="$(basename "$w")"
    [[ "$wb" == "README.md" ]] && continue
    if [[ -e "$HOME/.local/bin/$wb" ]] && (( ! FORCE )); then
      say "SKIP ~/.local/bin/$wb (exists; pass --force to overwrite)"
      continue
    fi
    run "cp '$w' '$HOME/.local/bin/$wb'"
    run "chmod +x '$HOME/.local/bin/$wb'"
  done
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) say "WARN: ~/.local/bin is not on your PATH — the reviewer agents will not find the wrappers." ;;
  esac
fi

# chmod +x all hooks and scripts
if (( ! DRY_RUN )); then
  find "$CLAUDE_DIR/hooks"   -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' -o -name '*.js' \) -exec chmod +x {} \; 2>/dev/null || true
  find "$CLAUDE_DIR/scripts" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} \; 2>/dev/null || true
  find "$CLAUDE_DIR/skills"  -type f -name '*.py' -path '*/scripts/*' -exec chmod +x {} \; 2>/dev/null || true
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
        $cur
        + { hooks: $merged }
        + (if ($cur.statusLine // null) == null and ($frag.statusLine // null) != null
           then { statusLine: $frag.statusLine } else {} end)
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

The user-level pieces are installed. External setup remains — the pack degrades
gracefully, so wire up only the vendors you actually want on the panel.

  1. OpenAI / Codex (reviewer + technical planner):
       brew install codex && codex login

  2. CodeRabbit (pre-commit reviewer):
       coderabbit auth login
     AND install the GitHub App on your repo's org — CLI auth alone is NOT enough:
       https://github.com/apps/coderabbitai

  3. Kimi / Moonshot (reviewer + planner):
       curl -LsSf https://code.kimi.com/install.sh | bash
       kimi login
     GOTCHA: unauthenticated `kimi` exits 0. Trust `kimi-review`'s exit 4.

  4. GLM / Zhipu (reviewer + planner) — key goes in the macOS Keychain:
       security add-generic-password -U -a "$(id -un)" \
         -s ai-config.myproject.ZAI_API_KEY -w
     WARNING: -w MUST be the final argument with nothing after it, so `security`
     prompts you. A flag placed after -w is silently stored AS the password.

  5. Bind the memory hooks to your repo (add to your shell profile):
       export AI_MEMORY_PROJECT_ROOT="/path/to/your/repo"

  6. (Optional) Multi-session worktree harness, per project:
       ./project-overlay/multi-session-worktrees/install-in-project.sh /path/to/repo
     Add --launchd for the hourly idle-reaper + daily janitor (macOS).
     NOTE: if your repo is under ~/Downloads or ~/Documents, macOS TCC blocks the
     launchd jobs silently. Grant /bin/bash Full Disk Access, or move the repo.

  7. (Optional, two-assistant setups only) Config audit + Codex sync:
       cp ai-config/sync-manifest.json.template ~/.claude/ai-config/sync-manifest.json
       cp ai-config/topology.json.template      ~/.claude/ai-config/topology.json
       # edit both — point default_root at your repo, prune roles you don't have

  8. Review rules/ — coding-style.md, security.md, testing.md, patterns.md and
     hooks.md are opinionated TypeScript/JS starter templates. Edit or delete the
     ones that don't match your stack; they load every single session.

  9. Restart any active Claude Code sessions.

To verify:
  python3 ~/.claude/skills/ai-config-audit/scripts/audit.py     # 0 = clean
  # then in a fresh session: make a non-trivial change and watch the gate fire.

Read docs/quickstart.md for the staged adoption path.

EOF
