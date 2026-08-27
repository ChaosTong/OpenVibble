#!/usr/bin/env node
//
// Cursor IDE gateable pre-execution hook → OpenVibble Desktop /permission-request.
//
// Only true blocking gates reach the phone:
//   - beforeMCPExecution (any MCP call)
//   - preToolUse for MCP wrappers, Task, and file tools (Write/Edit/StrReplace/…)
//
// File tools: gated by default so phone matches Cursor "Pending approval".
// Set OVD_CURSOR_GATE_WRITES=0 to pass through file edits (MCP gates unchanged).
//
// Shell, Read, Grep, beforeShellExecution, and other hooks pass through
// immediately (exit 0, no stdout) — Cursor fail-open, no phone spam.

'use strict';

const fs = require('fs');
const { postBridge, sessionId, workspaceCwd, debugLog } = require('./lib');

const TIMEOUT_MS = Number(process.env.OVD_CURSOR_PERMISSION_TIMEOUT_MS || 30000);
const ENABLED = (process.env.OVD_CURSOR_PERMISSION_ECHO || '1') !== '0';
const GATE_WRITES = (process.env.OVD_CURSOR_GATE_WRITES || '1') !== '0';

/** preToolUse tool_name values that match Cursor's real confirm UX. */
const GATE_TOOLS = new Set([
  'CallDynamicTool',
  'GetDynamicTool',
  'FetchMcpResource',
  'Task',
]);

/** Optional file mutations (auto-run in Agent — off by default). */
const GATE_FILE_TOOLS = new Set([
  'Write',
  'Edit',
  'StrReplace',
  'Delete',
  'ApplyPatch',
  'apply_patch',
  'Patch',
]);

/** Case-insensitive aliases. */
const GATE_TOOLS_LOWER = new Set([
  'calldynamictool',
  'getdynamictool',
  'fetchmcpresource',
  'task',
  'write',
  'edit',
  'strreplace',
  'delete',
  'applypatch',
  'apply_patch',
  'patch',
]);

/** Never send these to the phone — not blocking confirm UX in Cursor. */
const PASS_THROUGH_TOOLS = new Set(['Shell', 'Read', 'Grep']);

function isMcpWrapperTool(tool) {
  const t = String(tool || '');
  return (
    t === 'CallDynamicTool' ||
    t === 'GetDynamicTool' ||
    t === 'FetchMcpResource' ||
    t.toLowerCase() === 'calldynamictool' ||
    t.toLowerCase() === 'getdynamictool' ||
    t.toLowerCase() === 'fetchmcpresource'
  );
}

function isGatedTool(tool) {
  const t = String(tool || '');
  if (!t) return false;
  if (GATE_TOOLS.has(t)) return true;
  if (GATE_WRITES && GATE_FILE_TOOLS.has(t)) return true;
  const lower = t.toLowerCase();
  if (GATE_TOOLS_LOWER.has(lower)) {
    if (GATE_FILE_TOOLS.has(t) || ['write', 'edit', 'strreplace', 'delete', 'applypatch', 'apply_patch', 'patch'].includes(lower)) {
      return GATE_WRITES;
    }
    return true;
  }
  if (t.startsWith('MCP') || t.startsWith('mcp')) return true;
  return false;
}

function auditLog(entry) {
  try {
    fs.appendFileSync(
      '/tmp/openvibble-cursor-hook-audit.jsonl',
      JSON.stringify({ ts: Date.now(), ...entry }) + '\n',
    );
  } catch (_) {}
}

function emitPassThrough(reason) {
  debugLog({ gate: true, pass_through: reason });
  process.exit(0);
}

function emitAsk(reason) {
  const body = { permission: 'ask' };
  if (reason) {
    body.user_message = reason;
    body.agent_message = reason;
  }
  process.stdout.write(JSON.stringify(body) + '\n');
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

/** Cursor sometimes omits hook_event_name; infer from payload shape. */
function eventName(ev) {
  const explicit = ev.hook_event_name || ev.event || '';
  if (explicit) return explicit;

  if (ev.tool_name != null) {
    const tool = String(ev.tool_name);
    if (
      ev.mcp_server_name != null ||
      ev.url != null ||
      tool.startsWith('MCP:') ||
      isMcpWrapperTool(tool)
    ) {
      return ev.mcp_server_name != null || ev.url != null || tool.startsWith('MCP:')
        ? 'beforeMCPExecution'
        : 'preToolUse';
    }
    if (isGatedTool(tool)) {
      return 'preToolUse';
    }
  }

  if (typeof ev.command === 'string' && ev.tool_name == null && ev.mcp_server_name == null) {
    return 'beforeShellExecution';
  }

  return '';
}

/**
 * Whitelist: only blocking hooks + gated tools POST to the phone.
 * @returns {{ gate: boolean, reason?: string }}
 */
function shouldGatePhone(ev, hookName) {
  const tool = ev.tool_name != null ? String(ev.tool_name) : '';

  if (hookName === 'beforeShellExecution' || hookName === 'beforeReadFile') {
    return { gate: false, reason: hookName };
  }
  if (PASS_THROUGH_TOOLS.has(tool)) {
    return { gate: false, reason: `tool:${tool}` };
  }
  if (hookName === 'beforeMCPExecution') {
    return { gate: true };
  }
  if (hookName === 'preToolUse') {
    if (isGatedTool(tool)) {
      return { gate: true };
    }
    return { gate: false, reason: `preToolUse-not-gated:${tool || '?'}` };
  }
  return { gate: false, reason: `hook-not-blocking:${hookName || '?'}` };
}

function flattenToolInput(raw) {
  if (raw == null) return {};
  if (typeof raw === 'string') {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        return flattenToolInput(parsed);
      }
    } catch (_) {
      return { description: raw.slice(0, 200) };
    }
    return { description: raw.slice(0, 200) };
  }
  if (typeof raw !== 'object') return {};
  const out = {};
  for (const [k, v] of Object.entries(raw)) {
    if (typeof v === 'string') out[k] = v.slice(0, 200);
    else if (typeof v === 'number' || typeof v === 'boolean') out[k] = String(v);
  }
  return out;
}

