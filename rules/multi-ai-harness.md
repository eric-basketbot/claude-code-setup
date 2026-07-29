# Multi-AI Harness Contract (shared: Claude + Codex)

<!-- contract-id: multi-ai-harness-v2 -->
<!-- Single runtime source for panel rosters, engine ladders, wrapper paths, and
quorum policy. Both hosts load it every session (Claude via rules/*.md, Codex via
the generated AGENTS.md). Host-specific orchestration PROCEDURES live in
codex-adversarial-review.md (Claude) and ~/.codex/skills/adversarial-review/
(Codex); both must reference this contract-id and defer to this file on any
conflict. Bump the contract-id only on STRUCTURAL change — ordinary roster/model
churn edits this file's content and follows the churn checklist at the bottom. -->

## Panels per trigger

| Gate | Panel | Notes |
|---|---|---|
| **T1 planning** | Claude + exactly ONE OpenAI voice + Kimi + GLM | Independent plans; the ACTIVE HOST session is the editor (steelmans + HARVESTS — not a vote; minority insight survives; when Codex is the host, Claude is an outside voice). Forks → user. CodeRabbit excluded (review-only harness). |
| **T2 post-implementation** | Claude + Codex + Kimi + GLM | Symmetric — all scrutinize the same diff. CodeRabbit excluded (CLI credits rationed). |
| **T3 pre-commit** | Claude + Codex + CodeRabbit + Kimi + GLM | Final gate on the exact diff about to land. |

- **OpenAI = one brain, two harnesses**: Codex (`gpt-5.6-sol`, technical/repo, grounded) vs ChatGPT (business/strategy/writing). Never both on one plan; never counted as two opinions. ChatGPT is NEVER a reviewer.
- **Gemini**: NEVER in any gate (removed 2026-07-17). Ad-hoc only by explicit user request. Sanctioned utility roles: cheap batch LLM (Flash-Lite) and cheap image generation (Flash tier) — generation utility, not judgment.

## Authored-diff advisory rule

Whoever IMPLEMENTED the diff reviews it advisory-only: excluded from convergence
counts and the failure math. Mixed authorship counts as authored. Recompute
quorum from the remaining ELIGIBLE panel: a majority (more than half) failing =
STOP; fewer = PARTIALLY MET (user decides). Record "authored by: <engine>" in
handoffs/summaries so this survives context compaction.

| Example | Eligible N | PARTIALLY MET | STOP |
|---|---|---|---|
| Codex-authored T2 | 3 (Claude+Kimi+GLM) | 1 fails | 2 fail |
| Codex-authored T3 | 4 (+CodeRabbit) | 1–2 fail | 3 fail |
| Kimi-authored T2 | 3 (Claude+GLM+Codex*) | 1 fails | 2 fail |
| Normal T2 | 4 | 1–2 fail | 3 fail |
| Normal T3 | 5 | 1–2 fail | 3 fail |

*Usage caps are time-boxed: Codex can usually review a Kimi-authored diff even
if it was capped at implementation time.

## Permission matrix (never weaken)

| Role | Tool | Mode |
|---|---|---|
| Codex planning | `codex exec --sandbox read-only` | read-only (workspace-write at planning makes it implement instead of propose) |
| Codex review | `codex exec review` (via codex-reviewer) | read-only |
| Kimi planning/review | `~/.local/bin/kimi-review` | read-only (disposable-worktree isolation) |
| GLM planning/review | `~/.local/bin/glm-review` | read-only (tool allowlist + external cwd) |
| CodeRabbit review | `/opt/homebrew/bin/coderabbit review` (plain is the default since 0.7.0) | review-only |
| ChatGPT planning | `~/.local/bin/chatgpt-plan` | no tools |
| **Implementation (fallback only)** | `~/.claude/scripts/codex-implementation-fallback.sh` | workspace-write (Codex) / headless kimi — ONLY via this wrapper |

`--sandbox workspace-write` and bare headless `kimi` are permitted ONLY through
the implementation-fallback wrapper. Never `danger-full-access` or any bypass flag.

## Engines, models, waterfalls

- **Codex** at `~/.npm-global/bin/codex`, model `gpt-5.6-sol` (CLI 0.145.0 as of
  2026-07-25). REVIEW waterfall: sol → retry once `-m gpt-5.5` → stop. Exit 137 =
  transient memory pressure, retry once. Heredoc-to-stdin hangs codex — prompt as
  argv + `< /dev/null`.
  ⚠️ **Must run inside a trusted git repo.** From a non-repo dir (e.g. `/tmp`) it
  aborts with `Not inside a trusted directory and --skip-git-repo-check was not
  specified`. Verified 2026-07-25: this **fails CLOSED — exit 1, empty stdout**,
  so it can't be mistaken for a clean review (unlike the unauthenticated-Kimi
  `LLM not set` + exit 0 trap). Gates always run from a repo root, so they're
  unaffected; `cd` to the repo (or pass `--skip-git-repo-check`) for ad-hoc runs.
  ⚠️ When checking any wrapper's exit code, never do `cmd | tail`— `$?` is then
  the PIPE's status, not the tool's. Redirect to a file and test `$?` directly.
- **IMPLEMENTATION ladder** (Opus-fallback, enforced by the wrapper):
  sol → **Kimi managed (subscription + native Extra Usage)** → **Kimi paid Open
  Platform API (`kimi-k3`)** → `gpt-5.5` → orchestrator implements and reports
  the degradation (wrapper exit 6). The paid rung runs ONLY after an explicit
  managed-quota exhaustion response and a Keychain key is available; ordinary
  network/rate-limit/tool failures never authorize billing. Rung changes only on an UNTOUCHED
  workspace; partial edits stop the ladder. Every rung gets one exit-137 retry.
  Kimi rung has no OS sandbox — containment is the sentinel + rung constraints
  (no installs/builds, no writes through the worktree's canonical-pointing
  symlinks), the wrapper's git-state guard, and worktree isolation. ACCEPTED
  RESIDUAL (user-approved 2026-07-18): a misbehaving Kimi could write outside
  the worktree; the engine is trusted-but-fallible, malicious-engine is out of
  threat model, and the rung is exceedingly rare.
- **Kimi** at `~/.local/bin/kimi` (review via `kimi-review`). Models (Kimi Code
  plan): ⚠️ as of 2026-07-25 `~/.kimi/config.toml` has
  **`default_model = "kimi-code/k3"`** — so review AND the implementation rung
  both run K3 unless pinned. Implementation rung override via `$KIMI_IMPL_MODEL`.
  ⚠️ The CLI needs the NAMESPACED id — bare `k3` / `kimi-for-coding` fail as
  `LLM not set` (looks like an auth error); `kimi-review` now validates `--model`
  against config.toml and exits 2 with the valid list instead.
  Avoid `kimi-for-coding-highspeed` by default (same ability, 3× quota).
  Keep Thinking ON (K3/K2.7 without it silently route to K2.6). The managed
  Kimi Code account spends native Extra Usage automatically after subscription
  quota. On exact exhaustion, `kimi-review` retries once against the separate,
  paid Open Platform `kimi-k3` endpoint using the key from macOS Keychain service
  `ai-config.kimi.MOONSHOT_API_KEY`; the paid rung uses the native
  `~/.kimi-code/bin/kimi` because the legacy CLI retains managed OAuth when its
  endpoint is overridden. It announces the billed source. There is no
  paid retry for generic errors or rolling rate limits. Unauth gotcha: prints
  `LLM not set` and exits 0.
  **Large-diff behavior (measured 2026-07-25, all on K3): a TIME problem, not a
  model problem.** 10KB ≈ 4min; 30KB timed out at 420s once and finished in 388s
  the next run; 74KB gave 0 bytes at 600s but a full review at 900s. `kimi-review`
  now scales the default timeout by prompt size (600/900/1200s) and, on timeout,
  retries by SLICING the diff on `diff --git` boundaries — sliced output is marked
  `===== SLICE n/N =====` and is DEGRADED (no cross-file reasoning); report that
  to the gate. Do not pin a short `--timeout`; that was the old failure.
  ⚠️ **`kimi-review` exit 65 = PARTIAL COVERAGE** (slicing recovered only some
  slices; output opens with a `KIMI REVIEW COVERAGE: n of N` + `INCOMPLETE`
  banner). Treat that leg as DEGRADED / PARTIALLY MET — **never as a clean
  review**; no-findings on a partial run is not evidence of absence. Exit 0 means
  every slice was reviewed.
- ⚠️ **`kimi-review` and `glm-review`: `-p` and piped stdin are MUTUALLY
  EXCLUSIVE.** There is no separate diff channel — embed the diff IN the prompt.
  Both wrappers silently DISCARDED the pipe when `-p` was present (fixed
  2026-07-25; now exit 2), which produced confident reviews of the WRONG code.
- **GLM** via `~/.local/bin/glm-review`, default `glm-5.2` (per-prompt billing —
  strongest costs the same). LARGE scopes: pin `--model glm-4.7` or split the
  scope (5.2 observed hanging). No waterfall. **Key lives in the macOS Keychain**
  (service `ai-config.<project>.ZAI_API_KEY`) as of 2026-07-25 — `glm-review`
  reads it directly; `$ZAI_API_KEY`/`$ZAI_AUTH_TOKEN` still win if exported.
  The old plaintext `export` in `~/.zshrc` tripped the audit's
  `security.config_files` check and is gone. Re-store after a rotation with
  `security add-generic-password -U -a "$(id -un)" -s ai-config.<project>.ZAI_API_KEY -w`
  — **`-w` MUST be the final argument with nothing after it**, so `security`
  prompts (twice) and the key stays out of argv and shell history. ⚠️ A flag
  placed after `-w` is silently swallowed AS the password: the old `-w -U`
  ordering stored the literal string `-U`, exit 0, no prompt, no error.
  Never in chat.
- **CodeRabbit**: server-side model, no selector; CLI credits rationed to T3.
- **Claude orchestrator**: Fable 5. On fallback (normally Opus) the
  implementation ladder applies — see `opus-fallback-implementation.md`.

## Hallucination policy

Grep-verify every finding (cited file/symbol/line) before treating it as real.
A verified fabrication → append to
`/tmp/ai-reviewer-hallucinations-$(basename "$(git rev-parse --show-toplevel)").log`
(TSV: timestamp, model, summary, why). ≥2 per model per session → bench that
reviewer for the rest of the session. Tracked: codex, coderabbit, kimi, glm.

## Findings hard gate

Surface findings VERBATIM, grouped by reviewer. Convergence: 2+ reviewers =
HIGH-CONFIDENCE, 3+ = VERY-HIGH. STOP on findings — the user decides fix,
override, or ship; overrides are recorded (commit body when applicable).

## Churn checklist (edit facts HERE first)

1. Edit this contract. 2. Add a dated History bullet + bump the `panel-version`
marker in `codex-adversarial-review.md` — for SAME-DAY churn the bullet carries
the full version (`- **YYYY-MM-DD.N**: ...`) so the audit's version ratchet can
see it. 3. Mirror the marker in `~/.codex/skills/adversarial-review/SKILL.md`.
4. Sweep the leaf reviewer/planner skill descriptions for stale roster text.
5. If the IMPLEMENTATION ladder changed: update
`~/.claude/scripts/codex-implementation-fallback.sh` AND its test suite
(`test_codex_implementation_fallback.py`) in the same pass. 6. Run
`bash ~/.codex/sync-status.sh` — `rules.panel_version` and
`harness.shared_contract` must PASS.

Contract-id format (invariant — audit.py's CONTRACT_ID_MARKER regex depends on
it): an HTML comment `contract-id: <name>-v<n>` with `<name>` in `[a-z0-9-]+`
and integer `<n>`, appearing exactly once in this file.
