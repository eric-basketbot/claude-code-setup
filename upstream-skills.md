# Upstream skills (referenced, not redistributed)

This setup doesn't bundle anyone else's skills — but the author's actual `~/.claude/skills/` directory has 85 skills installed from various marketplaces. The list below is **exactly what's installed in the author's working setup**, grouped by source, so you can install the same set yourself.

Don't blindly install everything. Pick the skills that match your stack and workflow. The rules + hooks in this repo work without any of them.

## How install works (in general)

Most of these are installable via Claude Code's `/plugin install <name>` mechanism or by cloning the source repo into `~/.claude/skills/<name>/`. Specific install commands per source are below.

---

## 1. Everything Claude Code (ECC) — 57 skills

ECC is the largest marketplace this setup pulls from. Install the marketplace's installer skill first, then pick the skills you want:

```bash
# Install configure-ecc (the marketplace's own installer skill)
# Source: https://github.com/eccskills/configure-ecc  (check upstream for current URL)
# Once installed, use it inside Claude to add the ECC skills you want.
```

The ECC skills installed in this setup:

**Agentic / orchestration / loops**
- `agent-harness-construction` — Design and optimize AI agent action spaces, tool definitions, and observation formatting
- `agentic-engineering` — Operate as an agentic engineer using eval-first execution, decomposition, and cost-aware model routing
- `ai-first-engineering` — Engineering operating model for teams where AI agents generate a large share of implementation output
- `autonomous-loops` — Patterns and architectures for autonomous Claude Code loops
- `continuous-agent-loop` — Patterns for continuous autonomous agent loops with quality gates, evals, recovery controls
- `continuous-learning-v2` — Instinct-based learning that observes sessions via hooks, creates atomic instincts
- `cost-aware-llm-pipeline` — Cost optimization patterns for LLM API usage — model routing, budget tracking, prompt caching
- `enterprise-agent-ops` — Operate long-lived agent workloads with observability, security, lifecycle management
- `eval-harness` — Formal evaluation framework for Claude Code sessions implementing eval-driven development
- `iterative-retrieval` — Pattern for progressively refining context retrieval
- `nanoclaw-repl` — Operate and extend NanoClaw v2, ECC's zero-dependency session-aware REPL
- `ralphinho-rfc-pipeline` — RFC-driven multi-agent DAG execution with quality gates, merge queues, work unit orchestration
- `strategic-compact` — Suggests manual context compaction at logical intervals
- `configure-ecc` — Interactive installer for ECC itself

**Backend / database / infrastructure**
- `api-design` — REST API design patterns: naming, status codes, pagination, filtering, errors, versioning, rate limiting
- `backend-patterns` — Backend architecture for Node.js, Express, Next.js API routes
- `clickhouse-io` — ClickHouse patterns, query optimization, analytics for high-performance analytical workloads
- `database-migrations` — Migration best practices: schema changes, data migrations, rollbacks, zero-downtime
- `deployment-patterns` — CI/CD pipelines, Docker, health checks, rollback strategies, production readiness
- `docker-patterns` — Docker + Docker Compose patterns: local dev, container security, networking, volumes
- `postgres-patterns` — Postgres query optimization, schema design, indexing, security (Supabase best practices)

**Code review / quality**
- `coding-standards` — Universal coding standards for TypeScript, JavaScript, React, Node.js
- `security-review` — Security checklist + patterns for auth, user input, secrets, API endpoints
- `security-scan` — Scan your `.claude/` config for vulnerabilities, misconfigurations, injection risks (AgentShield)
- `verification-loop` — A comprehensive verification system for Claude Code sessions
- `skill-stocktake` — Audit skills + commands for quality (Quick Scan + Full Stocktake modes)

**Frontend / UI**
- `frontend-patterns` — React, Next.js, state management, performance optimization, UI best practices
- `frontend-slides` — Create animation-rich HTML presentations from scratch or by converting PowerPoint

**Stack-specific (install only what matches your stack)**
- Python: `python-patterns`, `python-testing`, `django-patterns`, `django-tdd`, `django-security`, `django-verification`
- Go: `golang-patterns`, `golang-testing`
- C++: `cpp-coding-standards`, `cpp-testing`
- Java/Spring: `java-coding-standards`, `jpa-patterns`, `springboot-patterns`, `springboot-tdd`, `springboot-security`, `springboot-verification`
- Swift: see Apple-platform section below
- E2E: `e2e-testing` — Playwright patterns, Page Object Model, CI integration

**Content / writing / research**
- `article-writing` — Long-form content (articles, guides, tutorials, newsletter issues) in a distinctive voice
- `content-engine` — Platform-native content for X, LinkedIn, TikTok, YouTube, newsletters, multi-platform campaigns
- `content-hash-cache-pattern` — Cache expensive file processing using SHA-256 content hashes
- `investor-materials` — Pitch decks, one-pagers, investor memos, accelerator applications, financial models
- `investor-outreach` — Cold emails, intro blurbs, follow-ups, update emails for fundraising
- `market-research` — Market sizing, competitor analysis, investor due diligence, industry intelligence
- `nutrient-document-processing` — Process, convert, OCR, extract, redact, sign, fill PDFs/DOCX/etc via Nutrient DWS
- `project-guidelines-example` — Example project-specific skill template
- `regex-vs-llm-structured-text` — Decision framework for regex vs LLM when parsing structured text
- `search-first` — Research-before-coding workflow (gh search, package registries before custom code)

