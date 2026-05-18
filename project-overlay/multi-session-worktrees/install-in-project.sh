#!/usr/bin/env bash
# Install the multi-session worktree harness into a target project.
#
# Usage:
#   ./install-in-project.sh /path/to/your/project
#   ./install-in-project.sh /path/to/your/project --launchd   (also install launchd jobs)
#   ./install-in-project.sh /path/to/your/project --dry-run   (print actions, no changes)
#
# What it does:
#   1. Copies scripts/ into <project>/scripts/claude-hooks/
#   2. Prints the CLAUDE.md fragment for you to paste into <project>/CLAUDE.md
#   3. Wires the four hooks (SessionStart, PreToolUse, SessionEnd) into Claude
#      Code's per-project settings at <project>/.claude/settings.local.json
#   4. With --launchd, substitutes the plist templates with your project paths
#      and loads them via launchctl. macOS only.
#
# Idempotent: safe to re-run. Use --uninstall to reverse.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
INSTALL_LAUNCHD=0
UNINSTALL=0
PROJECT_DIR=""

while (( $# > 0 )); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --launchd) INSTALL_LAUNCHD=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *) PROJECT_DIR="$1"; shift ;;
  esac
done

if [[ -z "$PROJECT_DIR" ]]; then
  echo "ERROR: missing project path. Usage: $0 /path/to/project [--launchd] [--dry-run]" >&2
  exit 2
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  echo "ERROR: $PROJECT_DIR is not a git repo (no .git dir found)" >&2
  exit 2
fi

PROJECT_SLUG="$(basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -E 's/^-+|-+$//g')"
[[ -z "$PROJECT_SLUG" ]] && PROJECT_SLUG="claude-wt"
HOOKS_DIR="$PROJECT_DIR/scripts/claude-hooks"
SETTINGS_FILE="$PROJECT_DIR/.claude/settings.local.json"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/.claude/logs"

say() { printf '  %s\n' "$*"; }
run() {
  if (( DRY_RUN )); then
    say "[dry-run] $*"
  else
    eval "$@"
  fi
}

if (( UNINSTALL )); then
  echo "Uninstalling worktree harness from $PROJECT_DIR (slug=$PROJECT_SLUG)..."
  run "rm -rf '$HOOKS_DIR'"
  for label in "com.example.${PROJECT_SLUG}.worktree-idle-reaper" "com.example.${PROJECT_SLUG}.worktree-daily-janitor"; do
    plist="$LAUNCH_AGENTS/${label}.plist"
    if [[ -f "$plist" ]]; then
      run "launchctl unload '$plist' 2>/dev/null || true"
      run "rm -f '$plist'"
    fi
  done
  echo "Done. Manually remove the worktree section from $PROJECT_DIR/CLAUDE.md and the hooks block from $SETTINGS_FILE."
  exit 0
fi

echo "Installing worktree harness into $PROJECT_DIR (slug=$PROJECT_SLUG)..."

# 1. Copy scripts
run "mkdir -p '$HOOKS_DIR'"
for f in "$SELF_DIR"/scripts/*.sh; do
  base="$(basename "$f")"
  run "cp '$f' '$HOOKS_DIR/$base'"
  run "chmod +x '$HOOKS_DIR/$base'"
done
if [[ -f "$SELF_DIR/scripts/README.md" ]]; then
  run "cp '$SELF_DIR/scripts/README.md' '$HOOKS_DIR/README.md'"
fi
say "scripts -> $HOOKS_DIR/"

# 2. CLAUDE.md fragment
echo ""
echo "  ---- COPY THIS INTO $PROJECT_DIR/CLAUDE.md ----"
sed "s/<your-project-root>/$(echo "$PROJECT_DIR" | sed 's:/:\\/:g')/g; s/\${PROJECT_SLUG}/$PROJECT_SLUG/g" "$SELF_DIR/CLAUDE.md.fragment"
echo "  ---- END ----"
echo ""

# 3. Wire hooks into the project's .claude/settings.local.json
mkdir -p "$(dirname "$SETTINGS_FILE")" 2>/dev/null || true
HOOKS_JSON=$(cat <<EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash $HOOKS_DIR/auto-worktree.sh", "timeout": 10 }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "bash $HOOKS_DIR/track-git-cwd.sh", "timeout": 5 }] },
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "bash $HOOKS_DIR/check-remote-push.sh", "timeout": 5 }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "bash $HOOKS_DIR/cleanup-on-session-end.sh", "timeout": 15 }] }
    ]
  }
}
EOF
)

if [[ -f "$SETTINGS_FILE" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "  WARN: jq not found — printing fragment for manual merge into $SETTINGS_FILE:"
    echo "$HOOKS_JSON"
  else
    if (( DRY_RUN )); then
      say "[dry-run] would merge hooks into $SETTINGS_FILE via jq"
    else
      tmp="$(mktemp)"
      jq -s '.[0] * .[1]' "$SETTINGS_FILE" <(printf '%s' "$HOOKS_JSON") > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
      say "merged hooks -> $SETTINGS_FILE"
    fi
  fi
else
  if (( DRY_RUN )); then
    say "[dry-run] would write $SETTINGS_FILE"
  else
    printf '%s\n' "$HOOKS_JSON" > "$SETTINGS_FILE"
    say "wrote $SETTINGS_FILE"
  fi
fi

# 4. launchd (optional, macOS only)
if (( INSTALL_LAUNCHD )); then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "  WARN: --launchd only works on macOS; skipping."
  else
    run "mkdir -p '$LAUNCH_AGENTS' '$LOG_DIR'"
    for kind in "idle-reaper" "daily-janitor"; do
      label="com.example.${PROJECT_SLUG}.worktree-${kind}"
      tmpl="$SELF_DIR/launchd/com.example.worktree-${kind}.plist.template"
      out="$LAUNCH_AGENTS/${label}.plist"
      script_path="$HOOKS_DIR/${kind}.sh"
      [[ -f "$tmpl" ]] || { echo "  WARN: template missing $tmpl"; continue; }
      if (( DRY_RUN )); then
        say "[dry-run] would render $tmpl -> $out (label=$label, script=$script_path)"
      else
        sed -e "s|@@LABEL@@|$label|g" \
            -e "s|@@SCRIPT_PATH@@|$script_path|g" \
            -e "s|@@STDOUT_LOG@@|$LOG_DIR/${PROJECT_SLUG}-${kind}.log|g" \
            -e "s|@@STDERR_LOG@@|$LOG_DIR/${PROJECT_SLUG}-${kind}.err|g" \
            "$tmpl" > "$out"
        launchctl unload "$out" 2>/dev/null || true
        launchctl load "$out"
        say "launchd loaded: $label"
      fi
    done
  fi
fi

echo ""
echo "DONE. Next steps:"
echo "  1. Paste the CLAUDE.md fragment above into $PROJECT_DIR/CLAUDE.md."
echo "  2. Start a new Claude session in $PROJECT_DIR — auto-worktree should fire."
echo "  3. Run: $HOOKS_DIR/sessions-status.sh   (verify the harness is alive)"
if (( ! INSTALL_LAUNCHD )); then
  echo "  4. Optional: re-run with --launchd to enable hourly idle-reaper + daily janitor."
fi
