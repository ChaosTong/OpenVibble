#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { SessionState } = require('./session-state');
const { createServer } = require('./http-server');
const { createBleProxy, assertSingleInstance } = require('./ble-proxy');
const { createActivityLog } = require('./activity-log');

const PORT_FILE =
  process.env.OVD_PORT_FILE ||
  path.join(os.homedir(), '.claude', 'openvibble.port');
const HOST = process.env.OVD_DAEMON_HOST || '127.0.0.1';
const PORT = Number(process.env.OVD_DAEMON_PORT || 52847);
const BLE_PREFIX = process.env.OVD_BLE_NAME_PREFIX || 'Claude';
const BLE_ENABLED = (process.env.OVD_DAEMON_BLE || '1') !== '0';

if (!Number.isFinite(PORT) || PORT < 1 || PORT > 65535) {
  console.error(`Invalid OVD_DAEMON_PORT: ${process.env.OVD_DAEMON_PORT}`);
  process.exit(1);
}

const activity = createActivityLog();
function log(msg) {
  activity.append(msg);
}

function writePortFile(port, token) {
  const dir = path.dirname(PORT_FILE);
  fs.mkdirSync(dir, { recursive: true });
  const payload = {
    port,
    token,
    pid: process.pid,
    version: 1,
  };
  fs.writeFileSync(PORT_FILE, JSON.stringify(payload), { mode: 0o600 });
  log(`port file ${PORT_FILE} → 127.0.0.1:${port}`);
}

function removePortFile() {
  try {
    fs.unlinkSync(PORT_FILE);
  } catch (_) {}
}

async function main() {
  try {
    assertSingleInstance((m) => activity.append(m));
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }

  const token = crypto.randomBytes(24).toString('base64');
  const state = new SessionState();
  let ble = null;
  const port = PORT;

  if (BLE_ENABLED) {
    ble = createBleProxy({
      onLog: log,
      env: { ...process.env, OVD_BLE_NAME_PREFIX: BLE_PREFIX },
    });
  }

  const server = createServer({
    token,
    state,
    ble,
    activity,
    onLog: log,
    getPort: () => port,
  });

  await new Promise((resolve, reject) => {
    server.on('error', (err) => {
      if (err.code === 'EADDRINUSE') {
        reject(new Error(`port ${PORT} already in use — stop other bridge or set OVD_DAEMON_PORT`));
        return;
      }
      reject(err);
    });
    server.listen(PORT, HOST, () => resolve());
  });

  writePortFile(port, token);
  log(`listening http://${HOST}:${port} (BLE prefix "${BLE_PREFIX}")`);
  log(`web UI: http://${HOST}:${port}/`);
  log('Open OpenVibble on iPhone; hooks use same ~/.claude/openvibble.port');
  if (ble) {
    log('BLE bridge starting (mac-ble-helper via open -a)');
    log('If BLE fails: pkill -x mac-ble-helper; rm -f ~/.claude/openvibble-ble.sock ~/.claude/openvibble-ble.sock.pid');
  }

  const shutdown = () => {
    log('shutting down');
    server.close();
    removePortFile();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