---

## 2. obra/superpowers — 14 skills

The "superpowers" collection by Jesse Vincent. Source: https://github.com/obra/superpowers

Install: clone the repo and copy individual skill dirs into `~/.claude/skills/`, or use whatever installer the upstream provides.

- `using-superpowers` — Establishes how to find and use skills; required by every other skill in the set
- `brainstorming` — Use before any creative work; explores user intent and requirements before implementation
- `writing-plans` — Write comprehensive implementation plans before touching code
- `executing-plans` — Execute a written plan with review checkpoints (separate session)
- `subagent-driven-development` — Execute implementation plans with independent tasks in the current session
- `dispatching-parallel-agents` — Use when facing 2+ independent tasks that can be worked on in parallel
- `finishing-a-development-branch` — Use when implementation is complete and you need to decide how to integrate
- `requesting-code-review` — Use when completing tasks, before merging, to verify work meets requirements
- `receiving-code-review` — Use when receiving code review feedback, before implementing suggestions
- `test-driven-development` — Write the test first. Watch it fail. Write minimal code to pass
- `systematic-debugging` — Four-phase debugging methodology — NO FIXES WITHOUT ROOT CAUSE FIRST
- `verification-before-completion` — Evidence before claims, always; before claiming work is done
- `writing-skills` — TDD for skills: write pressure scenarios first, then the skill, watch tests pass
- `using-git-worktrees` — Use when starting feature work that needs isolation from current workspace

---

## 3. Vercel skills — 2 skills

Source: https://github.com/vercel/skills (or wherever Vercel publishes them currently)

- `web-design-guidelines` — Review UI code for Web Interface Guidelines compliance (Vercel's design audit)
- `composition-patterns` — React composition patterns that scale (compound components, render props, context)

---

## 4. Anthropic-official — 1 skill

- `frontend-design` — Create distinctive, production-grade frontend interfaces. Avoids generic AI aesthetics

Install via Claude Code's `/plugin` mechanism or the official Anthropic skills marketplace.

---

## 5. gstack — 1 skill

Source: gstack project (check upstream for current install URL).

- `gstack` — Fast headless browser for QA testing and site dogfooding. 50+ subcommands (qa, review, design, plan, ship, dogfood, etc.)

This is a large, multi-tier skill with its own preamble system and configuration. The author has it heavily vendored locally.

---

## 6. plankton / community — 1 skill

- `plankton-code-quality` — Write-time code quality enforcement: auto-formatting, linting, and Claude-powered fixes on every file edit via hooks

---

## 7. bencium — 1 skill

- `bencium-controlled-ux-designer` — Expert UI/UX design guidance for unique, accessible interfaces

---

## 8. Sentry — 1 skill

- `sentry-cli` — Guide for using Sentry CLI from the command line (issues, events, projects, API calls, auth)

Source: Sentry's official skills (requires `sentry` binary).

---

## 9. Apple-platform skills — 6 skills

Source unclear (likely Anthropic-official or a Swift/Apple-focused marketplace). Install only if you do iOS/macOS work.

- `swiftui-patterns` — SwiftUI architecture, `@Observable` state, view composition, navigation, performance
- `swift-concurrency-6-2` — Swift 6.2 Approachable Concurrency, `@concurrent` for background offloading
- `swift-protocol-di-testing` — Protocol-based dependency injection for testable Swift code
- `swift-actor-persistence` — Thread-safe data persistence in Swift using actors
- `foundation-models-on-device` — Apple FoundationModels framework for on-device LLM (iOS 26+)
- `liquid-glass-design` — iOS 26 Liquid Glass design system for SwiftUI, UIKit, WidgetKit

---

## 10. Other (origin unclear) — 2 skills

- `ui-ux-pro-max` — Comprehensive UI/UX design intelligence (50 styles, 97 palettes, 57 font pairings, 99 UX guidelines, 25 chart types, 9 stacks). Looks like a polished marketplace skill.
- `visa-doc-translate` — Translate visa application documents (images) to English with bilingual PDF output. Niche custom skill.
- `share-setup` — Author-original. Generates a one-shot shareable markdown doc of your Claude setup. Lives in `~/.claude/skills/share-setup/`.

---

## Tldr — minimum viable setup (if you only want a few)

Start with these eight and add more later:

1. **`using-superpowers`** (obra/superpowers) — required by other obra skills
2. **`writing-plans`** + **`executing-plans`** (obra/superpowers) — the plan/execute split
3. **`test-driven-development`** (obra/superpowers) — TDD enforcer
4. **`systematic-debugging`** (obra/superpowers) — no-fix-without-root-cause discipline
5. **`verification-before-completion`** (obra/superpowers) — evidence before claims
6. **`frontend-design`** (Anthropic-official) — if you do any UI work
7. Your stack-specific patterns + testing pair (ECC) — e.g., `python-patterns` + `python-testing`

The rules and hooks in THIS repo work without any of the above. Add skills as you find friction the rules don't address.
