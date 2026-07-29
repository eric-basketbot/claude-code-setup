# claude-code-setup

A drop-in customization pack for Claude Code. Not skills — **rules, agents, hooks, wrappers, settings wiring, a memory architecture, and a config audit** that change how the harness operates.

Everything here runs in production daily against a real codebase. Paths are genericized; nothing is aspirational.

> **Updated 2026-07-28.** The review panel grew from 3 vendors to 5, planning switched from voting to editorial harvest, and four subsystems were added (implementation fallback, config audit + Codex sync, Keychain credential broker, cross-host shared contract). See [`CHANGELOG.md`](CHANGELOG.md) for the full delta.

## The five headline pieces

1. **Five-vendor adversarial review gate.** Every non-trivial change is scrutinized by Claude + Codex (OpenAI) + Kimi (Moonshot) + GLM (Zhipu) + CodeRabbit, at three hard gates. Different weights *and* different harnesses — that combination is what catches blind spots a single model shares with itself.
2. **Planning by editorial harvest, not consensus.** Four models write *independent* plans; one host steelmans each and grafts the best pieces into one. Voting discards minority insight, and the best idea is often in the plan the others disagree with.
3. **A shared contract both hosts obey.** Claude and Codex load the same `rules/multi-ai-harness.md`, which is the single authority on panel rosters, model waterfalls, and the permission matrix. Host-specific docs defer to it on conflict, so the two assistants can't drift apart.
4. **Config audit + one-way Codex sync.** `audit.py` runs 22 checks over both hosts' rules, skills, hooks, plugins, credentials, and memory; `sync-ai-config.py` generates Codex's `AGENTS.md` from Claude-owned sources so there is exactly one place to edit a rule.
5. **Multi-session worktree harness** *(optional, per-project)*. Parallel Claude sessions each get their own auto-named git worktree, with hooks that block edits to canonical, guard shared-branch pushes, and clean up on exit.

Plus the pieces that were already here and still earn their place: file-based memory with an auto-curating lifecycle, prompt-injection guards on every Write and Read, and a Keychain broker so no MCP server ever sees a plaintext token.

## Install

```bash
git clone <this repo> claude-code-setup
cd claude-code-setup
./install.sh --dry-run        # preview every action
./install.sh                  # actually install
```

The installer backs up `~/.claude/settings.json`, copies `rules/ agents/ hooks/ scripts/ skills/ ai-config/` into `~/.claude/`, installs the `wrappers/` into `~/.local/bin/`, and merges hook wiring into settings (deduped by command, never doubled).

Then wire up the vendors you actually want — **the pack degrades gracefully, a missing vendor just shrinks the panel**:

```bash
codex login                                  # OpenAI — reviewer + technical planner
coderabbit auth login                        # CodeRabbit — pre-commit reviewer
#   ALSO install https://github.com/apps/coderabbitai on your repo's GitHub org.
#   CLI auth alone is NOT enough; without the App you get
#   "could not connect this repository to a CodeRabbit organization".
kimi login                                   # Moonshot — reviewer + planner
security add-generic-password -U -a "$(id -un)" \
  -s ai-config.myproject.ZAI_API_KEY -w      # Zhipu/GLM — see docs/secrets.md
```

⚠️ On that last command, **`-w` must be the final argument with nothing after it** so `security` prompts you twice instead of reading the key from argv. A flag placed after `-w` is silently stored *as* the password — the old `-w -U` ordering saved the literal string `-U` with exit 0, no prompt and no error.

Optional, per project:

```bash
./project-overlay/multi-session-worktrees/install-in-project.sh /path/to/your/repo
```

Restart active Claude sessions to pick up new rules and hooks. Verify with:

```bash
python3 ~/.claude/skills/ai-config-audit/scripts/audit.py
```

## What's in this repo

