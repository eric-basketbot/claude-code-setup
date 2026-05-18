# Upstream skills (referenced, not redistributed)

This setup doesn't ship a bundle of skills. The rules + hooks + agents are self-contained — they work without any additional skills installed. But the original author's day-to-day Claude Code setup also includes a curated set of upstream skills. If you want a similar setup, install them yourself via Claude Code's `/plugin install` mechanism or the marketplace your skills come from.

The list below is informational. Install only the skills you actually need.

## High-value, recommended

| Skill | Source | Why |
|---|---|---|
| `using-superpowers` | obra/superpowers | Establishes how Claude finds and uses skills consistently; sets the stage for every other skill. |
| `writing-skills` | ECC / Anthropic-official | Use when creating new skills, editing existing skills, or verifying skills work before deployment. |
| `writing-plans` | ECC / Anthropic-official | Use before touching code on a multi-step task. Pairs with the planner agent. |
| `executing-plans` | ECC | Companion to writing-plans — handles execution in a separate session with review checkpoints. |
| `verification-before-completion` | ECC | Forces run-verification-before-claim-success discipline. Pairs well with the adversarial review gate. |
| `systematic-debugging` | ECC | Four-phase debugging methodology — no fix without root cause. |
| `test-driven-development` | ECC / Anthropic-official | TDD enforcer — write tests first. Pairs with the tdd-guide agent. |
| `frontend-design` | ECC / Anthropic-official | Polished, non-generic frontend code generation. |
| `dispatching-parallel-agents` | ECC | When to fan out to multiple agents in parallel vs. sequentially. |

## Stack-specific (install only what matches your stack)

- **Python**: `python-patterns`, `python-testing`, `django-patterns`, `django-tdd`, `django-security`, `django-verification`
- **TypeScript/React**: `frontend-patterns`, `composition-patterns`, `backend-patterns`, `api-design`, `coding-standards`
- **Go**: `golang-patterns`, `golang-testing`
- **C++**: `cpp-coding-standards`, `cpp-testing`
- **Java/Spring**: `springboot-patterns`, `springboot-tdd`, `springboot-security`, `springboot-verification`, `jpa-patterns`
- **Swift**: `swiftui-patterns`, `swift-concurrency-6-2`, `swift-protocol-di-testing`, `swift-actor-persistence`, `foundation-models-on-device`, `liquid-glass-design`
- **Postgres**: `postgres-patterns`, `database-migrations`
- **ClickHouse**: `clickhouse-io`
- **Docker**: `docker-patterns`

## Niche / on-demand

- `gstack` — headless-browser QA skill (50+ subcommands).
- `plankton-code-quality` — write-time formatter/linter via hooks on every Edit.
- `nanoclaw-repl` — interactive REPL for prototyping.
- `bencium-controlled-ux-designer` — UI/UX design guidance.
- `continuous-learning-v2` — instinct-based evolution observing sessions → atomic instincts → skills.
- `ralphinho-rfc-pipeline` — RFC-driven multi-agent DAG execution.
- `e2e-testing` — Playwright E2E testing patterns.

## How to install

Most of these are available through public marketplaces. Examples:

```bash
# Anthropic-official skills via /plugin
claude
# inside Claude: /plugin install <skill-name>

# Marketplace-hosted skills (URLs vary)
# Check the marketplace's documentation for the install command.
```

The exact source/marketplace for each upstream skill changes over time — when in doubt, check the skill's documentation or the marketplace it's hosted on. Don't blindly install everything; pick the ones that match your stack and workflow.

## What if I want everything the original author has?

Bundling someone else's marketplace skills into a third-party repo isn't safe (license + attribution concerns). The intentional shape of this repo is: **novel work only, pointers to everything else**. Run the upstream-skill installs yourself once, and you'll have a near-identical setup.
