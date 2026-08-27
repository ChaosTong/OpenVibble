'use strict';

const { BleCentral } = require('./ble-central');

const namePrefix = process.env.OVD_BLE_NAME_PREFIX || 'Claude';

function send(msg) {
  if (process.send) process.send(msg);
}

function onLog(text) {
  send({ type: 'log', text });
}

const ble = new BleCentral({
  namePrefix,
  onLog,
  onConnectedChange: (connected, name) =>
    send({ type: 'connected', value: connected, name: name || null }),
});

process.on('message', (msg) => {
  if (!msg) return;
  if (msg.type === 'snapshot') ble.sendSnapshot(msg.data);
  if (msg.type === 'raw') ble.sendLine(msg.line);
});

(async () => {
  const ok = await ble.loadNoble();
  if (!ok) {
    send({ type: 'fatal', reason: 'noble load failed' });
    process.exit(1);
  }
  ble.start();
  send({ type: 'ready' });
})().catch((e) => {
  onLog(`BLE worker error: ${e.message}`);
  process.exit(1);
});

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
