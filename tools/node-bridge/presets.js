'use strict';

/** @param {import('./session-state').SessionState} state */
function buildPreset(preset, state) {
  const base = state.lastSnapshot || state.getSnapshot('hook');
  const baseTokens = base.tokens ?? 0;

  switch (preset) {
    case 'idle':
      return {
        ...base,
        running: 0,
        waiting: 0,
        msg: 'idle',
        prompt: null,
        completed: false,
      };
    case 'busy':
      return {
        total: 4,
        running: 3,
        waiting: 0,
        msg: 'running tasks',
        entries: ['10:44 npm test', '10:43 build'],
        tokens: baseTokens + 1200,
        tokens_today: base.tokens_today ?? null,
        prompt: null,
        completed: false,
      };
    case 'attention': {
      const promptId = `req_${Math.random().toString(36).slice(2, 8)}`;
      return {
        total: base.total || 1,
        running: 1,
        waiting: 1,
        msg: 'approve: Bash',
        entries: base.entries || [],
        tokens: base.tokens ?? null,
        tokens_today: base.tokens_today ?? null,
        prompt: { id: promptId, tool: 'Bash', hint: 'rm -rf /tmp/foo' },
        completed: false,
      };
    }
    case 'done':
      return {
        ...base,
        msg: 'turn completed',
        entries: ['10:46 done', ...(base.entries || []).slice(0, 78)],
        tokens: baseTokens + 900,
        prompt: null,
        completed: true,
      };
    case 'clearPrompt':
      return {
        ...base,
        waiting: 0,
        msg: 'prompt resolved',
        prompt: null,
      };
    case 'tokenUp':
      return {
        ...base,
        msg: 'token growth +50K',
        tokens: baseTokens + 50000,
      };
    default:
      return null;
  }
}

function buildCommand(command, payload = {}) {
  switch (command) {
    case 'status':
      return { cmd: 'status' };
    case 'unpair':
      return { cmd: 'unpair' };
    case 'name': {
      const name = String(payload.name || '').trim();
      if (!name) return null;
      return { cmd: 'name', name };
    }
    case 'owner': {
      const name = String(payload.name || '').trim();
      if (!name) return null;
      return { cmd: 'owner', name };
    }
    case 'time': {
      const now = Math.floor(Date.now() / 1000);
      const tz = -new Date().getTimezoneOffset() * 60;
      return { time: [now, tz] };
    }
    default:
      return null;
  }
}

module.exports = { buildPreset, buildCommand };
