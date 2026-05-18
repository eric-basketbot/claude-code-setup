# Upstream skills (referenced, not redistributed)

This setup doesn't bundle anyone else's skills — but the author's actual `~/.claude/skills/` directory has 85 skills installed from various marketplaces. The list below is **exactly what's installed in the author's working setup**, grouped by source, with copy-paste install commands.

Don't blindly install everything. Pick the skills that match your stack and workflow. The rules + hooks in **this** repo work without any of them.

> All install commands assume Claude Code is installed (`claude` on your PATH) and you're inside any project directory. The `/plugin` and `/plugin marketplace` commands run inside a Claude session.

---

## 1. Everything Claude Code (ECC) — 57 skills

**Source**: <https://github.com/affaan-m/everything-claude-code> — agent harness performance optimization system. Anthropic Hackathon winner. 47 agents + 181 skills.

**Install the whole marketplace**:

```
# Inside a Claude session:
/plugin marketplace add affaan-m/everything-claude-code
/plugin install everything-claude-code@affaan-m-everything-claude-code
```

Or use ECC's `configure-ecc` skill (which the install above ships) to pick individual skills.

**Skills from ECC installed in the author's setup**:

Agentic / orchestration / loops:
- `agent-harness-construction`, `agentic-engineering`, `ai-first-engineering`, `autonomous-loops`, `continuous-agent-loop`, `continuous-learning-v2`, `cost-aware-llm-pipeline`, `enterprise-agent-ops`, `eval-harness`, `iterative-retrieval`, `nanoclaw-repl`, `ralphinho-rfc-pipeline`, `strategic-compact`, `configure-ecc`

Backend / database / infrastructure:
- `api-design`, `backend-patterns`, `clickhouse-io`, `database-migrations`, `deployment-patterns`, `docker-patterns`, `postgres-patterns`

Code review / quality:
- `coding-standards`, `security-review`, `security-scan`, `verification-loop`, `skill-stocktake`

