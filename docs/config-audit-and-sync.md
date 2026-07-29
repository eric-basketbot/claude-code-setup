# Config audit + one-way Codex sync

Two subsystems that exist for one reason: **once you run two AI assistants against the same repo, their configuration silently drifts apart**, and drift is invisible until it produces a wrong answer.

- [`../skills/ai-config-audit/`](../skills/ai-config-audit/) — 22 read-only checks across both hosts.
- [`../scripts/sync-ai-config.py`](../scripts/sync-ai-config.py) — generates Codex's instruction files from Claude-owned sources.
- [`../ai-config/`](../ai-config/) — the manifest and topology graph that drive both.

Skip this whole page if you only run one assistant. It buys nothing until there are two.

## The drift problem

You write a rule in `~/.claude/rules/`. Six weeks later you also want Codex to follow it, so you paste it into `~/.codex/AGENTS.md`. Then you edit the Claude copy. Now two assistants are working the same repo under two different versions of one rule, and nothing anywhere will tell you.

Multiply by rules, agent rosters, skill inventories, hook wiring, and plugin sets, and you get two assistants that *look* identically configured and behave differently on the cases that matter.

## The fix: one owner, generated consumers

Claude-side files are the **source of truth**. Codex's instruction files are **generated**. Never edit a generated file — the next sync overwrites it, and you'll spend an afternoon working out why your change evaporated.

```bash
# check for drift (read-only, the default)
python3 ~/.claude/scripts/sync-ai-config.py --check

# regenerate after editing a Claude-owned rule
python3 ~/.claude/scripts/sync-ai-config.py --write --scope global
python3 ~/.claude/scripts/sync-ai-config.py --write --scope project   # from a worktree
```

`ai-config/sync-manifest.json` declares what flows where:

- `global.rules` — rules shared with Codex
- `global.host_only_rules` — rules that stay Claude-only, because they describe Claude's own orchestration (dispatching subagents, the agent roster) and would be noise or actively wrong for another host
- `global.preamble` / `appendix` — wrapper text around the generated body
- `project.*` — a heading allowlist plus substitutions, so project `CLAUDE.md` becomes `AGENTS.md` with the right terminology and without the sections that only apply to one host

Generated files carry a `body-sha256` digest in a header comment, which is how `--check` detects hand-edits.

### The host-only distinction matters

It's tempting to share every rule. Don't. A rule telling Claude "dispatch the `codex-reviewer` agent" is meaningless to Codex — worse, it invites Codex to try reviewing on Claude's behalf. Rules describing *what is true about the system* get shared; rules describing *how this host orchestrates* stay host-only.

## The shared contract

One exception to "each host owns its own docs": panel facts live in **[`../rules/multi-ai-harness.md`](../rules/multi-ai-harness.md)** (contract-id `multi-ai-harness-v2`), which both hosts load every session and which **overrides host-specific docs on conflict**.

The split is deliberate:

- The **contract** holds *facts* — rosters, model IDs, waterfalls, the permission matrix, the quorum table.
- Host docs hold *procedure* — how this particular host dispatches, in its own tooling.

When facts live in five host docs, they rot at five different rates. When they live in one, procedure docs can go stale without becoming *dangerous* — the contract still wins.

### The churn checklist

Any panel change follows this order, and the audit enforces it:

1. Edit the contract.
2. Add a dated History bullet and bump the `panel-version` marker. Same-day churn carries a full version (`2026-07-25.3`) so the audit's version ratchet can see it.
3. Mirror the marker in the Codex-side skill.
4. Sweep leaf reviewer/planner skill descriptions for stale roster text.
5. If the implementation ladder changed, update the wrapper **and its test suite** in the same pass.
6. Run the audit — `rules.panel_version` and `harness.shared_contract` must pass.

## The audit

```bash
python3 ~/.claude/skills/ai-config-audit/scripts/audit.py              # human-readable
python3 ~/.claude/skills/ai-config-audit/scripts/audit.py --json       # CI
python3 ~/.claude/skills/ai-config-audit/scripts/audit.py --project-root /abs/path
```

Exit codes: `0` clean, `1` findings, `2` incomplete audit or configuration error.

The 20 checks, grouped:

| Group | Checks |
|---|---|
| Rules | `rules.manifest_completeness`, `rules.generated_drift`, `rules.panel_version`, `rules.known_stale_content` |
| Skills | `skills.frontmatter`, `skills.broken_link`, `skills.duplicate_name`, `skills.asset_references`, `skills.codex_topology`, `skills.compatibility_root`, `skills.project_local` |
| Harness | `harness.shared_contract`, `roles.mapping`, `hooks.wiring`, `plugins.required` |
| Security | `security.config_files`, `security.runtime_scope`, `security.artifact_residue` |
| Memory | `memory.boundary`, `memory.health` |

**Output contract:** findings carry only a rule ID, severity, path, line number, and a safe classification. Secret bytes, hashes, lengths, snippets, and raw subprocess output are forbidden — an audit that leaks the credential it's warning about is worse than no audit. In `--json` mode, stdout is exactly one JSON document.

### 🔴 Never trust a clean audit on its own

`0 findings; 0 failed checks` is *also* the exact output of an audit that silently failed to run any checks. That fail-open signature is real and it happened.

Prove liveness before believing a pass: plant a known-bad canary against a throwaway `--project-root` and confirm the audit reports it. If a planted finding doesn't show up, the audit isn't running — regardless of how green it looks.

This generalizes past this tool. Any check whose "everything is fine" output is indistinguishable from "I didn't check" needs a liveness proof, not a glance.

### Two checks worth calling out

- **`security.config_files` / `literal_credential_assignment`** catches plaintext secrets in dotfiles. It's what forced the GLM key out of `~/.zshrc` and into the Keychain — see [`secrets.md`](secrets.md). A secret in a shell profile is readable by anything that can read the file and leaks into every screen-shared terminal.
- **`memory.boundary`** enforces that the shared knowledge base and a host's private memory store stay separate. Merging them contaminates a curated corpus with one host's session detritus, and it's not reversible once it's happened.

### `stale_content_patterns`

Declare project-specific "this claim is known to be wrong" regexes in `topology.json`:

```json
{
  "stale_content_patterns": {
    "old_domain": "(?:staging\\.|www\\.)?old-domain\\.example",
    "wrong_retention_window": "(?i)retention[^\\n]{0,40}\\b12 months\\b"
  }
}
```

Empty by default. This exists because docs assert *policy numbers* that later change, and a doc confidently stating the old figure is worse than one that says nothing. In the source setup this caught a doc claiming a 12-month window months after the code moved to 6 — and a user was told "nothing to do" on that basis.

## The topology graph

`ai-config/topology.json` is the machine-readable map of the harness: agent roles present on both hosts, host-only agents, host hook dependencies, native-per-host skills, shared contracts and their consumers and wrappers, required plugins, and generated skill packs with their name-prefix overrides.

It's what lets the audit answer "is this Codex skill *supposed* to be missing, or did something break?" without hardcoding an inventory. A plugin-managed skill absent from the Claude→Codex symlink set is correct; a topology-declared shared skill absent from it is a finding.
