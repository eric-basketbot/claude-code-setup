# Wrappers

The read-only harnesses the reviewer and planner agents shell out to. `install.sh` copies these to `~/.local/bin/` and marks them executable.

They are wrappers, not thin aliases: each one exists to impose a safety property the underlying CLI does not offer.

| Wrapper | Wraps | Safety property it adds |
|---|---|---|
| `kimi-review` | Moonshot `kimi` | Read-only **by process isolation** — `kimi --print` implicitly auto-approves every tool call and has no read-only flag, so the wrapper runs it inside a disposable git worktree and deletes it afterwards. Any edits die with the worktree. |
| `glm-review` | `claude` CLI → z.ai endpoint | Read-only **by tool allowlist + external cwd** — `Read`/`Grep`/`Glob` only, run from a throwaway directory so the target repo's own hooks can't load, with the repo exposed read-only via `--add-dir`. |
| `chatgpt-plan` | ChatGPT backend | Rides the **subscription** rather than the separately-metered platform API, and constrains the role to business/strategy planning. |

## The contract they share

```bash
kimi-review [--model <name>] [--repo <path>] [--timeout <secs>] -p "<prompt>"
printf '%s' "<prompt>" | kimi-review
```

⚠️ **`-p` and piped stdin are mutually exclusive** (exit 2). There is no separate diff channel — **the diff must be embedded in the prompt text**.

Until 2026-07-25 both wrappers silently *discarded* piped stdin when `-p` was present. `git show X | kimi-review -p "review this"` returned a confident, well-formatted review of the repo at HEAD instead of commit X. Wrong target, no warning, and nothing downstream could tell. They now fail loudly instead.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success — **and, for `kimi-review`, every slice reviewed** |
| 2 | usage error (including `-p` + stdin together) |
| 3 | empty output / parse failure |
| 4 | not authenticated / no key |
| **65** | **`kimi-review` only: PARTIAL COVERAGE.** Slicing recovered some but not all slices. Output opens with `KIMI REVIEW COVERAGE: n of N` + `INCOMPLETE`. Treat the leg as DEGRADED — never clean. "No findings" on a partial run is not evidence of absence. |
| 124 | timeout |
| 127 | missing dependency |

## Timeouts — don't override them downward

Measured on real diffs: 10KB ≈ 4 min, 30KB ≈ 6.5 min, 74KB up to ~15 min, with large run-to-run variance (one 30KB diff timed out at 420s and finished in 388s on the next run).

`kimi-review` scales its timeout by prompt size (600/900/1200s), then on timeout slices the diff on `diff --git` boundaries and concatenates per-slice reviews, bounded by a 1800s total ceiling. Sliced output is marked `===== SLICE n/N =====` and is **degraded** — no cross-file reasoning. Report that to the gate.

`glm-review` uses 600s (`$GLM_REVIEW_TIMEOUT`). On large scopes, pin `--model glm-4.7` or split the scope; `glm-5.2` has been observed hanging.

Pinning a short `--timeout` was the original failure mode. Don't.

## Auth gotchas

- **Kimi**: unauthenticated `kimi --print` prints `LLM not set` and **exits 0**. The wrapper greps for that and converts it to exit 4, so the gate can't be handed a silent empty "review". Trust the wrapper's exit code, never a bare call's.
- **Kimi models**: the CLI needs the **namespaced** id (e.g. `kimi-code/k3`). A bare `k3` fails as `LLM not set`, which looks exactly like an auth error. `kimi-review` validates `--model` against your config and exits 2 with the valid list instead.
- **GLM**: resolves `$ZAI_API_KEY`/`$ZAI_AUTH_TOKEN` first, then the macOS Keychain. If neither yields a token it exits 4 — it deliberately does **not** fall back to your Anthropic auth, which would bill the wrong vendor and quietly turn a cross-vendor panel into two Claudes reviewing the same diff.
- **ChatGPT**: reads the OAuth token fresh from `~/.codex/auth.json` on every call, so Codex's own refresh keeps it current. No fallback to the metered API (which would bill separately, or 402 on a subscription account).

## Fragility, stated up front

`chatgpt-plan` talks to `chatgpt.com/backend-api`, which is **private and undocumented**. It can change shape without notice. If it breaks, fall back to `codex exec --sandbox read-only` with a business-planning prompt — same subscription, maintained CLI — until it's fixed.

## Configuration

All three honor environment overrides; see the header comment in each file. The ones you're most likely to want:

```bash
export KIMI_REVIEW_TOTAL_CAP=1800     # hard ceiling for the whole invocation
export GLM_REVIEW_TIMEOUT=600
export CHATGPT_PLAN_MODEL=gpt-5.6-sol
```