Frontend / UI (ECC's):
- `frontend-patterns`, `frontend-slides`

Stack-specific (install only what matches yours):
- Python: `python-patterns`, `python-testing`, `django-patterns`, `django-tdd`, `django-security`, `django-verification`
- Go: `golang-patterns`, `golang-testing`
- C++: `cpp-coding-standards`, `cpp-testing`
- Java/Spring: `java-coding-standards`, `jpa-patterns`, `springboot-patterns`, `springboot-tdd`, `springboot-security`, `springboot-verification`
- E2E: `e2e-testing` (Playwright)

Content / writing / research:
- `article-writing`, `content-engine`, `content-hash-cache-pattern`, `investor-materials`, `investor-outreach`, `market-research`, `nutrient-document-processing`, `project-guidelines-example`, `regex-vs-llm-structured-text`, `search-first`

---

## 2. obra/superpowers — 14 skills

**Source**: <https://github.com/obra/superpowers> — Jesse Vincent's agentic skills framework. The most-starred Claude Code plugin (90K+ stars).

**Install**:

```
# Inside a Claude session:
/plugin marketplace add obra/superpowers
/plugin install superpowers@obra-superpowers
```

**Skills from superpowers installed in the author's setup**:

- `using-superpowers` — establishes how to find and use skills (required by other obra skills)
- `brainstorming` — explore intent before any creative work
- `writing-plans` / `executing-plans` — plan/execute split
- `subagent-driven-development` — execute plans via subagents in the current session
- `dispatching-parallel-agents` — when to fan out 2+ independent tasks in parallel
- `finishing-a-development-branch` — decide how to integrate completed work
- `requesting-code-review` / `receiving-code-review` — code review etiquette on both sides
- `test-driven-development` — write the test first, watch it fail, write minimal code
- `systematic-debugging` — four-phase debugging; no fix without root cause
- `verification-before-completion` — evidence before claiming work is done
- `writing-skills` — TDD applied to skill authoring
- `using-git-worktrees` — feature work isolation via worktrees

---

## 3. Vercel-Labs agent-skills — 2 skills

**Source**: <https://github.com/vercel-labs/agent-skills> — Vercel's official collection. Open standard, works in Claude Code, Codex CLI, Gemini CLI, Cursor, Copilot CLI.

**Install individual skills**:

```bash
# From any shell (not inside Claude):
npx skills add https://github.com/vercel-labs/agent-skills --skill web-design-guidelines
npx skills add https://github.com/vercel-labs/agent-skills --skill composition-patterns
```

- `web-design-guidelines` — Review UI code against 100+ accessibility / performance / UX rules
- `composition-patterns` (upstream name: `vercel-composition-patterns`) — React composition patterns that scale (compound components, render props, context)

---

## 4. Anthropic-official — 1 skill

**Source**: <https://github.com/anthropics/claude-code/tree/main/plugins/frontend-design> (auto-available in the `claude-plugins-official` marketplace).

**Install**:

```
# Inside a Claude session:
/plugin install frontend-design@claude-plugins-official
```

- `frontend-design` — Create production-grade frontend interfaces that avoid generic AI aesthetics

---

## 5. gstack (Garry Tan) — 1 skill

**Source**: <https://github.com/garrytan/gstack> — turns Claude Code into a virtual engineering team (CEO, Designer, Eng Manager, Release Manager, QA Lead, Security Officer). Requires Bun v1.0+ and Node.js.

**Install**:

```bash
git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack
```

- `gstack` — Fast headless-browser QA + 23 opinionated workflow slash commands (/qa, /qa-only, /browse, /review, /ship, etc.). Maintains a persistent headless Chromium daemon across tool calls.

---

## 6. plankton (alexfazio) — 1 skill

**Source**: <https://github.com/alexfazio/plankton> — write-time code quality enforcement. Every file edit triggers Rust-based linters + dedicated Claude subprocesses to fix violations.

**Install**:

```bash
git clone https://github.com/alexfazio/plankton.git ~/.claude/skills/plankton-code-quality
```

(Check the upstream README for the latest install command — may have moved to a marketplace.)

- `plankton-code-quality` — Auto-format + lint + Claude-powered fixes on every Write/Edit, via hooks

---

## 7. bencium-marketplace — 1 skill

**Source**: <https://github.com/bencium/bencium-marketplace> — 13 design / architecture / productivity skills. Each UX skill ships with 28KB+ of reference material (accessibility, responsive, motion, design systems).

**Install one or all**:

```bash
# List all skills available:
npx skills add bencium/bencium-marketplace --list

# Install the one the author uses:
npx skills add bencium/bencium-marketplace -g --skill bencium-controlled-ux-designer
```

- `bencium-controlled-ux-designer` — UX guidance prioritizing consistency, control, and adherence to standards (vs. its sibling `bencium-innovative-ux-designer`, which is the bold/experimental variant)

---

## 8. Sentry — 1 skill

**Source**: Sentry's official skill (requires `sentry` CLI binary). Check <https://sentry.io> for the current install URL.

- `sentry-cli` — Guide for using Sentry CLI: issues, events, projects, API calls, auth

---

## 9. ui-ux-pro-max (nextlevelbuilder) — 1 skill

**Source**: <https://github.com/nextlevelbuilder/ui-ux-pro-max-skill> — design intelligence with 67 styles / 161 palettes / 57 font pairings / 99 UX guidelines / 25 chart types / 16 stacks.

**Install**:

```
# Inside a Claude session:
/plugin marketplace add nextlevelbuilder/ui-ux-pro-max-skill
/plugin install ui-ux-pro-max@ui-ux-pro-max-skill
```

Or CLI: `uipro init --ai claude`

- `ui-ux-pro-max` — Activates on UI/UX requests; includes a "Design System Generator" reasoning engine

---

## 10. Apple-platform — 6 skills (source unclear)

These all live in `~/.claude/skills/` but don't carry an `origin:` field. They look like a community Swift collection or are sub-skills of an ECC bundle. Check the relevant skill's `SKILL.md` for current install info, or try the ECC marketplace first.

- `swiftui-patterns` — SwiftUI architecture, `@Observable`, navigation, performance
- `swift-concurrency-6-2` — Swift 6.2 Approachable Concurrency, `@concurrent`
- `swift-protocol-di-testing` — Protocol-based DI for testable Swift
- `swift-actor-persistence` — Thread-safe persistence using actors
- `foundation-models-on-device` — Apple FoundationModels framework (iOS 26+)
- `liquid-glass-design` — iOS 26 Liquid Glass design system (SwiftUI / UIKit / WidgetKit)

---

## 11. Other / custom

- `visa-doc-translate` — Niche: translate visa application documents (images) into bilingual PDFs. Custom-looking, no clear upstream — may be author-original or a one-off marketplace skill.
- `share-setup` — Custom local skill (lives in `~/.claude/skills/share-setup/`) that exports a setup doc. Generic enough that it's not BB-specific.

---

## Tldr — minimum viable setup

If you only want 8 skills (instead of all 85), start here:

1. **`using-superpowers`** (obra) — required by other superpowers skills
2. **`writing-plans`** + **`executing-plans`** (obra) — the plan/execute split
3. **`test-driven-development`** (obra) — TDD enforcer
4. **`systematic-debugging`** (obra) — no fix without root cause
5. **`verification-before-completion`** (obra) — evidence before claims
6. **`frontend-design`** (Anthropic-official) — if you do any UI work
7. **`configure-ecc`** (ECC) — the marketplace installer for adding more ECC skills as you find friction

The rules + hooks in **this** repo work without any of the above. Add skills as you find friction the rules don't address.
