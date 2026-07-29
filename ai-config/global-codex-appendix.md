## Codex-specific appendix

These instructions describe Codex capabilities and paths that do not have a
literal Claude equivalent. They are maintained in the Claude-owned sync source
and appended to the shared global rules during generation.

### Model selection

- Use the default model for routine engineering work.
- Increase reasoning effort for architecture, risky refactors, and deep review.
- Use a lighter profile for repetitive, low-risk work when one is configured.
- Codex profiles live in `~/.codex/config.toml` under `[profiles.<name>]`.

### Shared role and workflow skills

- Cross-host skills are authored under `~/.claude/skills/` and exposed to Codex
  through directory symlinks under `~/.codex/skills/`.
- Third-party packs available as native plugins are installed and updated by
  each host instead of being copied. Superpowers and Expo follow this rule.
- Codex-only native skills may remain real directories under `~/.codex/skills/`.
- Do not add a second physical copy under `~/.agents/skills/`; duplicate scanner
  roots make skill selection ambiguous.
- See `~/.codex/SYNC.md` for the current topology and maintenance commands.

### Persistent <project> memory

The canonical <project> knowledge base lives at
`~/.claude/projects/<abs-repo-path-with-slashes-as-dashes>/memory/`.
Codex reads the same files through the `~/.codex/memory` symlink. Start with
`~/.codex/memory/MEMORY.md`, then follow the topic indexes.

`~/.codex/memories/` is Codex's separate product-managed memory store. Never
merge or symlink it into the shared <project> knowledge base.

### Mid-task handoffs

When pausing substantial <project> work or approaching context compaction,
write a handoff from `docs/handoffs/TEMPLATE.md` as
`docs/handoffs/YYYY-MM-DD-NN-slug.md`. Skip this for trivial or fully completed
work.

### Claude-only features

Do not assume Claude slash commands, status line behavior, plugin hooks, or
agent file formats are available in Codex. Use the Codex tools and skills
actually exposed in the current session. Reference copies under
`~/.codex/reference/` are documentation, not automatically active features.

### User profile

- The user is not a developer; provide copy-paste-ready commands with full paths.
- The <project> domain is `myproject.ai`.
- Default ZIP codes are `48309` and `94801`.
- Launch markets are Detroit, Bay Area, Birmingham, Miami, Longmont, Parker,
  and Anchorage.

### Tone

- Keep responses concise.
- Do not add generic wrap-up trailers.
- Use clickable Markdown links for file references.
