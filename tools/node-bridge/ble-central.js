'use strict';

const NUS_SERVICE = '6e400001b5a3f393e0a9e50e24dcca9e';
const NUS_RX = '6e400002b5a3f393e0a9e50e24dcca9e';
const NUS_TX = '6e400003b5a3f393e0a9e50e24dcca9e';

function normalizeUuid(u) {
  return String(u).replace(/-/g, '').toLowerCase();
}

class BleCentral {
  /**
   * @param {{ namePrefix?: string, onLog?: (msg: string) => void }} opts
   */
  constructor(opts = {}) {
    this.namePrefix = opts.namePrefix || 'Claude';
    this.onLog = opts.onLog || (() => {});
    this.onConnectedChange = opts.onConnectedChange || (() => {});
    this.noble = null;
    this.peripheral = null;
    this.rxChar = null;
    this.txChar = null;
    this.connected = false;
    this.scanning = false;
    this._wantConnect = true;
  }

  async loadNoble() {
    try {
      this.noble = require('@abandonware/noble');
      return true;
    } catch (e) {
      this.onLog(`BLE: install @abandonware/noble — ${e.message}`);
      return false;
    }
  }

  start() {
    if (!this.noble) return;
    this.noble.on('stateChange', (state) => {
      this.onLog(`BLE state=${state}`);
      if (state === 'poweredOn') {
        setTimeout(() => this.beginScan(), 250);
      } else if (state === 'unauthorized') {
        this.onLog(
          'BLE unauthorized — System Settings → Privacy & Security → Bluetooth → enable for Terminal (or Node if using launchd)',
        );
        this.connected = false;
        this.onConnectedChange(false);
        this.scanning = false;
      } else {
        this.connected = false;
        this.onConnectedChange(false);
        this.scanning = false;
      }
    });
    if (this.noble.state === 'poweredOn') {
      setTimeout(() => this.beginScan(), 250);
    }
  }

  beginScan() {
    if (!this.noble || this.scanning || this.connected) return;
    if (this.noble.state !== 'poweredOn') return;
    this.scanning = true;
    this.noble.removeAllListeners('discover');
    this.noble.on('discover', (peripheral) => this.onDiscover(peripheral));
    try {
      // Scan all peripherals; filter by name in onDiscover. Service-only
      // filters can abort on some macOS / noble builds when BT is restricted.
      this.noble.startScanning([], false);
      this.onLog('BLE scan started');
    } catch (e) {
      this.scanning = false;
      this.onLog(`BLE scan failed: ${e.message}`);
    }
  }

  onDiscover(peripheral) {
    if (!this._wantConnect || this.connected) return;
    const name = peripheral.advertisement?.localName || peripheral.address || '?';
    if (!String(name).startsWith(this.namePrefix)) return;
    this.noble.stopScanning();
    this.scanning = false;
    this.onLog(`BLE found ${name}, connecting…`);
    peripheral.connect((err) => {
      if (err) {
        this.onLog(`BLE connect error: ${err.message}`);
        this.beginScan();
        return;
      }
      this.peripheral = peripheral;
      peripheral.discoverSomeServicesAndCharacteristics(
        [NUS_SERVICE],
        [NUS_RX, NUS_TX],
        (err2, services, characteristics) => {
          if (err2) {
            this.onLog(`BLE discover error: ${err2.message}`);
            this.disconnect();
            return;
          }
          for (const c of characteristics) {
            const id = normalizeUuid(c.uuid);
            if (id === normalizeUuid(NUS_RX)) this.rxChar = c;
            if (id === normalizeUuid(NUS_TX)) this.txChar = c;
          }
          if (!this.rxChar) {
            this.onLog('BLE missing RX characteristic');
            this.disconnect();
            return;
          }
          this.connected = true;
          this.deviceName = name;
          this.onConnectedChange(true, name);
          this.onLog(`BLE connected ${name}`);
          if (this.txChar) {
            this.txChar.subscribe((e) => {
              if (e) this.onLog(`BLE notify subscribe: ${e.message}`);
            });
            this.txChar.on('data', (data) => {
              this.onLog(`BLE ← ${data.toString('utf8').trim().slice(0, 120)}`);
            });
          }
          peripheral.on('disconnect', () => {
            this.onLog('BLE disconnected');
            this.connected = false;
            this.onConnectedChange(false);
            this.rxChar = null;
            this.txChar = null;
            this.peripheral = null;
            setTimeout(() => this.beginScan(), 1500);
          });
        },
      );
    });
  }

  disconnect() {
    if (this.peripheral) {
      try {
        this.peripheral.disconnect();
      } catch (_) {}
    }
    this.connected = false;
    this.beginScan();
  }

  /** @param {object} snapshot HeartbeatSnapshot */
  sendSnapshot(snapshot) {
    return this.sendLine(JSON.stringify(snapshot));
  }

  sendLine(text) {
    if (!this.connected || !this.rxChar) return false;
    const line = String(text).endsWith('\n') ? String(text) : `${text}\n`;
    const data = Buffer.from(line, 'utf8');
    const chunk = 180;
    for (let i = 0; i < data.length; i += chunk) {
      this.rxChar.write(data.subarray(i, i + chunk), false);
    }
    return true;
  }
}

module.exports = { BleCentral };
