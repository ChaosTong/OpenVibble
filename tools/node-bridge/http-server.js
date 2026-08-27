'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');
const { PATH_TO_EVENT } = require('./session-state');
const { buildPreset, buildCommand } = require('./presets');

const UI_PATH = path.join(__dirname, 'public', 'index.html');

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function parseRequest(req, body) {
  const [pathOnly] = (req.url || '/').split('?');
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    headers[String(k).toLowerCase()] = String(v);
  }
  return {
    method: req.method || 'GET',
    path: pathOnly,
    headers,
    body,
  };
}

function sendJson(res, status, obj) {
  const data = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(data),
    Connection: 'close',
  });
  res.end(data);
}

function send204(res) {
  res.writeHead(204, { Connection: 'close' });
  res.end();
}

function sendHtml(res, html, extraHeaders = {}) {
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    Connection: 'close',
    ...extraHeaders,
  });
  res.end(html);
}

function parseJsonBody(bodyBuf) {
  if (!bodyBuf.length) return {};
  return JSON.parse(bodyBuf.toString('utf8'));
}

function pushBle(ble, payload, onLog, label) {
  if (!ble) {
    onLog(`[web] ${label} skipped — BLE disabled`);
    return { ok: false, error: 'ble_disabled' };
  }
  const ok = ble.sendSnapshot
    ? ble.sendSnapshot(payload)
    : ble.sendRaw(JSON.stringify(payload));
  if (!ok) onLog(`[web] ${label} failed — phone not connected`);
  return { ok, ble: ble.connected };
}

/**
 * @param {{
 *   token: string,
 *   state: import('./session-state').SessionState,
 *   ble: import('./ble-proxy').createBleProxy|null,
 *   activity: import('./activity-log').createActivityLog,
 *   onLog: (m:string)=>void,
 *   getPort: () => number,
 * }} deps
 */
