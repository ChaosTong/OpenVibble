'use strict';

const RECENT_CAP = 80;

const PATH_TO_EVENT = {
  pretooluse: 'PreToolUse',
  prompt: 'UserPromptSubmit',
  stop: 'Stop',
  'stop-failure': 'StopFailure',
  notification: 'Notification',
  'session-start': 'SessionStart',
  'session-end': 'SessionEnd',
  'subagent-start': 'SubagentStart',
  'subagent-stop': 'SubagentStop',
};

function projectName(cwd) {
  if (!cwd) return null;
  const parts = String(cwd).replace(/\/+$/, '').split('/');
  const last = parts[parts.length - 1];
  return last && last !== '/' ? last : null;
}

function extractConversationTitle(body) {
  if (body.conversation_title) {
    const t = String(body.conversation_title).trim();
    if (t) return t.slice(0, 120);
  }
  if (body.prompt) {
    const t = String(body.prompt).replace(/\n/g, ' ').trim();
    if (t) return t.slice(0, 48);
  }
  return null;
}

function extractToolDetail(body) {
  if (body.tool_detail) {
    const t = String(body.tool_detail).trim();
    if (t) return t.slice(0, 160);
  }
  const tool = body.tool_name ? String(body.tool_name).trim() : '';
  const ti = body.tool_input && typeof body.tool_input === 'object' ? body.tool_input : {};
  const hint =
    ti.command || ti.file_path || ti.path || ti.description || '';
  const h = String(hint).trim();
  if (tool && h) return `${tool} ${h}`.slice(0, 160);
  if (tool) return tool.slice(0, 40);
  if (h) return h.slice(0, 160);
  return null;
}

function logStamp() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}

class SessionState {
  constructor() {
    /** @type {Map<string, 'idle'|'running'>} */
    this.sessions = new Map();
    /** @type {string[]} newest first */
    this.recentHookLines = [];
    /** @type {object|null} */
    this.lastSnapshot = null;
  }

  getSnapshot(msg = 'hook') {
    return {
      total: this.sessionTotal(),
      running: this.sessionRunning(),
      waiting: 0,
      msg,
      entries: [...this.recentHookLines],
      tokens: null,
      tokens_today: null,
      prompt: null,
    };
  }

  /** @param {string} hookPath e.g. "stop" */
  record(hookPath, body) {
    const event = PATH_TO_EVENT[hookPath];
    if (!event) return null;

    const sid = body.session_id ? String(body.session_id) : '';
    this.updateSessions(event, sid);

    const line = this.appendHookLine(
      event,
      projectName(body.cwd),
      extractToolDetail(body),
      extractConversationTitle(body),
    );

    const completed = event === 'Stop';
    const snapshot = {
      total: this.sessionTotal(),
      running: this.sessionRunning(),
      waiting: 0,
      msg: 'hook',
      entries: [...this.recentHookLines],
      tokens: null,
      tokens_today: null,
      prompt: null,
      completed: completed || undefined,
    };
    this.lastSnapshot = snapshot;

    return { event, line, snapshot, completed };
  }

  updateSessions(event, sessionId) {
    if (event === 'Stop' || event === 'StopFailure') {
      for (const [key, state] of this.sessions) {
        if (state === 'running') this.sessions.set(key, 'idle');
      }
      return;
    }
    if (!sessionId) return;
    switch (event) {
      case 'SessionStart':
        if (!this.sessions.has(sessionId)) this.sessions.set(sessionId, 'idle');
        break;
      case 'UserPromptSubmit':
      case 'SubagentStart':
        this.sessions.set(sessionId, 'running');
        break;
      case 'SubagentStop':
        if (this.sessions.has(sessionId)) this.sessions.set(sessionId, 'idle');
        break;
      case 'SessionEnd':
        this.sessions.delete(sessionId);
        break;
      default:
        break;
    }
  }

  appendHookLine(event, projectName, toolDetail, conversationTitle) {
    let line = `${logStamp()} ${event}`;
    if (projectName) line += ` [${projectName}]`;
    const parts = [];
    if (conversationTitle) parts.push(conversationTitle);
    if (toolDetail) parts.push(toolDetail);
    if (parts.length) line += ` ${parts.join(' · ')}`;
    if (this.recentHookLines[0] !== line) {
      this.recentHookLines.unshift(line);
    }
    if (this.recentHookLines.length > RECENT_CAP) {
      this.recentHookLines.length = RECENT_CAP;
    }
    return line;
  }

  sessionTotal() {
    return this.sessions.size;
  }

  sessionRunning() {
    let n = 0;
    for (const s of this.sessions.values()) if (s === 'running') n += 1;
    return n;
  }
}

module.exports = {
  SessionState,
  PATH_TO_EVENT,
  projectName,
};
