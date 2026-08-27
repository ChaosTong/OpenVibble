'use strict';

const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');

const DEFAULT_PORT_FILE = path.join(os.homedir(), '.claude', 'openvibble.port');
const SESSION_CACHE_FILE = path.join(os.homedir(), '.claude', 'openvibble.cursor-session');
const TITLE_CACHE_FILE = path.join(os.homedir(), '.claude', 'openvibble.cursor-titles.json');

const TITLE_MAX_LEN = Number(process.env.OVD_CURSOR_TITLE_MAX_LEN || 48);

function truncateTitle(text) {
  const oneLine = String(text || '')
    .replace(/\s+/g, ' ')
    .trim();
  if (!oneLine) return '';
  if (oneLine.length <= TITLE_MAX_LEN) return oneLine;
  return `${oneLine.slice(0, TITLE_MAX_LEN - 1)}…`;
}

function readTitleMap() {
  try {
    const raw = fs.readFileSync(TITLE_CACHE_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch (_) {
    return {};
  }
}

function writeTitleMap(map) {
  try {
    fs.mkdirSync(path.dirname(TITLE_CACHE_FILE), { recursive: true });
    fs.writeFileSync(TITLE_CACHE_FILE, JSON.stringify(map, null, 0));
  } catch (_) {}
}

function rememberTitle(sessionId, text) {
  const id = String(sessionId || '').trim();
  const title = truncateTitle(text);
  if (!id || !title) return;
  const map = readTitleMap();
  map[id] = title;
  writeTitleMap(map);
}

function recallTitle(sessionId) {
  const id = String(sessionId || '').trim();
  if (!id) return null;
  const title = readTitleMap()[id];
  return title ? String(title) : null;
}

function forgetTitle(sessionId) {
  const id = String(sessionId || '').trim();
  if (!id) return;
  const map = readTitleMap();
  if (!Object.prototype.hasOwnProperty.call(map, id)) return;
  delete map[id];
  writeTitleMap(map);
}

/** Attach cached conversation title; seed from beforeSubmitPrompt text. */
function enrichBody(ev, base) {
  const out = { ...base };
  const hookName = ev.hook_event_name || ev.event || '';
  const sid = out.session_id || sessionId(ev);

  if (hookName === 'beforeSubmitPrompt') {
    const prompt =
      ev.prompt || ev.user_prompt || ev.userPrompt || ev.text || '';
    const title = truncateTitle(prompt);
    if (title) rememberTitle(sid, title);
  }
  if (hookName === 'sessionEnd') {
    forgetTitle(sid);
  }

  const title = recallTitle(sid);
  if (title) out.conversation_title = title;
  return out;
}

function rememberSession(id) {
  const s = String(id || '').trim();
  if (!s || s === 'cursor') return;
  try {
    fs.mkdirSync(path.dirname(SESSION_CACHE_FILE), { recursive: true });
    fs.writeFileSync(SESSION_CACHE_FILE, s);
  } catch (_) {}
}

function recallSession() {
  try {
    const s = fs.readFileSync(SESSION_CACHE_FILE, 'utf8').trim();
    return s || null;
  } catch (_) {
    return null;
  }
}

function readPortFile() {
  const file = process.env.OVD_PORT_FILE || DEFAULT_PORT_FILE;
  try {
    const raw = fs.readFileSync(file, 'utf8');
    const parsed = JSON.parse(raw);
    const port = Number(parsed.port);
    const token = String(parsed.token || '');
    if (!port || !token) return null;
    return { port, token, file };
  } catch (_) {
    return null;
  }
}

function postBridge(endpoint, bodyObj, options = {}) {
  const bridge = readPortFile();
  if (!bridge) return Promise.resolve(null);

  const timeoutMs = options.timeoutMs ?? 500;
  const payload = JSON.stringify(bodyObj);
  const reqPath = endpoint.startsWith('/') ? endpoint : `/${endpoint}`;

  return new Promise((resolve) => {
    const req = http.request(
      {
        hostname: '127.0.0.1',
        port: bridge.port,
        path: reqPath,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload),
          'X-OVD-Token': bridge.token,
        },
      },
      (res) => {
        let buf = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          buf += chunk;
        });
        res.on('end', () => {
          if (res.statusCode === 401 || res.statusCode === 404) {
            resolve(null);
            return;
          }
          if (!buf.trim()) {
            resolve({ status: res.statusCode, body: null });
            return;
          }
          try {
            resolve({ status: res.statusCode, body: JSON.parse(buf) });
          } catch (_) {
            resolve({ status: res.statusCode, body: null });
          }
        });
      },
    );

    req.setTimeout(timeoutMs, () => {
      req.destroy();
      resolve(null);
    });
    req.on('error', () => resolve(null));
    req.write(payload);
    req.end();
  });
}

function sessionId(ev) {
  const fromEvent = ev.session_id || ev.sessionId || ev.conversation_id;
  if (fromEvent) {
    const id = String(fromEvent);
    rememberSession(id);
    return id;
  }
  return recallSession() || 'cursor';
}

function workspaceCwd(ev) {
  if (ev.cwd) return String(ev.cwd);
  if (ev.workspace_path) return String(ev.workspace_path);
  if (ev.project_path) return String(ev.project_path);
  if (Array.isArray(ev.workspace_roots) && ev.workspace_roots[0]) {
    return String(ev.workspace_roots[0]);
  }
  return undefined;
}

function debugLog(entry) {
  if (process.env.CURSOR_HOOK_DEBUG !== '1') return;
  try {
    fs.appendFileSync(
      '/tmp/openvibble-cursor-hook-debug.jsonl',
      JSON.stringify({ ts: Date.now(), ...entry }) + '\n',
    );
  } catch (_) {}
}

module.exports = {
  readPortFile,
  postBridge,
  sessionId,
  workspaceCwd,
  enrichBody,
  debugLog,
};
