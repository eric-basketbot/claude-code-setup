#!/usr/bin/env python3
"""Report-only audit for Claude/Codex configuration convergence.

The output schema intentionally cannot carry file content or credential values.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from typing import Any, Callable, Iterable

try:
    import tomllib  # type: ignore[import-not-found]  # stdlib on Python 3.11+
except ImportError:  # macOS system python3 is still 3.9
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ImportError:  # pragma: no cover - environment guard
        sys.exit(
            "ai-config-audit needs TOML support.\n"
            "  Either run it on Python 3.11+ (tomllib is stdlib there):\n"
            "      brew install python@3.13 && python3.13 "
            "~/.claude/skills/ai-config-audit/scripts/audit.py\n"
            "  or install the backport for this interpreter:\n"
            f"      {sys.executable} -m pip install tomli\n"
            "Exiting rather than skipping the config.toml checks — a partial "
            "audit that reports clean is worse than no audit."
        )


HOME = Path.home()
CLAUDE = HOME / ".claude"
CODEX = HOME / ".codex"
AGENTS = HOME / ".agents"
# Point this at YOUR canonical checkout. Override per-run with --project-root,
# or persistently with the AI_CONFIG_PROJECT_ROOT environment variable.
DEFAULT_PROJECT = Path(
    os.environ.get("AI_CONFIG_PROJECT_ROOT", str(HOME / "src/your-project"))
).expanduser()
SYNC_MANIFEST = CLAUDE / "ai-config/sync-manifest.json"
TOPOLOGY = CLAUDE / "ai-config/topology.json"
GENERATOR = CLAUDE / "scripts/sync-ai-config.py"
# Claude Code encodes a project dir as its absolute path with "/" -> "-".
MEMORY_ROOT = CLAUDE / "projects" / str(DEFAULT_PROJECT).replace("/", "-") / "memory"
MEMORY_REPORT = MEMORY_ROOT / "meta/memory_health_report.md"
CODEX_AGENTS_FILE = CODEX / "AGENTS.md"
CONTRACT_ID_MARKER = re.compile(r"<!--\s*contract-id:\s*([a-z0-9-]+-v\d+)\s*-->")
PANEL_RULE = CLAUDE / "rules/codex-adversarial-review.md"
PANEL_SKILL = CODEX / "skills/adversarial-review/SKILL.md"
PANEL_VERSION = re.compile(r"<!--\s*panel-version:\s*(\d{4}-\d{2}-\d{2}\.\d+)")
PANEL_VERSION_ANY = re.compile(r"panel-version:\s*(\d{4}-\d{2}-\d{2}\.\d+)")
PANEL_HISTORY_ANCHOR = "History of panel composition"
PANEL_HISTORY_DATE = re.compile(r"(?m)^- \*\*(\d{4}-\d{2}-\d{2})")
PANEL_HISTORY_VERSION = re.compile(r"(?m)^- \*\*(\d{4}-\d{2}-\d{2})\.(\d+)")

ASSIGNMENT = re.compile(
    r'''(?ix)
    ["']?
    (api[_-]?key|access[_-]?key|auth(?:orization)?|bearer[_-]?token|
     client[_-]?secret|password|private[_-]?key|secret|token)
    ["']?\s*[:=]\s*
    (?:
      "((?:\\.|[^"\\])*)"
      |
      '((?:\\.|[^'\\])*)'
      |
      (\$\{[A-Z_][A-Z0-9_]*\})
      |
      ([^\s,}]+)
    )
    '''
)
SECRET_SHAPES = [
    re.compile(r"AIza[0-9A-Za-z_-]{20,}"),
    re.compile(r"(?:glsa_|ghp_|github_pat_|xox[baprs]-|sk-(?:proj-)?|re_)[0-9A-Za-z_-]{16,}"),
    re.compile(r"scp-live-[0-9a-f]{24,}"),
    re.compile(r"postgres(?:ql)?://[^\s:/]+:[^\s@]+@"),
    re.compile(r"(?i)(?:key|token|secret)=[0-9A-Za-z_-]{16,}"),
]
# Artifact scanning runs over session transcripts, which are FULL of long base64
# blobs (screenshots, attachments). The pre-2026-07-25 patterns matched any
# `AIza`+20-or-more run, so a 1898-char base64 chunk that happened to contain
# "AIza" was reported as a leaked credential — 13 of 16 "Google keys" found on
# 2026-07-25 were base64 coincidences or obvious fake placeholders
# (`AIzaOLDoldoldold123`), and all 3 "GitHub tokens" were base64 (lengths 45/185/248
# vs a real ghp_ token's 40).
#
# Two changes make this precise without weakening real detection:
#   1. TOKEN BOUNDARIES — a credential is delimited in practice (quote, `=`,
#      whitespace, newline). Requiring non-token chars on both sides is what
#      excludes matches embedded mid-blob. This is the fix that kills base64 FPs.
#   2. EXACT LENGTHS where the vendor format is fixed: a Google API key is ALWAYS
#      `AIza` + 35 chars (39 total); a classic GitHub PAT is `ghp_` + 36 (40).
#      This is what excludes the short fake placeholders.
#
# ACCEPTED TRADE-OFF: a real key concatenated directly to adjacent token characters
# with no delimiter is no longer matched here. That shape does not occur in practice
# for the emitters we scan, and the alternative — reporting every base64 blob as a
# critical credential leak — trains the reader to ignore the check, which is worse.
# NOTE: OUTPUT_SECRET_SHAPES below is deliberately left LOOSE. It redacts the audit's
# OWN output, where over-redaction is the safe direction; this precision work applies
# only to DETECTION.
_NB = rb"(?<![0-9A-Za-z_-])"   # left boundary: not mid-token
_NA = rb"(?![0-9A-Za-z_-])"    # right boundary: not mid-token
ARTIFACT_SECRET_SHAPES = [
    re.compile(_NB + rb"AIza[0-9A-Za-z_-]{35}" + _NA),
    re.compile(_NB + rb"glsa_[0-9A-Za-z_-]{20,}" + _NA),
    re.compile(_NB + rb"ghp_[0-9A-Za-z]{36}" + _NA),
    re.compile(_NB + rb"github_pat_[0-9A-Za-z_]{50,}" + _NA),
    re.compile(_NB + rb"xox[baprs]-[0-9A-Za-z-]{30,}" + _NA),
    re.compile(_NB + rb"scp-live-[0-9a-f]{24,}" + _NA),
]
ARTIFACT_SCAN_CHUNK_BYTES = 1024 * 1024
ARTIFACT_SCAN_OVERLAP_BYTES = 256
OUTPUT_SECRET_SHAPES = [
    re.compile(r"AIza[0-9A-Za-z_-]{20,}"),
    re.compile(
        r"(?:glsa_|ghp_|github_pat_|xox[baprs]-|sk-(?:proj-)?|re_)"
        r"[0-9A-Za-z_-]{16,}"
    ),
    re.compile(r"scp-live-[0-9a-f]{24,}"),
]
ASSET_REFERENCE = re.compile(r"(?:\(|`)((?:scripts|references)/[A-Za-z0-9_./-]+)")
KEYCHAIN_WRAPPER = str(CLAUDE / "scripts/keychain-exec.sh")
KEYCHAIN_POLICIES: dict[tuple[str, str], tuple[str, ...]] = {
    (
        "ai-config.global.GRAFANA_SERVICE_ACCOUNT_TOKEN",
        "GRAFANA_SERVICE_ACCOUNT_TOKEN",
    ): ("--", "/opt/homebrew/bin/mcp-grafana", "-t", "stdio"),
    (
        "ai-config.<project>.BASKETBOT_GRAFANA_SERVICE_ACCOUNT_TOKEN",
        "BASKETBOT_GRAFANA_SERVICE_ACCOUNT_TOKEN",
    ): ("--", "/opt/homebrew/bin/mcp-grafana", "-t", "stdio"),
    (
        "ai-config.<project>.STITCH_API_KEY",
        "STITCH_API_KEY",
    ): (
        "--",
        "/usr/local/bin/npx",
        "-y",
        "mcp-remote@0.1.38",
        "https://stitch.googleapis.com/mcp",
        "--silent",
    ),
}
CREDENTIAL_FLAGS = {
    "--api-key",
    "--authorization",
    "--header",
    "--password",
    "--secret",
    "--token",
}


def safe_path(path: Path) -> str:
    try:
        rendered = str(path.relative_to(HOME)).replace(os.sep, "/").join(("~/", ""))
    except ValueError:
        rendered = str(path)
    for pattern in OUTPUT_SECRET_SHAPES:
        rendered = pattern.sub("[REDACTED_CREDENTIAL]", rendered)
    return rendered


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value))).resolve()


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("root must be an object")
    return value


def codex_hooks_are_trusted(
    config: dict[str, Any], hooks_path: Path, hook_count: int
) -> bool:
    """Return whether Codex persisted trust for every project hook entry."""
    hooks = config.get("hooks", {})
    if not isinstance(hooks, dict):
        return False
    state = hooks.get("state", {})
    if not isinstance(state, dict):
        return False
    for index in range(hook_count):
        key = f"{hooks_path.resolve()}:pre_tool_use:0:{index}"
        entry = state.get(key)
        if not isinstance(entry, dict):
            return False
        trusted_hash = entry.get("trusted_hash")
        if not isinstance(trusted_hash, str) or re.fullmatch(
            r"sha256:[0-9a-f]{64}", trusted_hash
        ) is None:
            return False
    return True


def frontmatter(path: Path) -> dict[str, str]:
    """Parse YAML front matter well enough to read top-level scalar keys.

    Handles MULTI-LINE values, which the pre-2026-07-25 version did not: it read
    only the text after the colon ON THAT LINE, so perfectly valid YAML like

        description:
          React Native and Expo best practices ...

    parsed as an EMPTY description and got reported as `missing_skill_description`
    (hit on the vendored `react-native-skills` skill). Continuation lines and block
    scalars (`|`, `>`, with chomping indicators) are now folded into the value.

    Still deliberately not a full YAML parser — only top-level scalars are needed
    (callers read `name` and `description` only). Indented lines under a nested
    mapping such as `metadata:` get folded into that key's string, which is
    harmless because no caller reads it.
    """
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        return {}
    result: dict[str, str] = {}
    last_key: str | None = None
    for line in lines[1:]:
        if line == "---":
            return result
        match = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if match:
            last_key = match.group(1)
            value = match.group(2).strip().strip("\"'")
            # Block scalar header (`|`, `>`, `|-`, `>+`, ...): the value is the
            # indented block that follows, not this line.
            if re.fullmatch(r"[|>][+-]?\d*", value):
                value = ""
            result[last_key] = value
        elif last_key is not None and line[:1] in (" ", "\t") and line.strip():
            continuation = line.strip().strip("\"'")
            existing = result.get(last_key, "")
            result[last_key] = f"{existing} {continuation}".strip() if existing else continuation
        elif line.strip():
            # A non-indented line that is not `key:` ends any continuation.
            last_key = None
    return {}


def direct_skills(root: Path) -> Iterable[tuple[str, Path, Path]]:
    if not root.is_dir():
        return []
    found: list[tuple[str, Path, Path]] = []
    for entry in sorted(root.iterdir(), key=lambda item: item.name):
        skill_file = entry / "SKILL.md"
        if skill_file.is_file():
            metadata = frontmatter(skill_file)
            found.append((metadata.get("name", ""), skill_file, skill_file.resolve()))
    return found


def recursive_skills(root: Path) -> Iterable[tuple[str, Path, Path]]:
    """Enumerate skills as Codex discovers them, including linked packs."""
    if not root.is_dir():
        return []
    found: list[tuple[str, Path, Path]] = []
    for current, directories, files in os.walk(root, followlinks=True):
        directories[:] = [
            name
            for name in directories
            if name not in {".git", "node_modules", "__pycache__"}
        ]
        if "SKILL.md" not in files:
            continue
        skill_file = Path(current) / "SKILL.md"
        if skill_file.is_file():
            metadata = frontmatter(skill_file)
            found.append((metadata.get("name", ""), skill_file, skill_file.resolve()))
    return found


def broken_links(roots: Iterable[Path]) -> Iterable[Path]:
    for root in roots:
        if not root.exists() and not root.is_symlink():
            continue
        for current, directories, files in os.walk(root, followlinks=False):
            base = Path(current)
            for name in [*directories, *files]:
                candidate = base / name
                if candidate.is_symlink() and not candidate.exists():
                    yield candidate


def safe_env_reference(value: str) -> bool:
    cleaned = value.strip().strip('"\'').replace("\\\"", "")
    if not cleaned:
        return True
    if re.fullmatch(r"\$(?:[A-Z_][A-Z0-9_]*|\{[A-Z_][A-Z0-9_]*\})", cleaned):
        return True
    if re.fullmatch(
        r"(?i)(?:[A-Z][A-Z0-9_-]*:\s*)?(?:Bearer\s+)?"
        r"\$\{[A-Z_][A-Z0-9_]*\}",
        cleaned,
    ):
        return True
    if cleaned.lower() in {"env", "keychain", "credential-helper", "redacted"}:
        return True
    return False


def literal_credential_text(text: str) -> bool:
    if safe_env_reference(text.strip().rstrip(",")):
        return False
    if any(pattern.search(text) for pattern in SECRET_SHAPES):
        return True
    for match in ASSIGNMENT.finditer(text):
        key = match.group(1)
        value = next(
            (candidate for candidate in match.groups()[1:] if candidate is not None),
            "",
        )
        if key.lower().endswith("_env_var") or safe_env_reference(value):
            continue
        return True
    return False


def file_contains_artifact_secret_shape(
    path: Path,
    *,
    chunk_bytes: int = ARTIFACT_SCAN_CHUNK_BYTES,
    overlap_bytes: int = ARTIFACT_SCAN_OVERLAP_BYTES,
) -> bool:
    """Stream-scan a file for credential shapes without loading or emitting it."""
    if chunk_bytes <= 0 or overlap_bytes < 0:
        raise ValueError("chunk size must be positive and overlap non-negative")
    tail = b""
    with path.open("rb") as handle:
        while chunk := handle.read(chunk_bytes):
            data = tail + chunk
            if any(pattern.search(data) for pattern in ARTIFACT_SECRET_SHAPES):
                return True
            tail = data[-overlap_bytes:] if overlap_bytes else b""
    return False


def valid_keychain_invocation(command: str, args: Any) -> bool:
    if command != KEYCHAIN_WRAPPER or not isinstance(args, list) or len(args) < 3:
        return False
    if not all(isinstance(item, str) for item in args):
        return False
    key = (args[0], args[1])
    policy = KEYCHAIN_POLICIES.get(key)
    return policy is not None and tuple(args[2:]) == policy


def iter_claude_mcp_configs(state: dict[str, Any]) -> Iterable[dict[str, Any]]:
    """Yield every MCP server block Claude persists, across all projects."""
    top_level = state.get("mcpServers", {})
    if isinstance(top_level, dict):
        for config in top_level.values():
            if isinstance(config, dict):
                yield config
    projects = state.get("projects", {})
    if not isinstance(projects, dict):
        return
    for project in projects.values():
        if not isinstance(project, dict):
            continue
        servers = project.get("mcpServers", {})
        if isinstance(servers, dict):
            for config in servers.values():
                if isinstance(config, dict):
                    yield config


def mcp_config_credential_rules(
    config: Any,
) -> list[tuple[str, str, str, str]]:
    """Return value-free audit findings for one MCP server block."""
    if not isinstance(config, dict):
        return []
    findings: list[tuple[str, str, str, str]] = []

    def add(
        check: str,
        rule: str,
        severity: str = "critical",
        kind: str = "literal_secret",
    ) -> None:
        findings.append((check, rule, severity, kind))

    command = str(config.get("command", ""))
    args = config.get("args", [])
    if command == KEYCHAIN_WRAPPER and not valid_keychain_invocation(command, args):
        add(
            "security.runtime_scope",
            "keychain_wrapper_policy_mismatch",
            kind="policy_violation",
        )

    url = str(config.get("url", ""))
    for match in re.finditer(r"(?i)[?&](?:key|token|secret)=([^&]+)", url):
        if not safe_env_reference(match.group(1)):
            add("security.config_files", "literal_credential_assignment")

    for mapping_name in ("env", "headers"):
        mapping = config.get(mapping_name, {})
        if not isinstance(mapping, dict):
            continue
        for key, value in mapping.items():
            if literal_credential_text(f"{key}={json.dumps(str(value))}"):
                add("security.config_files", "literal_credential_assignment")

    if not isinstance(args, list):
        add(
            "security.config_files",
            "invalid_mcp_args",
            severity="error",
            kind="policy_violation",
        )
        return findings
    pending_credential_value = False
    for raw_arg in args:
        arg = str(raw_arg)
        argument_is_safe_reference = safe_env_reference(arg)
        if literal_credential_text(arg) and not argument_is_safe_reference:
            add("security.config_files", "literal_credential_assignment")
        if pending_credential_value and not argument_is_safe_reference:
            add("security.config_files", "literal_credential_argument")
        pending_credential_value = arg.lower() in CREDENTIAL_FLAGS
    return findings


def parse_claude_plugin_status(output: str) -> dict[str, bool]:
    """Parse each Claude plugin block without crossing into the next block."""
    plugins: dict[str, bool] = {}
    for block in re.split(r"(?m)^\s*❯\s+", output)[1:]:
        lines = block.splitlines()
        if not lines:
            continue
        plugin_name = lines[0].strip().split("@", 1)[0]
        plugins[plugin_name] = any(
            re.fullmatch(r"\s*Status:\s+.*enabled\s*", line) is not None
            for line in lines[1:]
        )
    return plugins


class Audit:
    def __init__(self, project: Path) -> None:
        self.project = project.resolve()
        self.checks: dict[str, dict[str, Any]] = {}
        self.information: dict[str, Any] = {}

    def finding(
        self,
        check: str,
        rule_id: str,
        path: Path,
        *,
        line: int | None = None,
        severity: str = "error",
        kind: str = "policy_violation",
    ) -> None:
        item: dict[str, Any] = {
            "rule_id": rule_id,
            "severity": severity,
            "path": safe_path(path),
            "kind": kind,
        }
        if line is not None:
            item["line"] = line
        self.checks.setdefault(check, {"status": "pass", "findings": []})
        self.checks[check]["status"] = "fail"
        self.checks[check]["findings"].append(item)

    def check(self, name: str, callback: Callable[[], None]) -> None:
        # Isolate per-check failures. Before 2026-07-25 an exception in ANY single
        # check propagated to main(), which aborted the whole run and printed
        # "0 finding(s); 0 failed check(s)" — i.e. one broken check silently
        # disabled every other check while looking almost like a clean report.
        # That is fail-OPEN on a gate whose entire job is catching drift.
        self.checks.setdefault(name, {"status": "pass", "findings": []})
        try:
            callback()
        except (
            OSError,
            ValueError,
            KeyError,
            AttributeError,
            TypeError,
            RuntimeError,
            subprocess.SubprocessError,
        ) as error:
            self.checks[name]["status"] = "fail"
            self.checks[name]["findings"].append(
                {
                    "rule_id": "check_raised",
                    "severity": "error",
                    "path": safe_path(self.project),
                    "kind": "check_error",
                    "detail": f"{type(error).__name__}: {error}",
                }
            )

    def generated_drift(self) -> None:
        for scope, cwd in (
            ("global", None),
            ("project", self.project),
        ):
            # stderr is CAPTURED, not discarded: the generator's message is the only
            # thing that explains WHY it failed (e.g. "project CLAUDE.md headings must
            # match the manifest"). Discarding it turned every generator failure into
            # an undiagnosable "audit did not complete".
            result = subprocess.run(
                [sys.executable, str(GENERATOR), "--check", "--scope", scope],
                cwd=cwd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                check=False,
            )
            target = CODEX / "AGENTS.md" if scope == "global" else self.project / "AGENTS.md"
            if result.returncode == 1:
                self.finding("rules.generated_drift", "generated_target_mismatch", target, kind="content_mismatch")
            elif result.returncode != 0:
                detail = (result.stderr or "").strip().splitlines()
                self.checks.setdefault("rules.generated_drift", {"status": "pass", "findings": []})
                self.checks["rules.generated_drift"]["status"] = "fail"
                self.checks["rules.generated_drift"]["findings"].append(
                    {
                        "rule_id": "generator_failed",
                        "severity": "error",
                        "path": safe_path(target),
                        "kind": "generator_error",
                        "detail": f"scope={scope} rc={result.returncode}: "
                        + (detail[-1] if detail else "(no stderr)"),
                    }
                )

    def rule_manifest(self, manifest: dict[str, Any]) -> None:
        global_config = manifest["global"]
        declared = {
            Path(value).expanduser().resolve()
            for value in [*global_config["rules"], *global_config.get("host_only_rules", [])]
        }
        actual = set((CLAUDE / "rules").glob("*.md"))
        for path in sorted(actual ^ declared):
            rule = "undeclared_rule" if path in actual else "missing_declared_rule"
            self.finding("rules.manifest_completeness", rule, path)

    @staticmethod
    def hook_commands(value: Any) -> list[str]:
        commands: list[str] = []
        if isinstance(value, dict):
            command = value.get("command")
            if isinstance(command, str):
                commands.append(command)
            for nested in value.values():
                commands.extend(Audit.hook_commands(nested))
        elif isinstance(value, list):
            for nested in value:
                commands.extend(Audit.hook_commands(nested))
        return commands

    @staticmethod
    def hook_command_entries(value: Any) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []
        if isinstance(value, dict):
            if isinstance(value.get("command"), str):
                entries.append(value)
            for nested in value.values():
                entries.extend(Audit.hook_command_entries(nested))
        elif isinstance(value, list):
            for nested in value:
                entries.extend(Audit.hook_command_entries(nested))
        return entries

    def hook_wiring(self, topology: dict[str, Any]) -> None:
        canonical = DEFAULT_PROJECT.resolve()
        expected_claude = {
            f"bash {canonical}/scripts/claude-hooks/track-git-cwd.sh",
            f"bash {canonical}/scripts/claude-hooks/check-remote-push.sh",
        }
        expected_codex = {
            "env BB_HOOK_HOST=codex BB_ALWAYS_BLOCK_CANONICAL=1 "
            f"bash {canonical}/scripts/claude-hooks/track-git-cwd.sh",
            "env BB_HOOK_HOST=codex "
            f"bash {canonical}/scripts/claude-hooks/check-remote-push.sh",
        }

        claude_hooks = canonical / ".claude/settings.json"
        if claude_hooks.is_file():
            claude_hook_data = load_json(claude_hooks).get("hooks", {})
            actual = set(self.hook_commands(claude_hook_data))
            if not expected_claude.issubset(actual):
                self.finding("hooks.wiring", "claude_project_hooks_missing", claude_hooks)
            for entry in self.hook_command_entries(claude_hook_data):
                if (
                    "check-remote-push.sh" in entry["command"]
                    and int(entry.get("timeout", 0)) < 30
                ):
                    self.finding(
                        "hooks.wiring", "remote_push_hook_timeout_too_short", claude_hooks
                    )
        else:
            self.finding("hooks.wiring", "claude_project_hooks_missing", claude_hooks)

        for codex_hooks in {
            self.project / ".codex/hooks.json",
            canonical / ".codex/hooks.json",
        }:
            if not codex_hooks.is_file():
                self.finding("hooks.wiring", "codex_project_hooks_missing", codex_hooks)
                continue
            hook_data = load_json(codex_hooks).get("hooks", {})
            actual = set(self.hook_commands(hook_data))
            if actual != expected_codex:
                self.finding("hooks.wiring", "codex_project_hooks_wrong", codex_hooks)
            for entry in self.hook_command_entries(hook_data):
                if (
                    "check-remote-push.sh" in entry["command"]
                    and int(entry.get("timeout", 0)) < 30
                ):
                    self.finding(
                        "hooks.wiring", "remote_push_hook_timeout_too_short", codex_hooks
                    )

        codex_config_path = CODEX / "config.toml"
        try:
            codex_config = tomllib.loads(codex_config_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, tomllib.TOMLDecodeError):
            self.finding(
                "hooks.wiring", "codex_hook_trust_state_unreadable", codex_config_path
            )
        else:
            canonical_hooks = canonical / ".codex/hooks.json"
            if not codex_hooks_are_trusted(codex_config, canonical_hooks, 2):
                self.finding(
                    "hooks.wiring", "codex_project_hooks_untrusted", codex_config_path
                )
            if re.search(
                r"(?m)^\s*bypass_hook_trust\s*=\s*true\s*(?:#.*)?$",
                codex_config_path.read_text(encoding="utf-8"),
            ):
                self.finding(
                    "hooks.wiring", "codex_hook_trust_bypass_enabled", codex_config_path
                )

        tracked = subprocess.run(
            ["git", "-C", str(self.project), "ls-files", "--error-unmatch", ".codex/hooks.json"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
        if tracked.returncode != 0:
            self.finding(
                "hooks.wiring",
                "codex_project_hooks_not_tracked",
                self.project / ".codex/hooks.json",
            )

        declared = {
            expand_path(path)
            for path in topology.get("claude_host_hook_dependencies", [])
        }
        for dependency in declared:
            if not dependency.is_file():
                self.finding(
                    "hooks.wiring", "missing_declared_claude_hook", dependency
                )
        settings = load_json(CLAUDE / "settings.json")
        active: set[Path] = set()
        active_config = {
            "hooks": settings.get("hooks", {}),
            "statusLine": settings.get("statusLine", {}),
        }
        for command in self.hook_commands(active_config):
            for token in command.split():
                candidate = Path(token)
                if any(
                    str(candidate).startswith(str(root) + os.sep)
                    for root in (CLAUDE / "plugins", CLAUDE / "hooks")
                ):
                    active.add(candidate.resolve())
        for dependency in sorted(active - declared):
            self.finding(
                "hooks.wiring", "undeclared_active_claude_hook", dependency
            )
        for dependency in sorted(declared - active):
            self.finding(
                "hooks.wiring", "declared_claude_hook_not_active", dependency
            )

    def skill_topology(self, topology: dict[str, Any]) -> None:
        roots = [CLAUDE / "skills", CLAUDE / "agents", CODEX / "skills", AGENTS / "skills"]
        for path in broken_links(roots):
            self.finding("skills.broken_link", "broken_symlink", path)

        agents_root = AGENTS / "skills"
        if agents_root.is_dir():
            for entry in agents_root.iterdir():
                self.finding("skills.compatibility_root", "unexpected_compatibility_skill", entry)

        # Claude discovers only direct user-skill entries. Codex recursively
        # follows linked packs, so use its real discovery shape to catch an
        # accidentally exposed source repository (notably gstack).
        host_skills = {
            "claude": list(direct_skills(CLAUDE / "skills")),
            "codex": list(recursive_skills(CODEX / "skills")),
        }
        for entries in host_skills.values():
            skills: dict[str, list[tuple[Path, Path]]] = defaultdict(list)
            for name, path, realpath in entries:
                if not name:
                    self.finding("skills.frontmatter", "missing_skill_name", path)
                else:
                    skills[name].append((path, realpath))
                metadata = frontmatter(path)
                if not metadata.get("description"):
                    self.finding("skills.frontmatter", "missing_skill_description", path)
                text = path.read_text(encoding="utf-8")
                try:
                    path.relative_to(CODEX / "skills" / ".system")
                    native_system_skill = True
                except ValueError:
                    native_system_skill = False
                if native_system_skill:
                    continue
                for reference in ASSET_REFERENCE.findall(text):
                    relative = reference.rstrip(".,:;)")
                    asset = path.resolve().parent / relative
                    candidates = [asset]
                    for parent in path.resolve().parents:
                        if parent.name == "gstack":
                            candidates.append(parent / relative)
                            break
                    if not any(candidate.exists() for candidate in candidates):
                        line = text[: text.find(reference)].count("\n") + 1
                        self.finding("skills.asset_references", "missing_skill_asset", asset, line=line)

            for name, named_entries in sorted(skills.items()):
                if len({str(realpath) for _, realpath in named_entries}) > 1:
                    for path, _ in named_entries:
                        self.finding("skills.duplicate_name", "duplicate_skill_different_realpath", path)

        native = set(topology["codex_native_skills"])
        optional_host_managed = set(
            topology.get("codex_optional_host_managed_skill_roots", [])
        )
        claude_host_only = set(topology.get("claude_host_only_skills", []))
        for required_name in topology.get("required_shared_skills", []):
            claude_entry = CLAUDE / "skills" / required_name
            codex_entry = CODEX / "skills" / required_name
            if not (claude_entry / "SKILL.md").is_file():
                self.finding(
                    "skills.codex_topology",
                    "missing_required_shared_skill",
                    claude_entry,
                )
            if (
                not codex_entry.is_symlink()
                or codex_entry.resolve() != claude_entry.resolve()
            ):
                self.finding(
                    "skills.codex_topology",
                    "missing_required_shared_skill_replica",
                    codex_entry,
                )
        pack_config = topology.get("generated_skill_packs", {}).get("gstack", {})
        pack_source = expand_path(pack_config["claude_source"])
        pack_runtime = expand_path(pack_config["codex_runtime"])
        pack_generated = expand_path(pack_config["generated_codex"])
        pack_prefix = pack_config["codex_prefix"]
        pack_overrides = pack_config.get("claude_to_codex_overrides", {})

        for entry_name in sorted(native):
            entry = CODEX / "skills" / entry_name
            if (
                not entry.is_dir()
                or entry.is_symlink()
                or not (entry / "SKILL.md").is_file()
            ):
                self.finding(
                    "skills.codex_topology", "missing_native_codex_skill", entry
                )

        # The generated source inventory is authoritative. This catches a
        # newly generated gstack command before either host has an adapter for
        # it, instead of only validating adapters that already happen to exist.
        reverse_overrides = {
            codex_name: claude_name
            for claude_name, codex_name in pack_overrides.items()
            if codex_name is not None
        }
        for _, generated_skill, _ in direct_skills(pack_generated):
            generated_name = generated_skill.parent.name
            codex_entry = CODEX / "skills" / generated_name
            if generated_name == "gstack":
                if (
                    not codex_entry.is_dir()
                    or codex_entry.is_symlink()
                    or not (codex_entry / "SKILL.md").is_file()
                    or (codex_entry / "SKILL.md").read_bytes()
                    != generated_skill.read_bytes()
                ):
                    self.finding(
                        "skills.codex_topology",
                        "generated_pack_runtime_drift",
                        codex_entry,
                    )
            elif (
                not codex_entry.is_symlink()
                or codex_entry.resolve() != generated_skill.parent.resolve()
            ):
                self.finding(
                    "skills.codex_topology",
                    "missing_generated_codex_adapter",
                    codex_entry,
                )

            claude_name = reverse_overrides.get(
                generated_name,
                "gstack"
                if generated_name == "gstack"
                else generated_name.removeprefix(pack_prefix),
            )
            claude_skill = CLAUDE / "skills" / claude_name / "SKILL.md"
            try:
                claude_skill.resolve().relative_to(pack_source)
                claude_adapter_in_pack = True
            except ValueError:
                claude_adapter_in_pack = False
            if not claude_skill.is_file() or not claude_adapter_in_pack:
                self.finding(
                    "skills.codex_topology",
                    "missing_generated_claude_adapter",
                    claude_skill,
                )

        # Enforce Claude -> Codex replication for every direct ordinary skill.
        for _, skill_path, _ in direct_skills(CLAUDE / "skills"):
            claude_entry = skill_path.parent
            entry_name = claude_entry.name
            resolved_skill = skill_path.resolve()
            if entry_name in claude_host_only:
                continue
            try:
                resolved_skill.relative_to(pack_source)
                in_generated_pack = True
            except ValueError:
                in_generated_pack = False
            if in_generated_pack:
                if entry_name in pack_overrides and pack_overrides[entry_name] is None:
                    continue
                codex_name = pack_overrides.get(
                    entry_name,
                    "gstack" if entry_name == "gstack" else f"{pack_prefix}{entry_name}",
                )
                codex_entry = CODEX / "skills" / codex_name
                generated_name = "gstack" if entry_name == "gstack" else codex_name
                expected_skill = pack_generated / generated_name / "SKILL.md"
                if not (codex_entry / "SKILL.md").is_file() or (codex_entry / "SKILL.md").resolve() != expected_skill.resolve():
                    self.finding("skills.codex_topology", "missing_generated_codex_adapter", codex_entry)
                continue
            codex_entry = CODEX / "skills" / entry_name
            if not codex_entry.is_symlink() or codex_entry.resolve() != claude_entry.resolve():
                self.finding("skills.codex_topology", "missing_codex_replica", codex_entry)

        for entry in (CODEX / "skills").iterdir():
            if entry.name in native:
                if entry.is_symlink():
                    self.finding("skills.codex_topology", "native_skill_is_symlink", entry)
                continue
            if entry.name in optional_host_managed:
                if entry.is_symlink():
                    self.finding(
                        "skills.codex_topology",
                        "host_managed_skill_root_is_symlink",
                        entry,
                    )
                continue
            if entry.resolve() == pack_runtime.resolve():
                if entry.is_symlink():
                    self.finding("skills.codex_topology", "generated_pack_runtime_is_symlink", entry)
                continue
            if entry.name.startswith(pack_prefix):
                expected = (pack_generated / entry.name).resolve()
                if not entry.is_symlink() or entry.resolve() != expected:
                    self.finding("skills.codex_topology", "generated_pack_adapter_wrong_target", entry)
                continue
            if not entry.is_symlink():
                self.finding("skills.codex_topology", "unexpected_codex_physical_skill", entry)
                continue
            target = entry.resolve()
            expected = (CLAUDE / "skills" / entry.name).resolve()
            if target != expected:
                self.finding("skills.codex_topology", "codex_link_wrong_target", entry)

        for role in topology["roles"]:
            skill = CLAUDE / "skills" / role / "SKILL.md"
            agent = CLAUDE / "agents" / f"{role}.md"
            codex = CODEX / "skills" / role
            if not skill.is_file():
                self.finding("roles.mapping", "missing_claude_role_skill", skill)
            if not agent.is_symlink() or agent.resolve() != skill.resolve():
                self.finding("roles.mapping", "claude_agent_wrong_target", agent)
            if not codex.is_symlink() or codex.resolve() != skill.parent.resolve():
                self.finding("roles.mapping", "codex_role_wrong_target", codex)

        declared_agents = {
            *topology["roles"],
            *topology.get("claude_host_only_agents", []),
        }
        actual_agents = {
            path.stem
            for path in (CLAUDE / "agents").glob("*.md")
            if path.is_file()
        }
        for name in sorted(actual_agents - declared_agents):
            self.finding(
                "roles.mapping",
                "undeclared_claude_agent",
                CLAUDE / "agents" / f"{name}.md",
            )
        for name in sorted(declared_agents - actual_agents):
            self.finding(
                "roles.mapping",
                "missing_declared_claude_agent",
                CLAUDE / "agents" / f"{name}.md",
            )

    def project_skills(self, topology: dict[str, Any]) -> None:
        allowed = set(topology["project_local_skills"])
        for root_name in (".agents/skills", ".claude/skills"):
            root = self.project / root_name
            if not root.is_dir():
                continue
            for entry in root.iterdir():
                if entry.is_dir() and not any(entry.iterdir()):
                    continue
                if entry.name not in allowed:
                    self.finding("skills.project_local", "unexpected_project_skill", entry)

    def credential_configs(self) -> None:
        paths = [
            CODEX / "config.toml",
            CLAUDE / "settings.json",
            CLAUDE / "settings.local.json",
            HOME / ".zshrc",
            self.project / ".mcp.json",
            self.project / ".claude/settings.json",
            self.project / ".claude/settings.local.json",
            self.project / ".codex/config.toml",
        ]
        for path in paths:
            if not path.exists():
                continue
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                self.finding("security.config_files", "unsafe_config_file_type", path)
                continue
            if info.st_uid != os.getuid():
                self.finding("security.config_files", "unsafe_config_owner", path)
            if stat.S_IMODE(info.st_mode) & 0o077:
                self.finding("security.config_files", "unsafe_config_mode", path, kind="file_mode")
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except (OSError, UnicodeError) as error:
                raise RuntimeError(f"cannot scan credential config {safe_path(path)}") from error
            for number, line in enumerate(lines, 1):
                if literal_credential_text(line):
                    self.finding(
                        "security.config_files",
                        "literal_credential_assignment",
                        path,
                        line=number,
                        severity="critical",
                        kind="literal_secret",
                    )

        def scan_mcp_config(config: Any, source: Path) -> None:
            for check, rule, severity, kind in mcp_config_credential_rules(config):
                self.finding(
                    check,
                    rule,
                    source,
                    severity=severity,
                    kind=kind,
                )

        config_text = (CODEX / "config.toml").read_text(encoding="utf-8")
        try:
            codex_config = tomllib.loads(config_text)
        except (ValueError, tomllib.TOMLDecodeError) as error:
            raise RuntimeError("cannot parse Codex config") from error
        codex_mcp = codex_config.get("mcp_servers", {})
        for config in codex_mcp.values():
            scan_mcp_config(config, CODEX / "config.toml")
        for required_name in ("grafana", "stitch"):
            required = codex_mcp.get(required_name, {})
            if not valid_keychain_invocation(str(required.get("command", "")), required.get("args", [])):
                self.finding(
                    "security.runtime_scope",
                    "required_keychain_mapping_missing",
                    CODEX / "config.toml",
                    severity="critical",
                )
        for server_name, server_config in codex_mcp.items():
            if server_name == "node_repl":
                continue
            if not isinstance(server_config, dict) or server_config.get("enabled") is not False:
                self.finding(
                    "security.runtime_scope",
                    "codex_mcp_not_disabled_at_rest",
                    CODEX / "config.toml",
                )

        project_mcp_path = self.project / ".mcp.json"
        if project_mcp_path.is_file():
            project_mcp = load_json(project_mcp_path).get("mcpServers", {})
            for config in project_mcp.values():
                scan_mcp_config(config, project_mcp_path)
                if not isinstance(config, dict) or config.get("disabled") is not True:
                    self.finding(
                        "security.runtime_scope",
                        "project_mcp_not_disabled_at_rest",
                        project_mcp_path,
                    )
            stitch = project_mcp.get("stitch", {})
            if not valid_keychain_invocation(str(stitch.get("command", "")), stitch.get("args", [])):
                self.finding(
                    "security.runtime_scope",
                    "required_keychain_mapping_missing",
                    project_mcp_path,
                    severity="critical",
                )
            grafana = project_mcp.get("grafana", {})
            if not valid_keychain_invocation(
                str(grafana.get("command", "")), grafana.get("args", [])
            ):
                self.finding(
                    "security.runtime_scope",
                    "required_keychain_mapping_missing",
                    project_mcp_path,
                    severity="critical",
                )

        claude_state = HOME / ".claude.json"
        if claude_state.exists():
            info = claude_state.lstat()
            if stat.S_IMODE(info.st_mode) & 0o077:
                self.finding("security.config_files", "unsafe_config_mode", claude_state, kind="file_mode")
            state = load_json(claude_state)
            persisted_configs = list(iter_claude_mcp_configs(state))
            for config in persisted_configs:
                scan_mcp_config(config, claude_state)
            if persisted_configs:
                self.finding(
                    "security.runtime_scope",
                    "claude_mcp_present_at_rest",
                    claude_state,
                )

        retired_loader = CLAUDE / "scripts/load-ai-secrets-to-launchctl.sh"
        if retired_loader.exists():
            self.finding("security.runtime_scope", "global_secret_loader_present", retired_loader)
        wrapper = CLAUDE / "scripts/keychain-exec.sh"
        if not wrapper.is_file() or stat.S_IMODE(wrapper.stat().st_mode) != 0o700:
            self.finding("security.runtime_scope", "keychain_wrapper_missing_or_unsafe", wrapper)
        else:
            wrapper_text = wrapper.read_text(encoding="utf-8")
            required_policy_markers = {
                "#!/bin/zsh -f",
                "unsetopt XTRACE VERBOSE",
                "/usr/bin/security",
                "/usr/bin/id",
                "mcp-remote@0.1.38",
                "X-Goog-Api-Key:${STITCH_API_KEY}",
                "ai-config.global.GRAFANA_SERVICE_ACCOUNT_TOKEN\\|GRAFANA_SERVICE_ACCOUNT_TOKEN",
                "ai-config.<project>.BASKETBOT_GRAFANA_SERVICE_ACCOUNT_TOKEN\\|BASKETBOT_GRAFANA_SERVICE_ACCOUNT_TOKEN",
                "ai-config.<project>.STITCH_API_KEY\\|STITCH_API_KEY",
            }
            if any(
                marker not in wrapper_text for marker in required_policy_markers
            ) or any(
                forbidden in wrapper_text
                for forbidden in ("AI_CONFIG_TESTING", "AI_CONFIG_SECURITY_BIN")
            ):
                self.finding(
                    "security.runtime_scope",
                    "keychain_wrapper_policy_mismatch",
                    wrapper,
                    severity="critical",
                )
        policy_match = re.search(
            r"(?ms)^\s*\[shell_environment_policy\]\s*(.*?)(?=^\s*\[|\Z)",
            config_text,
        )
        excluded = set(
            re.findall(r'"([A-Z][A-Z0-9_]+)"', policy_match.group(1))
            if policy_match
            else []
        )
        for variable in (
            "BASKETBOT_GRAFANA_SERVICE_ACCOUNT_TOKEN",
            "CLOUDFLARE_API_TOKEN",
            "GITHUB_PERSONAL_ACCESS_TOKEN",
            "GITHUB_TOKEN",
            "GH_TOKEN",
            "GRAFANA_SERVICE_ACCOUNT_TOKEN",
            "GOOGLE_API_KEY",
            "GREPTILE_API_KEY",
            "SCRAPFLY_API_KEY",
            "SNYK_API",
            "SNYK_API_TOKEN",
            "SNYK_TOKEN",
            "STITCH_API_KEY",
        ):
            result = subprocess.run(
                ["/bin/launchctl", "getenv", variable],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=5,
                check=False,
            )
            if result.stdout:
                self.finding("security.runtime_scope", "credential_in_launchctl", CODEX / "config.toml")
            if variable not in excluded:
                self.finding("security.runtime_scope", "missing_shell_environment_exclusion", CODEX / "config.toml")

        artifact_roots = [
            CODEX / "sessions",
            CODEX / "shell_snapshots",
            CLAUDE / "projects",
            HOME / ".ai-config-backups",
        ]
        for root in artifact_roots:
            if not root.exists():
                continue
            for current, directories, files in os.walk(root, followlinks=False):
                directories[:] = [name for name in directories if name not in {".git", "node_modules", "plugins", "cache"}]
                for name in files:
                    path = Path(current) / name
                    try:
                        if path.is_symlink() or path.stat().st_size > 60_000_000:
                            continue
                        contains_secret_shape = file_contains_artifact_secret_shape(path)
                    except OSError:
                        continue
                    if contains_secret_shape:
                        self.finding("security.artifact_residue", "credential_shape_in_artifact", path, severity="critical", kind="literal_secret")

        # Codex diagnostic databases can exceed the general artifact scan cap.
        # Scan the database and its WAL/SHM sidecars as bounded streams so token
        # shapes cannot hide in a large log store or across a chunk boundary.
        for path in sorted(CODEX.glob("logs*.sqlite*")):
            try:
                if path.is_symlink() or not path.is_file():
                    continue
                contains_secret_shape = file_contains_artifact_secret_shape(path)
            except OSError:
                continue
            if contains_secret_shape:
                self.finding("security.artifact_residue", "credential_shape_in_artifact", path, severity="critical", kind="literal_secret")

    def memory_boundary(self) -> None:
        alias = CODEX / "memory"
        product = CODEX / "memories"
        if not alias.is_symlink() or alias.resolve() != MEMORY_ROOT.resolve():
            self.finding("memory.boundary", "shared_memory_alias_wrong", alias)
        if not product.is_dir() or product.is_symlink():
            self.finding("memory.boundary", "codex_product_memory_not_separate", product)
        elif alias.exists() and os.path.samefile(alias, product):
            self.finding("memory.boundary", "codex_memory_roots_alias", product)

        report = MEMORY_REPORT.read_text(encoding="utf-8") if MEMORY_REPORT.exists() else ""
        if "**Status**: GREEN" not in report:
            self.finding("memory.health", "memory_health_not_green", MEMORY_REPORT)

    def stale_rules(self) -> None:
        # Project-specific "this claim is known to be stale" patterns. Declare
        # them in topology.json as {"stale_content_patterns": {"<rule-id>": "<regex>"}}
        # — e.g. an old domain you renamed away from, or a policy figure that a
        # doc still states incorrectly. Empty by default.
        declared = (self.topology or {}).get("stale_content_patterns", {})
        patterns = {}
        for rule_id, expression in declared.items():
            try:
                patterns[rule_id] = re.compile(expression)
            except re.error:
                self.finding("rules.known_stale_content", f"invalid_pattern:{rule_id}", TOPOLOGY)
        if not patterns:
            return
        for path in (self.project / "CLAUDE.md", self.project / "AGENTS.md"):
            if not path.is_file():
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                for rule_id, pattern in patterns.items():
                    if pattern.search(line):
                        self.finding("rules.known_stale_content", rule_id, path, line=number)
            text = path.read_text(encoding="utf-8")
            if "explicit confirmation before pushing to `vps main`" not in text:
                self.finding(
                    "rules.known_stale_content", "missing_production_gate", path
                )

    def panel_version(self) -> None:
        """The Claude panel rule and its Codex twin skill must carry matching markers.

        Failure shapes: the HTML-comment markers diverge across the two files;
        colon-form copies of the version inside one file diverge; the Claude
        rule's History section gained a dated bullet newer than the marker
        (panel churn without a bump); or the marker date is newer than the
        newest History entry (bump without a History record).
        """
        texts: dict[Path, str] = {}
        versions: dict[Path, str] = {}
        for path in (PANEL_RULE, PANEL_SKILL):
            if not path.is_file():
                self.finding("rules.panel_version", "panel_file_missing", path)
                continue
            text = path.read_text(encoding="utf-8")
            texts[path] = text
            match = PANEL_VERSION.search(text)
            if match is None:
                self.finding(
                    "rules.panel_version", "panel_version_marker_missing", path
                )
                continue
            versions[path] = match.group(1)
            if len(set(PANEL_VERSION_ANY.findall(text))) > 1:
                self.finding(
                    "rules.panel_version",
                    "panel_version_intra_file_mismatch",
                    path,
                    kind="content_mismatch",
                )
        if len(versions) == 2 and len(set(versions.values())) > 1:
            for path in sorted(versions):
                self.finding(
                    "rules.panel_version",
                    "panel_version_mismatch",
                    path,
                    kind="content_mismatch",
                )
        rule_version = versions.get(PANEL_RULE)
        if rule_version is not None:
            anchor = texts[PANEL_RULE].find(PANEL_HISTORY_ANCHOR)
            history = (
                PANEL_HISTORY_DATE.findall(texts[PANEL_RULE][anchor:])
                if anchor >= 0
                else []
            )
            if history:
                marker_date, marker_suffix = rule_version.split(".", 1)
                newest = max(history)
                if newest > marker_date:
                    self.finding(
                        "rules.panel_version",
                        "panel_version_stale",
                        PANEL_RULE,
                        kind="content_mismatch",
                    )
                elif newest < marker_date:
                    self.finding(
                        "rules.panel_version",
                        "panel_version_unrecorded",
                        PANEL_RULE,
                        kind="content_mismatch",
                    )
                else:
                    # Same-day churn: bullets that carry a full version
                    # (YYYY-MM-DD.N) must not outrun (or trail) the marker.
                    versioned = [
                        (date, int(number))
                        for date, number in PANEL_HISTORY_VERSION.findall(
                            texts[PANEL_RULE][anchor:]
                        )
                    ]
                    if versioned:
                        marker_tuple = (marker_date, int(marker_suffix))
                        newest_version = max(versioned)
                        if newest_version > marker_tuple:
                            self.finding(
                                "rules.panel_version",
                                "panel_version_stale",
                                PANEL_RULE,
                                kind="content_mismatch",
                            )
                        elif newest_version < marker_tuple:
                            self.finding(
                                "rules.panel_version",
                                "panel_version_unrecorded",
                                PANEL_RULE,
                                kind="content_mismatch",
                            )

    def shared_contracts(self, manifest: dict[str, Any], topology: dict[str, Any]) -> None:
        """Every declared shared contract must be synced to both hosts and
        referenced by every declared consumer; declared wrappers must exist and
        be executable. Contract-id appears exactly once in the source (as the
        canonical marker) and at least once in each consumer / the rendered
        Codex AGENTS.md."""
        contracts = topology.get("shared_contracts", {})
        if not contracts:
            self.finding("harness.shared_contract", "no_contracts_declared", TOPOLOGY)
            return
        global_config = manifest["global"]
        declared_rules = {
            Path(value).expanduser().resolve() for value in global_config["rules"]
        }
        host_only = {
            Path(value).expanduser().resolve()
            for value in global_config.get("host_only_rules", [])
        }
        agents_text = (
            CODEX_AGENTS_FILE.read_text(encoding="utf-8")
            if CODEX_AGENTS_FILE.is_file()
            else ""
        )
        for spec in contracts.values():
            contract_id = spec["contract_id"]
            source = Path(spec["source"]).expanduser()
            if not source.is_file():
                self.finding("harness.shared_contract", "contract_source_missing", source)
                continue
            markers = CONTRACT_ID_MARKER.findall(source.read_text(encoding="utf-8"))
            if markers != [contract_id]:
                self.finding(
                    "harness.shared_contract", "contract_id_not_exactly_once", source
                )
            resolved = source.resolve()
            if resolved not in declared_rules or resolved in host_only:
                self.finding("harness.shared_contract", "contract_not_synced", source)
            if contract_id not in CONTRACT_ID_MARKER.findall(agents_text):
                self.finding(
                    "harness.shared_contract",
                    "contract_missing_from_codex_agents",
                    CODEX_AGENTS_FILE,
                    kind="content_mismatch",
                )
            for consumer in spec.get("consumers", []):
                path = Path(consumer).expanduser()
                if not path.is_file():
                    self.finding("harness.shared_contract", "consumer_missing", path)
                    continue
                if contract_id not in path.read_text(encoding="utf-8"):
                    self.finding(
                        "harness.shared_contract",
                        "consumer_missing_contract_reference",
                        path,
                        kind="content_mismatch",
                    )
            for wrapper in spec.get("wrappers", []):
                path = Path(wrapper).expanduser()
                if not (path.is_file() and os.access(path, os.X_OK)):
                    self.finding(
                        "harness.shared_contract", "wrapper_not_executable", path
                    )

    def plugin_inventory(self, topology: dict[str, Any]) -> None:
        expected = topology["required_plugins"]
        claude_result = subprocess.run(
            ["claude", "plugin", "list"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
            check=False,
        )
        codex_result = subprocess.run(
            ["codex", "plugin", "list"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
            check=False,
        )
        if claude_result.returncode != 0 or codex_result.returncode != 0:
            raise RuntimeError("plugin inventory command failed")
        claude_plugins = parse_claude_plugin_status(claude_result.stdout)
        for name in expected["claude"]:
            if not claude_plugins.get(name, False):
                self.finding("plugins.required", "missing_claude_plugin", CLAUDE / "plugins")
        for name in expected["codex"]:
            if not re.search(rf"(?m)^{re.escape(name)}@\S+\s+installed, enabled", codex_result.stdout):
                self.finding("plugins.required", "missing_codex_plugin", CODEX / "plugins")
        self.information["plugins"] = {
            "claude": sorted(expected["claude"]),
            "codex": sorted(expected["codex"]),
        }

    def run(self) -> dict[str, Any]:
        manifest = load_json(SYNC_MANIFEST)
        topology = load_json(TOPOLOGY)
        if manifest.get("schema_version") != 1 or topology.get("schema_version") != 1:
            raise ValueError("unsupported manifest schema")

        self.check("rules.generated_drift", self.generated_drift)
        self.check("rules.manifest_completeness", lambda: self.rule_manifest(manifest))
        self.check("hooks.wiring", lambda: self.hook_wiring(topology))
        self.check("skills.broken_link", lambda: None)
        self.check("skills.compatibility_root", lambda: None)
        self.check("skills.frontmatter", lambda: None)
        self.check("skills.asset_references", lambda: None)
        self.check("skills.duplicate_name", lambda: None)
        self.check("skills.codex_topology", lambda: None)
        self.check("roles.mapping", lambda: self.skill_topology(topology))
        self.check("skills.project_local", lambda: self.project_skills(topology))
        self.check("security.config_files", self.credential_configs)
        self.check("security.runtime_scope", lambda: None)
        self.check("security.artifact_residue", lambda: None)
        self.check("memory.boundary", lambda: None)
        self.check("memory.health", self.memory_boundary)
        self.check("rules.known_stale_content", self.stale_rules)
        self.check("rules.panel_version", self.panel_version)
        self.check(
            "harness.shared_contract",
            lambda: self.shared_contracts(manifest, topology),
        )
        self.check("plugins.required", lambda: self.plugin_inventory(topology))

        failed = sum(check["status"] == "fail" for check in self.checks.values())
        findings = sum(len(check["findings"]) for check in self.checks.values())
        return {
            "schema_version": "ai-config-audit/v1",
            "status": "fail" if failed else "pass",
            "complete": True,
            "exit_code": 1 if failed else 0,
            "project_root": safe_path(self.project),
            "summary": {
                "passed": len(self.checks) - failed,
                "failed": failed,
                "errors": 0,
                "findings": findings,
            },
            "checks": [
                {"id": name, **value} for name, value in sorted(self.checks.items())
            ],
            "information": self.information,
            "output_policy": {
                "contains_file_content": False,
                "contains_secret_values": False,
            },
        }


def choose_project(explicit: Path | None) -> Path:
    if explicit is not None:
        return explicit.expanduser().resolve()
    current = Path.cwd()
    if (current / "CLAUDE.md").is_file() and (current / ".git").exists():
        return current.resolve()
    return DEFAULT_PROJECT.resolve()


class AuditArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ValueError(f"invalid command line: {message}")


def parse_args() -> argparse.Namespace:
    parser = AuditArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit one stable JSON document")
    parser.add_argument("--project-root", type=Path, help="<project> checkout to audit")
    return parser.parse_args()


def human_report(report: dict[str, Any]) -> None:
    print(f"AI config audit: {report['status'].upper()}")
    print(f"Project: {report.get('project_root', '(unavailable)')}")
    for check in report["checks"]:
        print(f"{check['status'].upper():4} {check['id']}")
        for finding in check["findings"]:
            location = finding["path"]
            if "line" in finding:
                location = f"{location}:{finding['line']}"
            print(f"     {finding['severity']} {finding['rule_id']} {location}")
    summary = report["summary"]
    print(f"{summary['findings']} finding(s); {summary['failed']} failed check(s)")


def main() -> int:
    json_requested = "--json" in sys.argv[1:]
    project = DEFAULT_PROJECT.resolve()
    try:
        args = parse_args()
        json_requested = args.json
        project = choose_project(args.project_root)
        report = Audit(project).run()
    except (
        OSError,
        ValueError,
        KeyError,
        AttributeError,
        TypeError,
        RuntimeError,
        subprocess.SubprocessError,
    ) as error:
        # Include the actual message — a bare type name is undiagnosable, and this
        # path now only fires for setup-level failures (arg parsing, project
        # resolution), since per-check failures are isolated in Audit.check().
        print(
            f"ERROR {type(error).__name__}: audit did not complete: {error}",
            file=sys.stderr,
        )
        report = {
            "schema_version": "ai-config-audit/v1",
            "status": "error",
            "complete": False,
            "exit_code": 2,
            "project_root": safe_path(project),
            "summary": {"passed": 0, "failed": 0, "errors": 1, "findings": 0},
            "checks": [],
            "output_policy": {
                "contains_file_content": False,
                "contains_secret_values": False,
            },
        }
    if json_requested:
        print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    else:
        human_report(report)
    return int(report["exit_code"])


if __name__ == "__main__":
    raise SystemExit(main())
