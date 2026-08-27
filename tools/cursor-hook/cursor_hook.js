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
const { postBridge, sessionId, workspaceCwd, enrichBody, debugLog } = require('./lib');

// Default off: only permission gates (cursor_hook_permission.js) push to the
// phone. Set OVD_CURSOR_OBSERVE=1 to forward busy/log/celebrate events too.
const OBSERVE = (process.env.OVD_CURSOR_OBSERVE || '0') === '1';
const TIMEOUT_MS = Number(process.env.OVD_CURSOR_HOOK_TIMEOUT_MS || 500);

function translate(ev) {
  const name = ev.hook_event_name || ev.event || '';
  const sid = sessionId(ev);
  const cwd = workspaceCwd(ev);
  const base = enrichBody(ev, { session_id: sid, ...(cwd ? { cwd } : {}) });

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

    // Only `stop` — `afterAgentResponse` also fires at turn end and would duplicate log lines.
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
      const desc = ev.description || ev.summary || ev.mcp_server_name || '';
      return {
        path: 'pretooluse',
        body: {
          ...base,
          tool_name: `mcp:${String(tool).slice(0, 40)}`,
          tool_input: { description: String(desc).slice(0, 120) },
        },
      };
    }

    case 'preToolUse': {
      const tool = String(ev.tool_name || 'tool').slice(0, 40);
      const ti = ev.tool_input || {};
      let hint =
        ti.path ||
        ti.file_path ||
        ti.command ||
        ti.description ||
        (typeof ti === 'object' ? JSON.stringify(ti).slice(0, 120) : '');
      const lower = tool.toLowerCase();
      if (lower === 'calldynamictool' || lower === 'getdynamictool' || lower === 'fetchmcpresource') {
        const ns = ti.namespace || ti.server || '';
        const tn = ti.toolName || ti.tool_name || ti.uri || '';
        hint = [ns, tn].filter(Boolean).join('/') || hint;
      }
      const detail = hint ? `${tool.toLowerCase()} ${String(hint).slice(0, 160)}` : tool.toLowerCase();
      return {
        path: 'pretooluse',
        body: {
          ...base,
          tool_name: tool.toLowerCase(),
          tool_detail: detail.trim(),
          tool_input: { command: String(hint).slice(0, 200) },
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
  if (!OBSERVE) process.exit(0);

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
