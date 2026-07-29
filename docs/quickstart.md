# Quickstart

Start here. This is the shortest path from a stock Claude Code install to a working version of this setup, ordered so the highest-value pieces land first.

You already know what skills, agents, hooks, and MCP servers are — this skips that primer.

## Before you start: what you're signing up for

The full pack assumes accounts with **five vendors** (Anthropic, OpenAI, Moonshot, Zhipu, CodeRabbit). That's the maximal version. **You do not need all five.** The gate degrades gracefully — a missing vendor shrinks the panel and says so out loud.

If you have Claude plus one other vendor, you already get most of the benefit. Going from one reviewer to two is by far the biggest jump; three-to-five is diminishing returns you can add later.

## Stage 0 — the free wins (15 minutes, no accounts)

```bash
git clone <this repo> claude-code-setup && cd claude-code-setup
./install.sh --dry-run     # read what it will do
./install.sh
```

You now have:

- **Prompt-injection guards** on every Write/Edit and every Read.
- **Context telemetry + statusline.**
- **The rules layer** — coding style, git workflow, development workflow, testing conventions.

Restart any open Claude session. Nothing above needs a login.

> `install.sh` backs up `~/.claude/settings.json` first, skips files that already exist unless you pass `--force`, and dedupes hook wiring by command string so re-running never doubles a hook.

### Prune the rules you don't want

`rules/coding-style.md`, `security.md`, `testing.md`, `patterns.md`, and `hooks.md` are opinionated TypeScript/JS starter templates. Read them; edit or delete the ones that don't match your stack. They load **every session**, so a rule you don't actually believe in is a permanent tax on both tokens and behavior.

## Stage 1 — worktree safety (10 minutes)

Do this before anything else if you ever run two Claude sessions at once.

```bash
./project-overlay/multi-session-worktrees/install-in-project.sh /path/to/your/repo
```

The failure it prevents: two sessions share one `.git/index`. Session A stages files, session B runs `git commit`, and B's commit silently swallows A's unrelated work. It's an expensive mistake and the harness makes it structurally impossible.

Read [`multi-session-worktrees.md`](multi-session-worktrees.md) — especially the two 🔴 sections on the `/tmp` wipe and macOS TCC. Both fail silently.

## Stage 2 — a second reviewer (30 minutes)

The highest-value stage. Pick **one** vendor to start; Codex is the natural first because it's the most grounded in your actual repo.

```bash
brew install codex && codex login
```

The gate now fires at three points: planning, post-implementation, and pre-commit. Read [`review-panel.md`](review-panel.md) for what each gate looks for, and for the **"what counts as non-trivial"** definition — that's what keeps the gate from firing on typos.

Try it on a real change and watch T2 fire. If it never fires, your change was trivial by the rule's definition; that's working as intended.

## Stage 3 — the rest of the panel (30 minutes)

Add vendors in whatever order matches what you're willing to pay for:

```bash
# CodeRabbit — pre-commit only (rationed CLI credits)
coderabbit auth login
# ⚠️ ALSO install the GitHub App: https://github.com/apps/coderabbitai
#    CLI auth alone is NOT enough. Without the App you get
#    "could not connect this repository to a CodeRabbit organization".

# Kimi (Moonshot) — reviewer + planner
curl -LsSf https://code.kimi.com/install.sh | bash
kimi login

# GLM (Zhipu) — reviewer + planner, needs a z.ai key
security add-generic-password -U -a "$(id -un)" -s ai-config.myproject.ZAI_API_KEY -w
```

⚠️ On that last command **`-w` must be last, with nothing after it**, so `security` prompts instead of reading your key from `argv`. See [`secrets.md`](secrets.md) — the failure mode is nasty: a flag placed after `-w` gets stored *as* the password, silently, exit 0.

Verify each leg independently before trusting the gate:

```bash
codex exec review --uncommitted                     # findings, or "no findings"
coderabbit review --uncommitted --include-untracked
~/.local/bin/kimi-review -p "say OK" < /dev/null    # expect OK, not "LLM not set"
~/.local/bin/glm-review -p "say OK"
```

That `LLM not set` check matters: unauthenticated `kimi` **exits 0**, so a broken leg looks like a passing one unless you read the output. The wrapper converts it to exit 4 — trust the wrapper, never the exit code of a bare call.

## Stage 4 — memory (ongoing payoff)

```bash
./install.sh --bootstrap-project /path/to/your/repo
export AI_MEMORY_PROJECT_ROOT="/path/to/your/repo"   # add to your shell profile
```

This doesn't pay off on day one — it pays off in week three, when Claude remembers why you rejected an approach two months ago. Read [`memory-system.md`](memory-system.md) and internalize one rule above all: **never append detail to `MEMORY.md`**. It's a router, not a store. That discipline is what keeps it working at 700+ notes.

## Stage 5 — two-assistant config hygiene (only if you also run Codex)

Skip unless you genuinely run two assistants against the same repo.

```bash
cp ai-config/sync-manifest.json.template ~/.claude/ai-config/sync-manifest.json
cp ai-config/topology.json.template      ~/.claude/ai-config/topology.json
# edit both: point default_root at your repo, prune roles you don't have

python3 ~/.claude/scripts/sync-ai-config.py --check
python3 ~/.claude/skills/ai-config-audit/scripts/audit.py
```

See [`config-audit-and-sync.md`](config-audit-and-sync.md), including the 🔴 warning that a clean audit result is indistinguishable from an audit that never ran. Prove liveness with a planted canary before believing a green result.

## Verifying the whole thing

```bash
python3 ~/.claude/skills/ai-config-audit/scripts/audit.py    # 0 = clean
```

Then in a fresh Claude session:

- Ask "what rules are active?" — you should see the rules layer.
- Make a non-trivial change and confirm T2 fires with multiple reviewers.
- Check the statusline renders.

## Things that will bite you

| Symptom | Cause |
|---|---|
| Reviewer returns a confident review of the wrong code | Passed both `-p` and piped stdin to `kimi-review`/`glm-review`. Embed the diff **in** the prompt. |
| Kimi "passes" but reviewed nothing | Unauthenticated `kimi` exits 0. Trust the wrapper's exit 4. |
| `kimi-review` exit 65 read as clean | That's **partial coverage** — some slices unreviewed. Never treat as clean. |
| CodeRabbit reports clean on a diff with new files | Missing `--include-untracked`. Untracked files are silently dropped. |
| Reviewer killed at 5 minutes | Don't. A 74KB diff can legitimately need ~15 min. The wrappers self-bound. |
| Codex "succeeds" with empty output | Run it from inside a git repo. It fails closed. |
| A wrapper's exit code looks wrong | `cmd \| tail` makes `$?` the *pipe's* status. Redirect to a file. |
| Worktree branched from stale code | The SessionStart hook doesn't fetch. Check `git rev-list --count main..origin/main`. |
| launchd reapers do nothing | macOS TCC blocks launchd-spawned bash under `~/Downloads`. Grant Full Disk Access. |
| A memory "disappeared" | It was quarantined. Grep `memory-repository/` before concluding anything. |

## What to read next

[`../README.md`](../README.md) has the full map. The two docs worth reading end-to-end are [`review-panel.md`](review-panel.md) and [`planning-by-harvest.md`](planning-by-harvest.md) — they're the substance. Everything else is plumbing that supports them.
