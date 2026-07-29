# Skills, plugins, and agents — the full installed inventory

*Snapshot: 2026-07-28. Verified against the actual install, not from memory.*

This repo ships **rules, hooks, agents, wrappers, and scripts**. It does **not** redistribute anyone else's skills. This file is the honest inventory of what's installed alongside it, grouped by source, with real install commands.

**Don't install all of it.** The working set is ~150 skills accumulated over months; most are stack-specific and irrelevant to you. The rules and hooks in this repo work with zero of them. Add skills when you hit friction the rules don't address — that's the only signal worth acting on.

> One caution before bulk-installing: every enabled skill's *description* is loaded into context so the model can decide whether to invoke it. A hundred irrelevant skills is a permanent context tax and a permanent source of wrong-skill invocations. See [Turning skills off](#turning-skills-off) — in the source setup, **63 of the installed skills are explicitly disabled**.

---

## 1. Plugins (the modern install path)

Plugins are the cleanest mechanism — versioned, updatable, and they bring their own hooks and commands.

```text
superpowers@claude-plugins-official   v6.2.0
expo@claude-plugins-official          v1.8.6
arcads@arcads                         v1.0.4
```

```bash
# inside a Claude session
/plugin install superpowers@claude-plugins-official
/plugin install expo@claude-plugins-official

/plugin marketplace add arcads-ai/skills
/plugin install arcads@arcads
```

### superpowers — the one to install first

Jesse Vincent's agentic framework, now distributed through Anthropic's official marketplace. It used to be installed from `obra/superpowers` directly — **if you have the old install, migrate**; the official one is the maintained path.

Its value is *process* skills that fire before implementation skills: `brainstorming` (explore intent before creative work), `writing-plans` / `executing-plans`, `test-driven-development`, `systematic-debugging` (no fix without a root cause), `verification-before-completion` (evidence before claiming done), `requesting-code-review` / `receiving-code-review`, `subagent-driven-development`, `dispatching-parallel-agents`, `using-git-worktrees`, `writing-skills`, `finishing-a-development-branch`.

`using-superpowers` is the entry point and is required by the others.

### expo — only if you ship React Native

EAS builds, hosting, updates, workflows, routing, native UI, upgrades. Skip entirely if you're not doing mobile.

### arcads — ad creative generation

Niche. Only relevant if you produce video/static ad creative.

⚠️ Both `expo` and `arcads` expose MCP servers needing interactive OAuth. They can't be authorized from a headless or cron session — do it in an interactive session via `/mcp`.

---

## 2. gstack — 55 skills from one repo

Garry Tan's "virtual engineering team" — the largest single source here. A git clone rather than a marketplace, and it self-updates.

```bash
git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack
```

Installed version: **1.60.1.0**. Requires Bun v1.0+ and Node.

| Group | Skills |
|---|---|
| **QA / browser** | `qa`, `qa-only`, `browse`, `connect-chrome`, `open-gstack-browser`, `setup-browser-cookies`, `scrape`, `canary`, `benchmark`, `benchmark-models` |
| **Review roles** | `review`, `plan-ceo-review`, `plan-eng-review`, `plan-design-review`, `plan-devex-review`, `design-review`, `devex-review`, `cso`, `office-hours`, `retro`, `autoplan`, `plan-tune` |
| **Ship / deploy** | `ship`, `land-and-deploy`, `setup-deploy`, `health`, `investigate` |
| **Design** | `design-shotgun`, `design-consultation`, `design-html`, `diagram`, `landing-report` |
| **Safety** | `careful`, `guard`, `freeze`, `unfreeze` |
| **Docs** | `document-generate`, `document-release`, `make-pdf`, `spec` |
| **iOS** | `ios-qa`, `ios-fix`, `ios-clean`, `ios-sync`, `ios-design-review` |
| **Context / misc** | `context-save`, `context-restore`, `learn`, `pair-agent`, `skillify`, `setup-gbrain`, `sync-gbrain`, `gstack-upgrade`, `codex` |

The QA browser daemon — a persistent headless Chromium held across tool calls — is the standout, genuinely faster than spinning up Playwright per check.

The review roles overlap conceptually with this repo's review panel but are **not** a substitute: gstack's roles are *one model wearing different hats*. That's useful perspective diversity; it is not vendor diversity, and it can't catch what a model shares with itself. Use both.

---

## 3. Everything Claude Code (ECC) — 37 skills

```bash
# inside a Claude session
/plugin marketplace add affaan-m/everything-claude-code
/plugin install everything-claude-code@affaan-m-everything-claude-code
```

Identifiable by `origin: ECC` in their frontmatter. Installed here:

- **Agentic / orchestration**: `agent-harness-construction`, `agentic-engineering`, `ai-first-engineering`, `continuous-agent-loop`, `continuous-learning-v2`, `cost-aware-llm-pipeline`, `enterprise-agent-ops`, `eval-harness`, `iterative-retrieval`, `strategic-compact`
- **Backend / infra**: `api-design`, `backend-patterns`, `database-migrations`, `deployment-patterns`, `docker-patterns`, `postgres-patterns`
- **Quality**: `coding-standards`, `security-scan`, `skill-stocktake`, `e2e-testing`
- **Stack-specific**: `python-patterns`, `python-testing`, `golang-patterns`, `golang-testing`, `swift-actor-persistence`, `swift-protocol-di-testing`
- **Frontend**: `frontend-patterns`, `frontend-slides`
- **Content / research**: `article-writing`, `content-engine`, `content-hash-cache-pattern`, `investor-materials`, `investor-outreach`, `market-research`, `nutrient-document-processing`, `regex-vs-llm-structured-text`, `search-first`

