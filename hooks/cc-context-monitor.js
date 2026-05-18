#!/usr/bin/env node
// cc-context-monitor.js — PostToolUse hook that injects context-pressure warnings
//
// Source: adapted from gsd-build/get-shit-done's gsd-context-monitor.js (MIT).
// Changes vs upstream:
//   - Stripped GSD-specific bits (.planning/STATE.md detection, gsd-tools spawn,
//     /gsd-pause-work suggestions in advisory text)
//   - Kept thresholds, debounce, severity-escalation bypass
//   - Advisory text now suggests user's actual flow: pause + summarize state, not GSD
//
// How it works:
// 1. cc-statusline.js writes context metrics to /tmp/claude-ctx-{session_id}.json
// 2. This hook reads those metrics after each tool use
// 3. When remaining context drops below thresholds, it injects a warning as
//    additionalContext, which the agent sees in its next conversation turn
//
// Thresholds (on raw remaining_percentage from Claude Code, not buffer-normalized):
//   WARNING  (remaining <= 35%): wrap up current task, no new complex work
//   CRITICAL (remaining <= 25%): inform user, ask how to proceed, save state
//
// Debounce: 5 tool calls between repeat warnings. WARNING -> CRITICAL bypasses.

const fs = require('fs');
const os = require('os');
const path = require('path');

const WARNING_THRESHOLD = 35;
const CRITICAL_THRESHOLD = 25;
const STALE_SECONDS = 60;
const DEBOUNCE_CALLS = 5;

let input = '';
const stdinTimeout = setTimeout(() => process.exit(0), 10000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const sessionId = data.session_id;
    if (!sessionId) process.exit(0);
    // Path-traversal guard on session_id
    if (/[/\\]|\.\./.test(sessionId)) process.exit(0);

    const tmpDir = os.tmpdir();
    const metricsPath = path.join(tmpDir, `claude-ctx-${sessionId}.json`);
    if (!fs.existsSync(metricsPath)) process.exit(0);

    const metrics = JSON.parse(fs.readFileSync(metricsPath, 'utf8'));
    const now = Math.floor(Date.now() / 1000);
    if (metrics.timestamp && (now - metrics.timestamp) > STALE_SECONDS) process.exit(0);

    const remaining = metrics.remaining_percentage;
    const usedPct = metrics.used_pct;
    if (remaining > WARNING_THRESHOLD) process.exit(0);

    // Debounce w/ severity-escalation bypass
    const warnPath = path.join(tmpDir, `claude-ctx-${sessionId}-warned.json`);
    let warnData = { callsSinceWarn: 0, lastLevel: null };
    let firstWarn = true;
    if (fs.existsSync(warnPath)) {
      try {
        warnData = JSON.parse(fs.readFileSync(warnPath, 'utf8'));
        firstWarn = false;
      } catch (e) { /* corrupted, reset */ }
    }
    warnData.callsSinceWarn = (warnData.callsSinceWarn || 0) + 1;

    const isCritical = remaining <= CRITICAL_THRESHOLD;
    const currentLevel = isCritical ? 'critical' : 'warning';
    const severityEscalated = currentLevel === 'critical' && warnData.lastLevel === 'warning';

    if (!firstWarn && warnData.callsSinceWarn < DEBOUNCE_CALLS && !severityEscalated) {
      fs.writeFileSync(warnPath, JSON.stringify(warnData));
      process.exit(0);
    }

    warnData.callsSinceWarn = 0;
    warnData.lastLevel = currentLevel;
    fs.writeFileSync(warnPath, JSON.stringify(warnData));

    // Advisory message — never use imperative "you must" language; advisory only.
    let message;
    if (isCritical) {
      message =
        `CONTEXT CRITICAL: usage at ${usedPct}%, remaining ${remaining}%. ` +
        `Context is nearly exhausted. Inform the user that context is low and ask how they want to proceed. ` +
        `Do NOT autonomously start new complex work, write large handoff files, or kick off long subagent runs. ` +
        `Good options to suggest: a /clear with a one-line summary of where to resume, or finishing the current ` +
        `tool call and stopping.`;
    } else {
      message =
        `CONTEXT WARNING: usage at ${usedPct}%, remaining ${remaining}%. ` +
        `Wrap up the current task before starting new exploration. Avoid spawning subagents that return large ` +
        `outputs. If mid-multi-step work, consider checkpointing progress in a memory file or commit so the ` +
        `next session can resume cleanly.`;
    }

    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PostToolUse',
        additionalContext: message
      }
    }));
  } catch (e) {
    // Silent fail — never block tool execution
    process.exit(0);
  }
});
