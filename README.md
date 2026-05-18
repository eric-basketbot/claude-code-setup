# claude-code-setup

A drop-in Claude Code customization pack. Not skills — **rules, hooks, agents, settings wiring, and a memory-system architecture** that change how Claude Code operates.

The headline pieces:

1. **3-vendor adversarial review gate** — every non-trivial change goes through Claude + Codex (OpenAI) + CodeRabbit (purpose-built review pipeline) at planning, post-implementation, and pre-commit. Cross-harness diversity catches what single-model review misses.
2. **File-based memory system** — atomic notes per topic, an auto-loaded index file, and a lifecycle hook that quarantines stale notes, rotates session logs, and snapshots conversations every 15 min so cross-session recall survives context compaction.
3. **Write-time injection guards** — Node hooks scan every Write/Edit and every Read for prompt-injection patterns (especially the kind designed to survive context compression).
4. **Multi-session worktree harness** *(optional, per-project)* — when you run multiple Claude sessions against the same repo, each gets its own auto-named git worktree, with hooks that block direct edits to canonical, manage cleanup, and prevent destructive pushes to shared branches.

## Install

```bash
git clone <this repo> claude-code-setup
cd claude-code-setup
./install.sh --dry-run        # preview every action
./install.sh                  # actually install
```

The installer:

1. Backs up `~/.claude/settings.json` first.
2. Copies `rules/`, `agents/`, `hooks/`, `scripts/` into `~/.claude/` (skips existing files unless you pass `--force`).
3. Merges the hook wiring into `~/.claude/settings.json` (deduped by command, won't add the same hook twice).
4. Optionally creates a memory skeleton for a project with `--bootstrap-project /path/to/repo`.

After install:

```bash
codex login                                            # for the codex-reviewer agent
coderabbit auth login                                  # for the coderabbit-reviewer agent
# AND install https://github.com/apps/coderabbitai on your repo's GitHub org

# Optional — per project — the multi-session worktree harness:
./project-overlay/multi-session-worktrees/install-in-project.sh /path/to/your/repo
```

Restart any active Claude Code sessions to pick up the new rules and hooks.

## What's in this repo

```
rules/                      always-on instructions Claude loads every session
├── codex-adversarial-review.md   the flagship 3-vendor review gate
├── development-workflow.md       research-first + planner + TDD + review pipeline
├── agents.md                     which subagent to use when
├── git-workflow.md, performance.md, ...

agents/                     subagents the rules call into
├── codex-reviewer.md             wraps `codex exec review`
└── coderabbit-reviewer.md        wraps `coderabbit review --plain`

hooks/                      enforced operating principles
├── memory_health_audit.py        quarantine stale memory, rotate logs (launchd)
├── session_snapshot.py           15-min rolling snapshots (UserPromptSubmit)
├── precompact_session_log.py     breadcrumb on every compact (PreCompact)
├── cc-write-injection-guard.js   block prompt-injection patterns on Write/Edit
├── cc-context-monitor.js         context-usage telemetry (PostToolUse)
├── cc-read-injection-scanner.js  scan Read results for injection (PostToolUse)
└── cc-statusline.js              statusline renderer

scripts/
└── cross-ai-review.sh            manual 3-vendor review aggregator

memory-system/              templates for the file-based memory architecture
├── MEMORY.md.template            index file Claude auto-loads each session
├── memory-tree.txt               recommended directory layout
└── README.md                     full architecture + lifecycle docs

project-overlay/
└── multi-session-worktrees/      per-project: git worktree harness
    ├── install-in-project.sh
    ├── scripts/ (12 .sh files)
    ├── CLAUDE.md.fragment        paste into your project's CLAUDE.md
    └── launchd/ (plist templates for idle-reaper + daily-janitor)

settings.json.fragment      merged into ~/.claude/settings.json
install.sh                  the user-level installer
sanitize-check.sh           pre-commit gate against project-specific leakage
docs/                       deeper writeups of each headline piece
upstream-skills.md          manifest of skills referenced but not redistributed
CREDITS.md                  attribution
LICENSE
```

## What's NOT here (and where to get it)

This repo doesn't redistribute upstream marketplace skills (ECC, Anthropic-official, gstack, plankton, bencium, etc.). See [`upstream-skills.md`](upstream-skills.md) for the install commands. The setup works fine without them — the rules and hooks are self-contained.

## License

MIT for the rules / hooks / scripts authored in this repo. See [`CREDITS.md`](CREDITS.md) for upstream attributions.
