#!/usr/bin/env node
// cc-statusline.js — Claude Code statusline with context-bridge file
//
// Source: adapted from gsd-build/get-shit-done's gsd-statusline.js (MIT).
// Changes vs upstream:
//   - Stripped GSD-specific bits (.planning/STATE.md, last-slash-command, update banner)
//   - Kept the auto-compact-buffer-aware context % math
//   - Kept the bridge-file write at /tmp/claude-ctx-{session_id}.json
//     (consumed by cc-context-monitor.js to make the agent self-aware of context)
//   - Kept native Claude Code todos integration (in-progress task display)
//
// Output format:  {model} | {in-progress task or dirname} | {progress bar} {used%}

const fs = require('fs');
const path = require('path');
const os = require('os');

let input = '';
const stdinTimeout = setTimeout(() => process.exit(0), 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const model = data.model?.display_name || 'Claude';
    const dir = data.workspace?.current_dir || process.cwd();
    const session = data.session_id || '';
    const remaining = data.context_window?.remaining_percentage;

    // Context window display.
    // Claude Code reserves an autocompact buffer (~16.5% by default).
    // CLAUDE_CODE_AUTO_COMPACT_WINDOW (token count) overrides; compute % dynamically.
    const totalCtx = data.context_window?.total_tokens || 1_000_000;
    const acw = parseInt(process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW || '0', 10);
    const AUTO_COMPACT_BUFFER_PCT = acw > 0
      ? Math.min(100, (acw / totalCtx) * 100)
      : 16.5;

    let ctx = '';
    if (remaining != null) {
      // Normalize: subtract buffer from remaining, scale to usable range
      const usableRemaining = Math.max(0, ((remaining - AUTO_COMPACT_BUFFER_PCT) / (100 - AUTO_COMPACT_BUFFER_PCT)) * 100);
      const used = Math.max(0, Math.min(100, Math.round(100 - usableRemaining)));

      // Bridge file: write raw (un-normalized) context state for cc-context-monitor.
      // The monitor uses the RAW remaining_percentage (matches Claude Code's
      // native /context reporting), not the buffer-normalized used %.
      // Reject session IDs with path separators to prevent /tmp escape.
      const sessionSafe = session && !/[/\\]|\.\./.test(session);
      if (sessionSafe) {
        try {
          const bridgePath = path.join(os.tmpdir(), `claude-ctx-${session}.json`);
          const rawUsedPct = Math.round(100 - remaining);
          fs.writeFileSync(bridgePath, JSON.stringify({
            session_id: session,
            remaining_percentage: remaining,
            used_pct: rawUsedPct,
            timestamp: Math.floor(Date.now() / 1000)
          }));
        } catch (e) {
          // Best-effort — never break the statusline
        }
      }

      // 10-segment progress bar
      const filled = Math.floor(used / 10);
      const bar = '█'.repeat(filled) + '░'.repeat(10 - filled);

      // Color by usable-context threshold
      if (used < 50) {
        ctx = ` \x1b[32m${bar} ${used}%\x1b[0m`;
      } else if (used < 65) {
        ctx = ` \x1b[33m${bar} ${used}%\x1b[0m`;
      } else if (used < 80) {
        ctx = ` \x1b[38;5;208m${bar} ${used}%\x1b[0m`;
      } else {
        ctx = ` \x1b[5;31m💀 ${bar} ${used}%\x1b[0m`;
      }
    }

    // In-progress task from Claude Code's native todos
    let task = '';
    const homeDir = os.homedir();
    const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(homeDir, '.claude');
    const todosDir = path.join(claudeDir, 'todos');
    if (session && fs.existsSync(todosDir)) {
      try {
        const files = fs.readdirSync(todosDir)
          .filter(f => f.startsWith(session) && f.includes('-agent-') && f.endsWith('.json'))
          .map(f => ({ name: f, mtime: fs.statSync(path.join(todosDir, f)).mtime }))
          .sort((a, b) => b.mtime - a.mtime);
        if (files.length > 0) {
          const todos = JSON.parse(fs.readFileSync(path.join(todosDir, files[0].name), 'utf8'));
          const inProgress = todos.find(t => t.status === 'in_progress');
          if (inProgress) task = inProgress.activeForm || '';
        }
      } catch (e) { /* never break statusline */ }
    }

    const dirname = path.basename(dir);
    const middle = task ? `\x1b[1m${task}\x1b[0m` : null;
    if (middle) {
      process.stdout.write(`\x1b[2m${model}\x1b[0m │ ${middle} │ \x1b[2m${dirname}\x1b[0m${ctx}`);
    } else {
      process.stdout.write(`\x1b[2m${model}\x1b[0m │ \x1b[2m${dirname}\x1b[0m${ctx}`);
    }
  } catch (e) {
    // Silent fail — never break the statusline
  }
});
