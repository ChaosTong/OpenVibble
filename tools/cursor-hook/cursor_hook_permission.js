#!/usr/bin/env node
//
// Cursor IDE gateable pre-execution hook → OpenVibble Desktop /permission-request.
//
// Blocks until the user approves/denies on iPhone or OpenVibble Desktop (or
// timeout), then writes Cursor's { permission: allow|deny } JSON to stdout.
//
// Wired to beforeShellExecution and beforeMCPExecution only.

'use strict';

const fs = require('fs');
const { postBridge, sessionId, workspaceCwd, debugLog } = require('./lib');

const TIMEOUT_MS = Number(process.env.OVD_CURSOR_PERMISSION_TIMEOUT_MS || 30000);
const ENABLED = (process.env.OVD_CURSOR_PERMISSION_ECHO || '1') !== '0';

function emitNoop() {
  process.exit(0);
}

function emitDecision(perm, reason) {
  const body = { permission: perm };
  if (reason) {
    body.user_message = reason;
    body.agent_message = reason;
  }
  process.stdout.write(JSON.stringify(body) + '\n');
  process.exit(0);
}

function describe(ev) {
  const name = ev.hook_event_name || '';

  if (name === 'beforeShellExecution') {
    const cmd = String(ev.command || '').slice(0, 200);
    return { tool_name: 'shell', tool_input: { command: cmd } };
  }

  if (name === 'beforeMCPExecution') {
    const tool = String(ev.tool_name || ev.tool || 'mcp').slice(0, 40);
    let ti = ev.tool_input;
    if (typeof ti === 'string') {
      try {
        ti = JSON.parse(ti);
      } catch (_) {
        /* keep string */
      }
    }
    const hintParts = [];
    if (ev.command) hintParts.push(String(ev.command));
    if (ev.url) hintParts.push(String(ev.url));
    if (ti && typeof ti === 'object') {
      for (const k of ['path', 'file_path', 'query', 'url', 'cmd', 'command', 'name', 'message']) {
        if (typeof ti[k] === 'string' && ti[k]) {
          hintParts.push(`${k}=${ti[k]}`);
          break;
        }
      }
    }
    const desc = hintParts.join(' ').slice(0, 200);
    return {
      tool_name: `mcp:${tool}`,
      tool_input: { description: desc },
    };
  }

  return null;
}

function mapOvdResponse(body) {
  const behavior =
    body?.hookSpecificOutput?.decision?.behavior ||
    body?.hookSpecificOutput?.decision?.Behaviour;
  if (behavior === 'allow') return 'allow';
  if (behavior === 'deny') return 'deny';
  return 'ask';
}

async function main() {
  if (!ENABLED) emitNoop();

  let raw;
  try {
    raw = fs.readFileSync(0, 'utf8');
  } catch (_) {
    emitNoop();
  }
  if (!raw) emitNoop();

  let ev;
  try {
    ev = JSON.parse(raw);
  } catch (_) {
    emitNoop();
  }

  debugLog({ gate: true, ev });

  const desc = describe(ev);
  if (!desc) emitNoop();

  const body = {
    session_id: sessionId(ev),
    cwd: workspaceCwd(ev),
    tool_name: desc.tool_name,
    tool_input: desc.tool_input,
  };

  const hardStop = setTimeout(() => emitNoop(), TIMEOUT_MS + 500).unref();

  const result = await postBridge('permission-request', body, {
    timeoutMs: TIMEOUT_MS,
  });

  clearTimeout(hardStop);

  if (!result || !result.body) {
    emitNoop();
  }

  const decision = mapOvdResponse(result.body);
  if (decision === 'allow') {
    emitDecision('allow', 'OpenVibble: approved');
  }
  if (decision === 'deny') {
    emitDecision('deny', 'OpenVibble: denied');
  }
  emitNoop();
}

main();
