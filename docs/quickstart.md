# Quickstart

5-minute path from clone to first working session.

## 1. Install (1 min)

```bash
git clone <this-repo> claude-code-setup
cd claude-code-setup
./install.sh --dry-run            # preview every action — read the output
./install.sh                      # actually install
```

The installer:
- Backs up `~/.claude/settings.json` first.
- Copies `rules/`, `agents/`, `hooks/`, `scripts/` into `~/.claude/`.
- Merges hook wiring into `~/.claude/settings.json` (deduped, won't double-add).
- Optionally creates a memory dir for a specific project (`--bootstrap-project /path/to/repo`).

`--force` overwrites existing files. `--uninstall` reverses the install (keeps backups).

## 2. Auth the reviewers (3 min)

The 3-vendor review gate needs Codex and CodeRabbit set up. Both have free/trial tiers.

```bash
# Codex (OpenAI)
codex login                       # opens browser
# OR
export OPENAI_API_KEY=sk-...      # alternative

# CodeRabbit
coderabbit auth login             # opens browser
```

CodeRabbit also requires the **GitHub App** to be installed on the org/account that owns your repo:

1. Go to https://github.com/apps/coderabbitai
2. Install on your personal account or org
3. Grant access to the specific repo you'll work in

Without the GitHub App, `coderabbit review --plain --type uncommitted` returns "could not connect this repository to a CodeRabbit organization." Until that's fixed, the gate degrades to Codex-only.

## 3. Verify the install (1 min)

Start a Claude Code session in a project directory:

```bash
cd /path/to/some-project
claude
```

In the session, ask:

> What rules are loaded?

You should see references to `codex-adversarial-review`, `development-workflow`, etc. (the rules from `~/.claude/rules/`).

To verify the review gate fires, ask Claude to make a non-trivial change (touches 2+ files, schema change, or auth-adjacent). Watch for the 3-vendor planning gate — Claude should dispatch Codex and CodeRabbit in parallel before proposing a plan.

## 4. Optional: project-level worktree harness

If you run multiple Claude Code sessions against the same repo, enable the worktree harness:

```bash
./project-overlay/multi-session-worktrees/install-in-project.sh /path/to/your/repo
# Add --launchd at the end to enable hourly idle-reaper + daily janitor (macOS).
```

After install, paste the printed `CLAUDE.md` fragment into your project's `CLAUDE.md`. Restart any open Claude sessions — auto-worktree will fire on the next start.

## 5. (Optional) Bootstrap the memory system for a project

```bash
./install.sh --bootstrap-project /path/to/your/repo
```

Creates `~/.claude/projects/<slug>/memory/` with the standard directory layout and a stub `MEMORY.md`. From there, you (or Claude) add atomic notes as work happens. The audit hook (`memory_health_audit.py`) keeps the dir clean over time.

## Troubleshooting

**Hooks don't fire.** Check `~/.claude/settings.json` for the merged `hooks` entries. If they're missing, re-run `./install.sh --force`. If they're present but not firing, restart any open Claude Code sessions.

**Codex / CodeRabbit "command not found".** Install the CLIs:
- Codex: https://github.com/openai/codex
- CodeRabbit: https://www.coderabbit.ai/cli

**Settings merge failed.** Install `jq` (`brew install jq` on macOS) and re-run. Without `jq`, the installer prints the fragment for manual merge.

**Python hooks fail.** They require Python 3.9+. Check `python3 --version`.

**Memory hook can't find the project.** It auto-detects the most-recent project under `~/.claude/projects/` if no env var is set. Override with `CLAUDE_MEMORY_PROJECT_DIR=~/.claude/projects/<slug>` or pass `--project-dir` to the script.