function describe(ev, hookName) {
  if (hookName === 'beforeMCPExecution') {
    const tool = String(ev.tool_name || ev.tool || 'mcp').slice(0, 40);
    const ti = flattenToolInput(ev.tool_input);
    const hintParts = [];
    if (ev.command) hintParts.push(String(ev.command));
    if (ev.url) hintParts.push(String(ev.url));
    if (ev.mcp_server_name) hintParts.push(String(ev.mcp_server_name));
    for (const k of ['path', 'file_path', 'query', 'url', 'cmd', 'command', 'name', 'message']) {
      if (ti[k]) {
        hintParts.push(`${k}=${ti[k]}`);
        break;
      }
    }
    const desc = hintParts.join(' ').slice(0, 200);
    return {
      tool_name: `mcp:${tool}`,
      tool_input: { description: desc || JSON.stringify(ti).slice(0, 200) },
    };
  }

  if (hookName === 'preToolUse') {
    const tool = String(ev.tool_name || 'tool').slice(0, 40);
    const ti = flattenToolInput(ev.tool_input);
    let hint =
      ti.command ||
      ti.path ||
      ti.file_path ||
      ti.description ||
      JSON.stringify(ti).slice(0, 200);
    if (isMcpWrapperTool(tool)) {
      const ns = ti.namespace || ti.server || '';
      const tn = ti.toolName || ti.tool_name || ti.uri || '';
      hint = [ns, tn].filter(Boolean).join('/') || hint;
    }
    return {
      tool_name: isMcpWrapperTool(tool) ? `mcp:${tool.toLowerCase()}` : tool.toLowerCase(),
      tool_input: { command: String(hint).slice(0, 200) },
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
  if (!ENABLED) emitPassThrough('disabled');

  let raw;
  try {
    raw = fs.readFileSync(0, 'utf8');
  } catch (_) {
    emitPassThrough('stdin-error');
  }
  if (!raw) emitPassThrough('empty-input');

  let ev;
  try {
    ev = JSON.parse(raw);
  } catch (_) {
    emitPassThrough('invalid-json');
  }

  const hookName = eventName(ev);
  const { gate, reason } = shouldGatePhone(ev, hookName);
  auditLog({
    hook_event: ev.hook_event_name,
    resolved_event: hookName,
    tool_name: ev.tool_name,
    mcp_server: ev.mcp_server_name,
    phone_gate: gate,
    pass_reason: reason,
  });
  debugLog({
    gate: true,
    resolved_event: hookName,
    tool_name: ev.tool_name,
    phone_gate: gate,
    pass_reason: reason,
    ev,
  });

  if (!gate) {
    emitPassThrough(reason);
  }

  const desc = describe(ev, hookName);
  if (!desc) emitPassThrough('no-description');

  try {
    fs.appendFileSync(
      '/tmp/openvibble-cursor-hook-debug.jsonl',
      JSON.stringify({
        ts: Date.now(),
        phone_request: true,
        hookName,
        tool: ev.tool_name,
        tool_name_out: desc.tool_name,
        hint: desc.tool_input?.command,
      }) + '\n',
    );
  } catch (_) {}

  const body = {
    session_id: sessionId(ev),
    cwd: workspaceCwd(ev),
    tool_name: desc.tool_name,
    tool_input: desc.tool_input,
  };

  const hardStop = setTimeout(() => emitAsk('OpenVibble: approval timeout'), TIMEOUT_MS + 500).unref();

  const result = await postBridge('permission-request', body, {
    timeoutMs: TIMEOUT_MS,
  });

  clearTimeout(hardStop);

  if (!result || !result.body) {
    emitAsk('OpenVibble: desktop bridge unavailable — approve in Cursor');
  }

  const decision = mapOvdResponse(result.body);
  if (decision === 'allow') {
    emitDecision('allow', 'OpenVibble: approved');
  }
  if (decision === 'deny') {
    emitDecision('deny', 'OpenVibble: denied');
  }
  emitAsk('OpenVibble: no decision — approve in Cursor');
}

main();
