# Secrets: Keychain, brokers, and the mistakes that made this necessary

This pack talks to five AI vendors and a handful of MCP servers. That's a lot of credentials, and every one of them started life as a plaintext `export` in a shell profile. This page documents where they ended up and why.

## The rule

**No credential value ever appears in a dotfile, in `argv`, in shell history, in a config file, or in chat.**

Every one of those is a real leak path, not a hypothetical:

- **Dotfiles** are readable by anything that can read your home directory, and they scroll past in every screen-share and pairing session.
- **`argv`** is visible to any process that can run `ps`.
- **Shell history** persists the value long after you've forgotten you typed it.
- **Config files** get committed. Eventually. By someone.
- **Chat** is the worst of all: a secret pasted into a conversation is compromised, full stop — it's in a transcript, possibly in a log, possibly in a training corpus. Rotate it; don't try to un-send it.

## Where each credential lives

| Credential | Storage | Consumed by |
|---|---|---|
| OpenAI / Codex | `codex login` OAuth → `~/.codex/auth.json` | `codex`, and `chatgpt-plan` (reads the token fresh each call) |
| Anthropic / Claude | `claude` CLI's own auth | Claude Code |
| Kimi managed | `kimi login` OAuth → `~/.kimi/` | `kimi`, `kimi-review` |
| Kimi paid API | macOS Keychain, `ai-config.kimi.MOONSHOT_API_KEY` | `kimi-review` paid retry, implementation ladder rung 3 |
| GLM / z.ai | macOS Keychain, `ai-config.myproject.ZAI_API_KEY` | `glm-review` |
| CodeRabbit | `coderabbit auth login` | `coderabbit` |
| MCP server tokens | macOS Keychain, brokered by `keychain-exec.sh` | the MCP servers, at spawn time |

## Storing a key in the Keychain

```bash
security add-generic-password -U -a "$(id -un)" -s ai-config.myproject.ZAI_API_KEY -w
```

### ⚠️ `-w` must be the last argument, with nothing after it

With nothing following it, `security` prompts you (twice, to confirm) and the key never enters `argv` or history. That's the entire point of the flag.

**Any flag placed after `-w` is silently swallowed *as* the password.** The earlier `-w -U` ordering stored the literal two-character string `-U` as the secret — exit 0, no prompt, no error, and a `glm-review` that failed authentication for reasons that made no sense until someone read the stored value back.

Reading it back is how you verify, and it's the one time the value is legitimately on screen:

```bash
security find-generic-password -a "$(id -un)" -s ai-config.myproject.ZAI_API_KEY -w
```

### Key formats worth knowing

- **z.ai / GLM**: `{API Key ID}.{secret}` — the *whole* dotted string is the token. The Anthropic-compatible endpoint takes it directly as the Bearer token; there's no JWT signing step. Export the entire string.

## Resolution order

`glm-review` resolves its token env-first, then Keychain:

1. `$ZAI_API_KEY` / `$ZAI_AUTH_TOKEN` if already exported — for CI and one-off overrides
2. macOS Keychain

If neither yields a token, it **exits 4 with instructions**. It deliberately does *not* fall back to your Anthropic auth: that would bill the wrong vendor and, much worse, would silently turn your cross-vendor panel into two Claudes reviewing the same diff while reporting as if it were two vendors. Failing loudly is the whole design.

## The MCP broker

MCP servers need tokens in their environment, and the obvious approach — putting them in `.mcp.json` — commits your secrets to the repo.

`scripts/keychain-exec.sh` sits in between:

```json
{
  "mcpServers": {
    "grafana": {
      "type": "stdio",
      "command": "~/.claude/scripts/keychain-exec.sh",
      "args": [
        "ai-config.myproject.GRAFANA_SERVICE_ACCOUNT_TOKEN",
        "GRAFANA_SERVICE_ACCOUNT_TOKEN",
        "--",
        "/opt/homebrew/bin/mcp-grafana", "-t", "stdio"
      ],
      "env": { "GRAFANA_URL": "https://your-tenant.example.net" }
    }
  }
}
```

The config now contains a Keychain *service name*, not a secret. The broker fetches the value at spawn time and injects it as an env var into the child.

Two guardrails inside the broker, both of which exist because a generic "fetch any key, run any command" tool is a credential-exfiltration primitive:

1. **The credential mapping is allowlisted.** Only known `service|variable` pairs are permitted.
2. **The command is pinned per credential.** The Grafana token can only ever launch `mcp-grafana` with exactly those arguments. Anything else exits 65.

So even if something rewrote `.mcp.json`, it couldn't point a real token at an arbitrary binary.

### Per-tool tokens

Where two assistants use the same service, issue **two tokens against one service account** — one per tool. The audit log stays unambiguous about which assistant made which change, and you can revoke either without breaking the other.

Use `GRAFANA_SERVICE_ACCOUNT_TOKEN`, not the deprecated `GRAFANA_API_KEY`; the latter emits a startup warning on every spawn.

## Never disable MCP servers by deleting them

Keep servers in config with `"disabled": true` and one file per server documenting its activation triggers and tool list. Enable on demand, disable after.

This is about a real cost, not tidiness: every enabled stdio server spawns a process and injects its tool definitions into context on every session. A dozen "might be useful someday" servers is a permanent context tax and a dozen background processes during automated deploys.

## What the audit enforces

- **`security.config_files`** flags literal credential assignments in dotfiles. This check is what moved the GLM key out of `~/.zshrc`; the literal had been sitting there for weeks, doing nothing wrong until the day someone shared their screen.
- **`security.runtime_scope`** checks that credentials aren't reachable outside the scope that needs them.
- **`security.artifact_residue`** catches secrets left behind in generated artifacts and transcripts.

That third one is subtle and worth internalizing: a batch of findings that look like leaked keys are often base64 blobs inside session transcripts — an assistant that read a file containing a key has now written it into a transcript on disk. Tightening the patterns to distinguish "a key in a config" from "a key quoted in a transcript" is necessary, but the transcript copy is still a real copy. Rotate anything that was ever pasted.

## If a key leaks

1. **Rotate first, investigate second.** A key that has been in a transcript, a screen-share, or a chat is compromised regardless of what the investigation concludes.
2. Re-store the new one with the `-w`-last incantation above.
3. Re-run the audit to confirm the literal is gone from every file.
4. Verify end-to-end from a **fresh login shell with the env vars unset** — otherwise you're testing your current shell's exported value, not the storage you just fixed, and it'll pass for the wrong reason.
