# Global instructions for Codex

Claude's global instruction files are authoritative. This file is generated for
Codex because Codex loads `~/.codex/AGENTS.md` instead of Claude's split
`CLAUDE.md` plus `rules/*.md` layout.

Do not edit the generated file directly. Edit the Claude source or the
Claude-owned sync templates, then run:

```bash
python3 ~/.claude/scripts/sync-ai-config.py --write --scope global
```
