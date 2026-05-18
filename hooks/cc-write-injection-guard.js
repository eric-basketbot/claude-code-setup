#!/usr/bin/env node
// cc-write-injection-guard.js — PreToolUse hook on Write/Edit/MultiEdit
// Scans content being written to long-lived memory/instruction files for
// prompt-injection patterns. Advisory-only (does not block).
//
// Inspired by gsd-build/get-shit-done's gsd-prompt-guard.js (MIT) — that one
// scans .planning/ writes since GSD subagents handoff via plan files. This
// one targets the equivalent persistent surfaces in this user's setup:
//
//   - ~/.claude/projects/*/memory/*       (auto-memory files + MEMORY.md)
//   - ~/.claude/CLAUDE.md                  (global Claude instructions)
//   - ~/.codex/AGENTS.md                   (global Codex instructions)
//   - **/CLAUDE.md                         (any project's CLAUDE.md)
//   - **/MEMORY.md                         (any project's MEMORY.md)
//   - **/.codex/AGENTS.md                  (project-scoped Codex)
//
// Why those: each one gets re-loaded into every future session's context.
// A poisoned write here persists indefinitely and survives compression.
//
// Scoping: scans only the NEW content to avoid false positives on the
// existing body of files like MEMORY.md (which legitimately documents
// injection patterns):
//   - Edit / MultiEdit : scan only tool_input.new_string
//   - Write            : scan tool_input.content, but ONLY for new files
//                         (file does not yet exist on disk). Overwriting an
//                         existing memory file is unusual and the user can
//                         re-trigger advisory by running scanner manually.

const fs = require('fs');
const path = require('path');

// Same patterns as cc-read-injection-scanner.js — kept inline for hook independence.
const SUMMARISATION_PATTERNS = [
  /when\s+(?:summari[sz]ing|compressing|compacting),?\s+(?:retain|preserve|keep)\s+(?:this|these)/i,
  /this\s+(?:instruction|directive|rule)\s+is\s+(?:permanent|persistent|immutable)/i,
  /preserve\s+(?:these|this)\s+(?:rules?|instructions?|directives?)\s+(?:in|through|after|during)/i,
  /(?:retain|keep)\s+(?:this|these)\s+(?:in|through|after)\s+(?:summar|compress|compact)/i,
];

const INJECTION_PATTERNS = [
  /ignore\s+(all\s+)?previous\s+instructions/i,
  /ignore\s+(all\s+)?above\s+instructions/i,
  /disregard\s+(all\s+)?previous/i,
  /forget\s+(all\s+)?(your\s+)?instructions/i,
  /override\s+(system|previous)\s+(prompt|instructions)/i,
  /you\s+are\s+now\s+(?:a|an|the)\s+/i,
  /act\s+as\s+(?:a|an|the)\s+(?!plan|phase|wave)/i,
  /pretend\s+(?:you(?:'re| are)\s+|to\s+be\s+)/i,
  /from\s+now\s+on,?\s+you\s+(?:are|will|should|must)/i,
  /(?:print|output|reveal|show|display|repeat)\s+(?:your\s+)?(?:system\s+)?(?:prompt|instructions)/i,
  /<\/?(?:system|assistant|human)>/i,
  /\[SYSTEM\]/i,
  /\[INST\]/i,
  /<<\s*SYS\s*>>/i,
];

const ALL_PATTERNS = [...INJECTION_PATTERNS, ...SUMMARISATION_PATTERNS];

function isProtectedPath(filePath) {
  const p = filePath.replace(/\\/g, '/');
  // ~/.claude/projects/*/memory/* — any file under any project's memory dir
  if (/\/\.claude\/projects\/[^/]+\/memory\//.test(p)) return true;
  // ~/.claude/CLAUDE.md (global)
  if (/\/\.claude\/CLAUDE\.md$/i.test(p)) return true;
  // ~/.codex/AGENTS.md (global) and any project-scoped .codex/AGENTS.md
  if (/(?:^|\/)\.codex\/AGENTS\.md$/i.test(p)) return true;
  // Any project's root CLAUDE.md or MEMORY.md
  const base = path.basename(p);
  if (/^(CLAUDE|MEMORY)\.md$/i.test(base)) return true;
  return false;
}

function scanContent(content) {
  if (!content || typeof content !== 'string' || content.length < 20) return [];
  const findings = [];
  for (const pattern of ALL_PATTERNS) {
    if (pattern.test(content)) {
      findings.push(pattern.source.replace(/\\s\+/g, '-').replace(/[()\\]/g, '').substring(0, 50));
    }
  }
  // Invisible Unicode (zero-width chars, line/para separators, RTL override,
  // soft hyphen, BOM, word-joiner / Cf-class invisibles in U+2060-2069).
  const invisRe = new RegExp("[\\u200B-\\u200F\\u2028-\\u202F\\uFEFF\\u00AD\\u2060-\\u2069]");
  if (invisRe.test(content)) findings.push('invisible-unicode');
  try {
    if (/[\u{E0000}-\u{E007F}]/u.test(content)) findings.push('unicode-tag-block');
  } catch { /* engine missing Unicode property escapes */ }
  return findings;
}

let inputBuf = '';
const stdinTimeout = setTimeout(() => process.exit(0), 5000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { inputBuf += chunk; });
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(inputBuf);
    const tool = data.tool_name;
    if (tool !== 'Write' && tool !== 'Edit' && tool !== 'MultiEdit') process.exit(0);

    const filePath = data.tool_input?.file_path || '';
    if (!filePath || !isProtectedPath(filePath)) process.exit(0);

    // Collect just the NEW content for each tool shape
    let scanTargets = [];
    if (tool === 'Edit') {
      const ns = data.tool_input?.new_string;
      if (typeof ns === 'string') scanTargets.push(ns);
    } else if (tool === 'MultiEdit') {
      const edits = data.tool_input?.edits || [];
      for (const e of edits) {
        if (typeof e?.new_string === 'string') scanTargets.push(e.new_string);
      }
    } else if (tool === 'Write') {
      // Only scan Write if the target file does NOT yet exist (genuinely new).
      // Overwrites of existing memory files are typically user-initiated.
      let exists = false;
      try { exists = fs.existsSync(filePath); } catch { /* treat as new */ }
      if (exists) process.exit(0);
      const c = data.tool_input?.content;
      if (typeof c === 'string') scanTargets.push(c);
    }

    if (scanTargets.length === 0) process.exit(0);

    const allFindings = new Set();
    for (const t of scanTargets) {
      for (const f of scanContent(t)) allFindings.add(f);
    }
    if (allFindings.size === 0) process.exit(0);

    const findings = Array.from(allFindings);
    const severity = findings.length >= 3 ? 'HIGH' : 'LOW';
    const fileName = path.basename(filePath);
    const detail = severity === 'HIGH'
      ? 'Multiple patterns — strong injection signal. This file persists across sessions; review the new content before committing it. Consider reverting if any pattern came from external scraped data rather than your own writing.'
      : 'Single pattern match may be a false positive (e.g., documenting an attack pattern). Continue if intentional.';

    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        additionalContext:
          `WRITE INJECTION GUARD [${severity}]: writing to "${fileName}" — content matched ` +
          `${findings.length} injection pattern(s): ${findings.join(', ')}. ` +
          `${detail} Path: ${filePath}`
      }
    }));
  } catch {
    // Silent fail — never block tool execution
    process.exit(0);
  }
});