`search-first` is worth adopting even if you take nothing else: research existing libraries and prior art *before* writing custom code.

---

## 4. Marketing / growth suite — 12 skills

`ab-testing`, `ad-creative`, `ads`, `ai-seo`, `churn-prevention`, `cro`, `launch`, `pricing`, `product-marketing`, `programmatic-seo`, `seo-audit`, `makeugc-ads`

Start with `product-marketing` — it writes `.agents/product-marketing.md`, which every other skill in the group reads for product, audience, and positioning context. Without it you re-explain your product on every task.

---

## 5. Design / Stitch — 6 skills

`code-to-design`, `extract-design-md`, `generate-design`, `react-components`, `react-native`, `upload-to-stitch`

Google Stitch round-trip: extract a design system from existing frontend code, generate screens, convert back to React or React Native components. Needs a Stitch API key — store it in the Keychain and broker it (see [`docs/secrets.md`](docs/secrets.md)).

---

## 6. Vercel Labs — 2 skills

```bash
npx skills add https://github.com/vercel-labs/agent-skills --skill web-design-guidelines
npx skills add https://github.com/vercel-labs/agent-skills --skill composition-patterns
```

`web-design-guidelines` reviews UI code against 100+ accessibility/performance/UX rules. `composition-patterns` covers React composition that scales (compound components, render props, context).

---

## 7. Other third-party

| Skill | Source | Notes |
|---|---|---|
| `react-native-best-practices` | Software Mansion | New Architecture, Reanimated, Gesture Handler. Deep and current. |
| `react-native-skills` | community | General RN performance |
| `ui-ux-pro-max` | `nextlevelbuilder/ui-ux-pro-max-skill` | 67 styles, 161 palettes, 57 font pairings |
| `plankton-code-quality` | `alexfazio/plankton` | Write-time lint + auto-fix via hooks |
| `sentry-cli` | Sentry | Issues, events, projects via CLI |
| `tailwind-v4-shadcn` | community | Tailwind v4 + shadcn |
| `fixing-accessibility`, `fixing-motion-performance` | community | Targeted audit-and-fix |
| `karpathy-guidelines` | community | |
| `liquid-glass-design`, `swiftui-patterns`, `swift-concurrency-6-2`, `foundation-models-on-device` | community Apple set | iOS 26 era |

---

## 8. Author-original — what this repo actually ships

These are in this repo. Everything else above is someone else's work.

- **`ai-config-audit`** — 22 checks over both hosts' config. See [`docs/config-audit-and-sync.md`](docs/config-audit-and-sync.md).
- **Reviewer agents** — `codex-reviewer`, `coderabbit-reviewer`, `kimi-reviewer`, `glm-reviewer` (plus `gemini-reviewer`, **out of rotation**, ad-hoc only).
- **`chatgpt-planner`** — the OpenAI business/strategy planning voice. Planning only, never a reviewer.
- **Role agents** — `planner`, `architect`, `code-reviewer`, `security-reviewer`, `database-reviewer`, `python-reviewer`, `go-reviewer`, `build-error-resolver`, `go-build-resolver`, `refactor-cleaner`, `doc-updater`, `e2e-runner`, `harness-optimizer`, `loop-operator`, `chief-of-staff`.

---

## 9. Built into the harness

These ship with Claude Code — nothing to install, listed so you don't go looking: `dataviz`, `artifact-design`, `artifact-capabilities`, `update-config`, `keybindings-help`, `simplify`, `fewer-permission-prompts`, `loop`, `schedule`, `claude-api`, `run`, `security-review`, `init`.

---

## Turning skills off

`skillOverrides` in `~/.claude/settings.json` disables a skill without uninstalling it:

```json
{
  "skillOverrides": {
    "swift-concurrency-6-2": "off",
    "ios-qa": "off",
    "docker-patterns": "off"
  }
}
```

**63 of the installed skills are disabled this way in the source setup** — every iOS, Swift, Go, and Django skill, plus most of the agentic-orchestration set. They stay installed so they're one config edit away when a project needs them, and cost nothing while off.

This is the honest counterweight to a 150-skill inventory: the *installed* count is not the *active* count, and only the active count matters. Prune aggressively.

---

## Minimum viable setup

The shortest list that captures most of the value:

1. **`superpowers`** (plugin) — process discipline: brainstorm → plan → TDD → verify
2. **`search-first`** (ECC) — check for prior art before writing code
3. **`gstack`** — if you do web work; the QA browser daemon alone justifies it
4. **This repo's reviewer agents** — the actual cross-vendor gate
5. **`product-marketing`** — only if you write marketing copy

Everything else: wait for friction, then install the thing that removes it.