function createServer(deps) {
  const { token, state, ble, activity, onLog, getPort } = deps;

  function authOk(request) {
    return request.headers['x-ovd-token'] === token;
  }

  function statusPayload() {
    const snap = state.getSnapshot();
    return {
      name: 'OpenVibbleNodeBridge',
      ready: true,
      version: '0.1.0',
      port: getPort(),
      ble: {
        enabled: Boolean(ble),
        connected: ble?.connected ?? false,
        ready: ble?.ready ?? false,
        deviceName: ble?.deviceName ?? null,
        connectedDeviceId: ble?.connectedDeviceId ?? null,
        scanning: ble?.scanning ?? false,
        autoConnect: ble?.autoConnect ?? false,
        bluetoothState: ble?.bluetoothState ?? 'unknown',
        devices: ble?.devices ?? [],
      },
      sessions: {
        total: snap.total,
        running: snap.running,
        waiting: snap.waiting,
      },
      entries: snap.entries,
      activity: activity.all(),
    };
  }

  return http.createServer(async (req, res) => {
    try {
      const bodyBuf = await readBody(req);
      const request = parseRequest(req, bodyBuf);

      if (request.method === 'GET' && request.path === '/health') {
        return sendJson(res, 200, {
          name: 'OpenVibbleNodeBridge',
          ready: true,
          version: '0.1.0',
          ble: ble?.connected ?? false,
        });
      }

      if (request.method === 'GET' && (request.path === '/' || request.path === '/ui')) {
        let html = fs.readFileSync(UI_PATH, 'utf8');
        html = html
          .replaceAll('__OVD_TOKEN__', token)
          .replaceAll('__OVD_PORT__', String(getPort()));
        return sendHtml(res, html, { 'Cache-Control': 'no-store' });
      }

      if (request.method === 'GET' && request.path === '/api/status') {
        return sendJson(res, 200, statusPayload());
      }

      if (!authOk(request)) {
        res.writeHead(401, { Connection: 'close' });
        return res.end();
      }

      if (request.method === 'POST' && request.path === '/api/activity/clear') {
        activity.clear();
        onLog('[web] activity cleared');
        return send204(res);
      }

      if (request.method === 'POST' && request.path === '/api/ble/preset') {
        let json;
        try {
          json = parseJsonBody(bodyBuf);
        } catch (_) {
          return sendJson(res, 400, { ok: false, error: 'invalid_json' });
        }
        const snapshot = buildPreset(String(json.preset || ''), state);
        if (!snapshot) {
          return sendJson(res, 400, { ok: false, error: 'unknown_preset' });
        }
        const result = pushBle(ble, snapshot, onLog, `preset:${json.preset}`);
        return sendJson(res, 200, result);
      }

      if (request.method === 'POST' && request.path === '/api/ble/scan') {
        let json;
        try {
          json = parseJsonBody(bodyBuf);
        } catch (_) {
          return sendJson(res, 400, { ok: false, error: 'invalid_json' });
        }
        if (!ble) {
          return sendJson(res, 200, { ok: false, error: 'ble_disabled' });
        }
        const action = String(json.action || 'start');
        if (action === 'stop') {
          const sent = ble.sendControl({ type: 'scan_stop' });
          if (!sent) {
            return sendJson(res, 200, {
              ok: false,
              error: ble.ready ? 'ble_send_failed' : 'ble_not_ready',
            });
          }
          onLog('[web] scan stop');
          return sendJson(res, 200, { ok: true });
        }
        const prefix = json.prefix != null ? String(json.prefix) : 'Claude';
        const sent = ble.sendControl({
          type: 'scan_start',
          prefix,
          clear: json.clear !== false,
        });
        if (!sent) {
          onLog('[web] scan start failed — BLE not ready');
          return sendJson(res, 200, {
            ok: false,
            error: ble.ready ? 'ble_send_failed' : 'ble_not_ready',
            ble: { ready: ble.ready, connected: ble.connected },
          });
        }
        onLog(`[web] scan start prefix=${prefix || '<any>'}`);
        return sendJson(res, 200, { ok: true, scanning: true });
      }

      if (request.method === 'POST' && request.path === '/api/ble/connect') {
        let json;
        try {
          json = parseJsonBody(bodyBuf);
        } catch (_) {
          return sendJson(res, 400, { ok: false, error: 'invalid_json' });
        }
        const id = String(json.id || '').trim();
        if (!id) return sendJson(res, 400, { ok: false, error: 'missing_id' });
        if (!ble) {
          return sendJson(res, 200, { ok: false, error: 'ble_disabled' });
        }
        ble.sendControl({ type: 'connect', id });
        onLog(`[web] connect ${id}`);
        return sendJson(res, 200, { ok: true });
      }

      if (request.method === 'POST' && request.path === '/api/ble/disconnect') {
        if (!ble) {
          return sendJson(res, 200, { ok: false, error: 'ble_disabled' });
        }
        ble.sendControl({ type: 'disconnect' });
        onLog('[web] disconnect');
        return sendJson(res, 200, { ok: true });
      }

      if (request.method === 'POST' && request.path === '/api/ble/auto-connect') {
        let json = {};
        try {
          if (bodyBuf.length) json = parseJsonBody(bodyBuf);
        } catch (_) {
          return sendJson(res, 400, { ok: false, error: 'invalid_json' });
        }
        if (!ble) {
          return sendJson(res, 200, { ok: false, error: 'ble_disabled' });
        }
        const value = json.value !== false;
        ble.sendControl({ type: 'auto_connect', value });
        onLog(`[web] auto_connect=${value}`);
        return sendJson(res, 200, { ok: true });
      }

      if (request.method === 'POST' && request.path === '/api/ble/command') {
        let json;
        try {
          json = parseJsonBody(bodyBuf);
        } catch (_) {
          return sendJson(res, 400, { ok: false, error: 'invalid_json' });
        }
        const payload = buildCommand(String(json.command || ''), json);
        if (!payload) {
          return sendJson(res, 400, { ok: false, error: 'invalid_command' });
        }
        if (!ble) {
          onLog(`[web] cmd:${json.command} skipped — BLE disabled`);
          return sendJson(res, 200, { ok: false, error: 'ble_disabled' });
        }
        const ok = ble.sendRaw(JSON.stringify(payload));
        onLog(ok ? `[web] cmd:${json.command}` : `[web] cmd:${json.command} FAILED`);
        return sendJson(res, 200, { ok, ble: ble.connected });
      }

      if (request.method === 'POST' && request.path === '/api/ble/raw') {
        let json;
        try {
          json = parseJsonBody(bodyBuf);
        } catch (_) {
          return sendJson(res, 400, { ok: false, error: 'invalid_json' });
        }
        const line = String(json.line || json.json || '').trim();
        if (!line) return sendJson(res, 400, { ok: false, error: 'empty' });
        try {
          JSON.parse(line);
        } catch (_) {
          return sendJson(res, 400, { ok: false, error: 'invalid_json_line' });
        }
        if (!ble) {
          return sendJson(res, 200, { ok: false, error: 'ble_disabled' });
        }
        const ok = ble.sendRaw(line);
        onLog(ok ? `[web] raw ${line.slice(0, 60)}` : '[web] raw FAILED');
        return sendJson(res, 200, { ok, ble: ble.connected });
      }

      if (request.method === 'POST' && request.path === '/api/test/hook') {
        let json;
        try {
          json = parseJsonBody(bodyBuf);
        } catch (_) {
          return sendJson(res, 400, { ok: false, error: 'invalid_json' });
        }
        const hookPath = String(json.path || '').replace(/^\//, '');
        if (!PATH_TO_EVENT[hookPath]) {
          return sendJson(res, 400, { ok: false, error: 'unknown_hook' });
        }
        const body = json.body && typeof json.body === 'object' ? json.body : {};
        const result = state.record(hookPath, body);
        if (result) {
          onLog(`[web] test hook ${result.line}`);
          if (ble) {
            const ok = ble.sendSnapshot(result.snapshot);
            if (!ok) onLog('[web] BLE push skipped — phone not connected');
          }
        }
        return sendJson(res, 200, { ok: true, line: result?.line ?? null });
      }

      const hookPath = request.path.replace(/^\//, '');

      if (request.method === 'POST' && hookPath === 'permission-request') {
        return sendJson(res, 200, {
          hookSpecificOutput: { hookEventName: 'PermissionRequest' },
        });
      }

      if (request.method === 'POST' && PATH_TO_EVENT[hookPath]) {
        let json = {};
        if (bodyBuf.length) {
          try {
            json = parseJsonBody(bodyBuf);
          } catch (_) {
            res.writeHead(400, { Connection: 'close' });
            return res.end();
          }
        }
        const result = state.record(hookPath, json);
        if (result) {
          onLog(`[hook] ${result.event} ${result.line}`);
          if (ble) {
            const ok = ble.sendSnapshot(result.snapshot);
            if (!ok) onLog('[hook] BLE push skipped — phone not connected');
          }
        }
        return send204(res);
      }

      res.writeHead(404, { Connection: 'close' });
      res.end();
    } catch (e) {
      onLog(`HTTP error: ${e.message}`);
      res.writeHead(500, { Connection: 'close' });
      res.end();
    }
  });
}

module.exports = { createServer };