```text
rules/                       always-on instructions, loaded every session
├── multi-ai-harness.md          ★ THE SHARED CONTRACT — panel rosters, model
│                                  waterfalls, permission matrix, quorum table.
│                                  Loaded by BOTH Claude and Codex. Overrides
│                                  every other doc on conflict. Edit facts HERE.
├── codex-adversarial-review.md   Claude's orchestration procedure for the gates
├── opus-fallback-implementation.md  who writes code when the host model degrades
├── development-workflow.md       research-first → plan → TDD → review → commit
├── agents.md                     which subagent to use when
└── coding-style / git-workflow / hooks / patterns / performance / security / testing

agents/                      subagents the rules dispatch to
├── codex-reviewer.md             wraps `codex exec review`      (OpenAI)
├── coderabbit-reviewer.md        wraps `coderabbit review`      (AST + lint + repo context)
├── kimi-reviewer.md              wraps `kimi-review`            (Moonshot)
├── glm-reviewer.md               wraps `glm-review`             (Zhipu)
└── chatgpt-planner.md            wraps `chatgpt-plan`  — PLANNING ONLY, never a reviewer

wrappers/                    the read-only harnesses those agents call
├── kimi-review                   runs Kimi in a disposable worktree; size-scaled
│                                 timeouts + slice-on-timeout recovery
├── glm-review                    runs `claude` against z.ai's Anthropic-compatible
│                                 endpoint; read-only via tool allowlist + external cwd
└── chatgpt-plan                  business/strategy planning voice on the ChatGPT
                                  subscription (not the metered platform API)

scripts/
├── cross-ai-review.sh            manual aggregator — all vendors, one diff
├── codex-implementation-fallback.sh   the ONLY sanctioned workspace-write dispatch
├── keychain-exec.sh              allowlisted Keychain → env broker for MCP servers
└── sync-ai-config.py             generate Codex AGENTS.md from Claude-owned sources

skills/ai-config-audit/      22 checks across both hosts; report-only, never
                             emits a credential value

ai-config/                   templates for the sync manifest + topology graph

hooks/
├── memory_health_audit.py        quarantine stale memory, rotate logs (launchd)
├── session_snapshot.py           rolling snapshots     (UserPromptSubmit)
├── precompact_session_log.py     breadcrumb per compact (PreCompact)
├── cc-write-injection-guard.js   block injection patterns on Write/Edit
├── cc-read-injection-scanner.js  scan Read results for injection (PostToolUse)
├── cc-context-monitor.js         context-usage telemetry (PostToolUse)
└── cc-statusline.js              statusline renderer

memory-system/               templates for the router-style memory architecture
project-overlay/             per-project: the multi-session worktree harness
docs/                        deeper writeups — start with docs/quickstart.md
upstream-skills.md           the ~150 skills installed but not redistributed
```

## Read next

| If you want… | Read |
|---|---|
| A day-one install path | [`docs/quickstart.md`](docs/quickstart.md) |
| How the three gates actually fire | [`docs/review-panel.md`](docs/review-panel.md) |
| Why planning harvests instead of votes | [`docs/planning-by-harvest.md`](docs/planning-by-harvest.md) |
| What happens when the host model degrades | [`docs/implementation-fallback.md`](docs/implementation-fallback.md) |
| Keeping Claude and Codex from drifting apart | [`docs/config-audit-and-sync.md`](docs/config-audit-and-sync.md) |
| Where credentials live and why | [`docs/secrets.md`](docs/secrets.md) |
| The memory architecture | [`docs/memory-system.md`](docs/memory-system.md) |
| Parallel sessions on one repo | [`docs/multi-session-worktrees.md`](docs/multi-session-worktrees.md) |
| Which skills and plugins are installed | [`upstream-skills.md`](upstream-skills.md) |

## Adopt it in pieces

The pack is deliberately separable. In rough order of value-per-minute-of-setup:

1. **Worktree harness** — costs nothing, blocks the most expensive class of mistake (one session committing another's staged work).
2. **The review gate with whatever vendors you already pay for.** Two vendors beats one; five is better but not required. Start with Claude + Codex.
3. **Injection guards** — two hook files, no configuration.
4. **Memory system** — pays off after a few weeks, not on day one.
5. **Config audit + Codex sync** — only worth it once you actually run two assistants.

## License

MIT for everything authored here. See [`CREDITS.md`](CREDITS.md) for upstream attributions, and [`upstream-skills.md`](upstream-skills.md) for skills referenced but not redistributed.
