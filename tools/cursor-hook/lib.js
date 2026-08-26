'use strict';

const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');

const DEFAULT_PORT_FILE = path.join(os.homedir(), '.claude', 'openvibble.port');

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
  return ev.session_id || ev.sessionId || ev.conversation_id || 'cursor';
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
  debugLog,
};
