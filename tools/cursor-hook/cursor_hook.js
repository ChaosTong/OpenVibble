#!/usr/bin/env node
//
// Cursor IDE async hook → OpenVibble Desktop HTTP bridge.
//
// Reads Cursor hook JSON from stdin, maps events to OpenVibble Desktop
// Bridge API endpoints, POSTs to 127.0.0.1 (port/token from
// ~/.claude/openvibble.port), exits 0 immediately.
//
// Fail-open: if OpenVibble Desktop is not running or iPhone is not
// connected, the hook must never block Cursor.

'use strict';

const fs = require('fs');
const { postBridge, sessionId, workspaceCwd, debugLog } = require('./lib');

const TIMEOUT_MS = Number(process.env.OVD_CURSOR_HOOK_TIMEOUT_MS || 500);

function translate(ev) {
  const name = ev.hook_event_name || ev.event || '';
  const sid = sessionId(ev);
  const cwd = workspaceCwd(ev);
  const base = { session_id: sid };
  if (cwd) base.cwd = cwd;

  switch (name) {
    case 'sessionStart':
      return { path: 'session-start', body: base };

    case 'sessionEnd':
      return { path: 'session-end', body: base };

    case 'beforeSubmitPrompt': {
      const prompt =
        ev.prompt || ev.user_prompt || ev.userPrompt || ev.text || '';
      return {
        path: 'prompt',
        body: { ...base, prompt: String(prompt) },
      };
    }

    case 'afterAgentResponse':
    case 'afterAgentThought':
    case 'stop':
      return { path: 'stop', body: base };

    case 'beforeReadFile': {
      const fp = ev.file_path || ev.path || ev.filePath || '';
      return {
        path: 'pretooluse',
        body: {
          ...base,
          tool_name: 'read',
          tool_input: { file_path: String(fp).slice(0, 200) },
        },
      };
    }

    case 'beforeShellExecution': {
      const ti = ev.tool_input || {};
      const cmd = ev.command || ti.command || ev.shell_command || '';
      return {
        path: 'pretooluse',
        body: {
          ...base,
          tool_name: 'shell',
          tool_input: { command: String(cmd).slice(0, 200) },
        },
      };
    }

    case 'afterShellExecution':
      return {
        path: 'pretooluse',
        body: { ...base, tool_name: 'shell', tool_input: { phase: 'after' } },
      };

    case 'beforeMCPExecution': {
      const tool = ev.tool || ev.tool_name || ev.method || 'mcp';
      const desc = ev.description || ev.summary || '';
      return {
        path: 'pretooluse',
        body: {
          ...base,
          tool_name: `mcp:${String(tool).slice(0, 40)}`,
          tool_input: { description: String(desc).slice(0, 120) },
        },
      };
    }

    case 'afterMCPExecution':
      return {
        path: 'pretooluse',
        body: { ...base, tool_name: 'mcp', tool_input: { phase: 'after' } },
      };

    case 'afterFileEdit': {
      const fp = ev.file_path || ev.path || ev.filePath || '';
      return {
        path: 'pretooluse',
        body: {
          ...base,
          tool_name: 'edit',
          tool_input: { file_path: String(fp).slice(0, 200) },
        },
      };
    }

    case 'subagentStart':
      return {
        path: 'subagent-start',
        body: {
          ...base,
          tool_name: `sub:${String(ev.subagent_type || ev.type || 'task').slice(0, 24)}`,
        },
      };

    case 'subagentStop':
      return {
        path: 'subagent-stop',
        body: {
          ...base,
          tool_name: `sub:${String(ev.subagent_type || ev.type || 'task').slice(0, 24)}`,
        },
      };

    default:
      return null;
  }
}

async function main() {
  let raw;
  try {
    raw = fs.readFileSync(0, 'utf8');
  } catch (_) {
    process.exit(0);
  }
  if (!raw) process.exit(0);

  let ev;
  try {
    ev = JSON.parse(raw);
  } catch (_) {
    process.exit(0);
  }

  debugLog({ async: true, ev });

  const mapped = translate(ev);
  if (!mapped) process.exit(0);

  await postBridge(mapped.path, mapped.body, { timeoutMs: TIMEOUT_MS });
  process.exit(0);
}

main();
