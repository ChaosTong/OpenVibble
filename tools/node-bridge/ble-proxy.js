'use strict';

const { fork, spawn, execSync } = require('child_process');
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');

const MAC_APP = path.join(__dirname, 'mac-ble-helper.app');
const MAC_HELPER = path.join(MAC_APP, 'Contents', 'MacOS', 'mac-ble-helper');
const SOCK =
  process.env.OVD_BLE_SOCKET ||
  path.join(os.homedir(), '.claude', 'openvibble-ble.sock');

const MAX_LAUNCH_FAILURES = 8;
const RECONNECT_MS = 2000;
const HELPER_LOG = path.join(os.homedir(), 'Library', 'Logs', 'openvibble-ble-helper.log');

function helperRunning() {
  try {
    execSync('pgrep -x mac-ble-helper >/dev/null 2>&1');
    return true;
  } catch (_) {
    return false;
  }
}

const SOCK_PID = `${SOCK}.pid`;

function helperPidFromFile() {
  try {
    const n = parseInt(fs.readFileSync(SOCK_PID, 'utf8').trim(), 10);
    return Number.isFinite(n) ? n : null;
  } catch (_) {
    return null;
  }
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (_) {
    return false;
  }
}

function readPortFilePid() {
  const portFile =
    process.env.OVD_PORT_FILE ||
    path.join(os.homedir(), '.claude', 'openvibble.port');
  try {
    const data = JSON.parse(fs.readFileSync(portFile, 'utf8'));
    const pid = Number(data?.pid);
    return Number.isFinite(pid) ? pid : null;
  } catch (_) {
    return null;
  }
}

function assertSingleInstance(onLog) {
  const pid = readPortFilePid();
  if (pid && pidAlive(pid) && pid !== process.pid) {
    const msg = `Another node-bridge is already running (pid ${pid}). Stop it first: pkill -f "node index.js"`;
    onLog(msg);
    throw new Error(msg);
  }
}

function restartHelperProcess(onLog) {
  onLog('BLE: restarting mac-ble-helper (stale or unreachable socket)');
  try {
    execSync('pkill -x mac-ble-helper 2>/dev/null || true', { stdio: 'ignore' });
  } catch (_) {}
  removeStaleArtifacts(onLog);
}

function removeStaleArtifacts(onLog) {
  // Never unlink while helper is alive — path may still be in use (unlink breaks listen).
  if (helperRunning()) return;
  for (const p of [SOCK, SOCK_PID]) {
    try {
      if (fs.existsSync(p)) {
        fs.unlinkSync(p);
        onLog(`BLE: removed ${path.basename(p)}`);
      }
    } catch (_) {}
  }
}

function createBleProxy({ onLog, env = process.env }) {
  let socket = null;
  let connected = false;
  let ready = false;
  let deviceName = null;
  let connectedDeviceId = null;
  let launchFailures = 0;
  let disabled = false;
  let mode = 'none';
  let reconnectTimer = null;
  let connecting = false;
  let socketGen = 0;
  /** @type {Map<string, {id:string,name:string,rssi:number,lastSeen:number}>} */
  const discoveredDevices = new Map();
  let scanning = false;
  let autoConnect = true;
  let bluetoothState = 'unknown';

  function bleDevicesForStatus() {
    const list = [...discoveredDevices.values()];
    if (connected && deviceName) {
      const id = connectedDeviceId || 'connected';
      if (!list.some((d) => d.id === id || d.name === deviceName)) {
        list.unshift({
          id,
          name: deviceName,
          rssi: list.find((d) => d.id === connectedDeviceId)?.rssi ?? 0,
          lastSeen: Date.now(),
        });
      }
    }
    return list.sort((a, b) => b.rssi - a.rssi);
  }

  function handleMessage(msg) {
    if (!msg) return;
    switch (msg.type) {
      case 'log':
        onLog(msg.text);
        break;
      case 'connected':
        connected = Boolean(msg.value);
        deviceName = msg.name || null;
        connectedDeviceId = connected && msg.id ? String(msg.id) : null;
        if (connected && msg.id) {
          const id = String(msg.id);
          const prev = discoveredDevices.get(id);
          discoveredDevices.set(id, {
            id,
            name: String(msg.name || deviceName || '?'),
            rssi: prev?.rssi ?? 0,
            lastSeen: Date.now(),
          });
        }
        if (connected) launchFailures = 0;
        break;
      case 'ready':
        ready = true;
        launchFailures = 0;
        break;
      case 'discovered': {
        const d = msg.device;
        if (d && d.id) {
          discoveredDevices.set(String(d.id), {
            id: String(d.id),
            name: String(d.name || '?'),
            rssi: Number(d.rssi || 0),
            lastSeen: Date.now(),
          });
        }
        break;
      }
      case 'scan_state':
        scanning = Boolean(msg.scanning);
        if (typeof msg.auto_connect === 'boolean') autoConnect = msg.auto_connect;
        break;
      case 'ble_state':
        if (msg.state) bluetoothState = String(msg.state);
        break;
      case 'fatal':
        onLog(`BLE helper fatal: ${msg.reason || 'unknown'}`);
        break;
      case 'error':
        if (msg.reason) onLog(`BLE helper error: ${msg.reason}`);
        break;
      default:
        break;
    }
  }

  function cleanupSocket() {
    const oldSocket = socket;
    socket = null;
    connected = false;
    ready = false;
    deviceName = null;
    connectedDeviceId = null;

    if (oldSocket) {
      oldSocket.removeAllListeners();
      try {
        oldSocket.destroy();
      } catch (_) {}
    }
  }

  function scheduleReconnect(why, delayMs = RECONNECT_MS) {
    if (reconnectTimer) return;
    cleanupSocket();
    if (disabled) return;
    const reuse = helperRunning() ? 'reuse helper' : 'spawn helper';
    onLog(`BLE reconnect in ${delayMs}ms (${why}, ${reuse})`);
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connectWorker();
    }, delayMs);
  }

  function attachSocket(stream) {
    if (socket === stream) return;
    cleanupSocket();
    const gen = ++socketGen;
    socket = stream;
    let buf = '';

    stream.on('data', (chunk) => {
      buf += chunk.toString('utf8');
      for (;;) {
        const nl = buf.indexOf('\n');
        if (nl < 0) break;
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        try {
          handleMessage(JSON.parse(line));
        } catch (_) {}
      }
    });

    stream.on('close', () => {
      if (gen === socketGen) scheduleReconnect('socket closed');
    });
    stream.on('error', (err) => {
      if (gen === socketGen) scheduleReconnect(err.message);
    });
  }

  function spawnMacHelper() {
    return new Promise((resolve, reject) => {
      if (helperRunning()) {
        onLog('BLE: skip spawn — mac-ble-helper already running');
        resolve();
        return;
      }
      fs.mkdirSync(path.dirname(SOCK), { recursive: true });
      fs.mkdirSync(path.dirname(HELPER_LOG), { recursive: true });
      onLog(`BLE: launch mac-ble-helper.app (--serve) → ${SOCK}`);
      // Must launch via `open -a` so macOS loads the .app Info.plist for Bluetooth TCC.
      // Direct spawn of Contents/MacOS/binary aborts with privacy violation on macOS 15+.
      const child = spawn(
        'open',
        ['-g', '-n', '-a', MAC_APP, '--args', '--serve', SOCK],
        {
          env,
          detached: true,
          stdio: 'ignore',
        },
      );
      child.on('error', reject);
      child.unref();
      setTimeout(resolve, 1200);
    });
  }

  async function tryConnectOnce() {
    return new Promise((resolve, reject) => {
      const s = net.createConnection(SOCK);
      s.setKeepAlive(true);
      s.once('connect', () => resolve(s));
      s.once('error', (err) => {
        if ((err.code === 'ECONNREFUSED' || err.code === 'ENOENT') && !helperRunning()) {
          removeStaleArtifacts(onLog);
        }
        reject(err);
      });
    });
  }

  async function waitForSocket(retries = 50) {
    for (let i = 0; i < retries; i += 1) {
      try {
        return await tryConnectOnce();
      } catch (_) {
        await new Promise((r) => setTimeout(r, 200));
      }
    }
    return null;
  }

  async function ensureHelperRunning() {
    const pidFromFile = helperPidFromFile();
    if (pidFromFile && pidAlive(pidFromFile)) {
      const existing = await waitForSocket(40);
      if (existing) return existing;
      onLog(`BLE: helper pid=${pidFromFile} alive but socket unreachable — restarting`);
      restartHelperProcess(onLog);
      await new Promise((r) => setTimeout(r, 600));
    } else if (helperRunning()) {
      const existing = await waitForSocket(25);
      if (existing) return existing;
      onLog('BLE: helper alive but socket dead — restarting helper');
      restartHelperProcess(onLog);
      await new Promise((r) => setTimeout(r, 600));
    } else {
      removeStaleArtifacts(onLog);
    }

    if (!helperRunning()) {
      try {
        await spawnMacHelper();
      } catch (e) {
        launchFailures += 1;
        onLog(`BLE spawn failed: ${e.message}`);
        throw new Error(`launch failed: ${e.message}`);
      }
    }

    const stream = await waitForSocket(60);
    if (!stream) {
      launchFailures += 1;
      let hint = '';
      try {
        hint = fs.readFileSync(HELPER_LOG, 'utf8').slice(-300);
      } catch (_) {}
      onLog(`BLE helper log: ${HELPER_LOG}`);
      if (hint) onLog(`BLE helper tail: ${hint.replace(/\n/g, ' | ')}`);
      throw new Error('socket connect timeout');
    }
    return stream;
  }

  async function connectWorker() {
    if (disabled || connecting) return;
    connecting = true;
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }

    try {
      if (process.platform === 'darwin') {
        if (!fs.existsSync(MAC_HELPER)) {
          disabled = true;
          onLog('BLE disabled — run: bash mac-ble-helper/build.sh');
          return;
        }
        mode = 'mac-socket';
        const stream = await ensureHelperRunning();
        attachSocket(stream);
        onLog('BLE: connected to mac-ble-helper socket');
        return;
      }

      mode = 'noble';
      onLog('BLE: using @abandonware/noble');
      const worker = fork(path.join(__dirname, 'ble-worker.js'), [], {
        env,
        stdio: ['pipe', 'pipe', 'pipe', 'ipc'],
      });
      worker.on('message', handleMessage);
      worker.on('exit', (code, signal) => {
        scheduleReconnect(String(signal || code));
      });
      socket = worker;
      ready = false;
    } catch (e) {
      onLog(e.message);
      if (launchFailures >= MAX_LAUNCH_FAILURES) {
        disabled = true;
        onLog('BLE disabled after repeated launch failures');
      } else {
        scheduleReconnect('launch failed');
      }
    } finally {
      connecting = false;
    }
  }

  function sendToWorker(msg) {
    if (!socket || !ready) return false;
    if (mode === 'mac-socket') {
      try {
        socket.write(`${JSON.stringify(msg)}\n`);
        return true;
      } catch (_) {
        return false;
      }
    }
    socket.send(msg);
    return true;
  }

  connectWorker();

  return {
    get connected() {
      return connected;
    },
    get ready() {
      return ready;
    },
    get deviceName() {
      return deviceName;
    },
    get connectedDeviceId() {
      return connectedDeviceId;
    },
    get disabled() {
      return disabled;
    },
    get scanning() {
      return scanning;
    },
    get autoConnect() {
      return autoConnect;
    },
    get bluetoothState() {
      return bluetoothState;
    },
    get devices() {
      return bleDevicesForStatus();
    },
    sendControl(payload) {
      if (payload.type === 'scan_start' && payload.clear !== false) {
        discoveredDevices.clear();
      }
      return sendToWorker(payload);
    },
    sendSnapshot(snapshot) {
      if (!sendToWorker({ type: 'snapshot', data: snapshot })) return false;
      return connected;
    },
    sendRaw(line) {
      if (!sendToWorker({ type: 'raw', line })) return false;
      return connected;
    },
  };
}

module.exports = { createBleProxy, assertSingleInstance };
