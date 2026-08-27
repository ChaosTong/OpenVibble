import Foundation
import CoreBluetooth
import Darwin

private let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
private let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

/// NDJSON lines to a unix-socket client. Uses raw write() so a disconnected peer
/// never raises NSFileHandleOperationException (which would kill the helper).
final class LineEmitter {
    private var fd: Int32
    private var alive = true

    init(fileDescriptor fd: Int32, closeOnDealloc: Bool = false) {
        self.fd = fd
        _ = closeOnDealloc // socket lifetime owned by ClientSession
    }

    func invalidate() {
        alive = false
    }

    func emit(_ obj: [String: Any]) {
        guard alive, fd >= 0 else { return }
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var sent = 0
            while sent < bytes.count {
                let n = write(fd, base + sent, bytes.count - sent)
                if n > 0 {
                    sent += n
                    continue
                }
                if n == 0 || errno == EPIPE || errno == EBADF || errno == ENOTCONN {
                    alive = false
                }
                break
            }
        }
    }
}

/// Tracks one unix-socket client; replaces previous client without tearing down BLE.
final class ClientSession {
    private var readSource: DispatchSourceRead?
    private var buffer = ""
    private let clientFD: Int32
    private let onLine: ([String: Any]) -> Void
    private let onDisconnect: () -> Void

    init(clientFD: Int32, onLine: @escaping ([String: Any]) -> Void, onDisconnect: @escaping () -> Void) {
        self.clientFD = clientFD
        self.onLine = onLine
        self.onDisconnect = onDisconnect
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: .global(qos: .utility))
        readSource = source
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [clientFD] in
            close(clientFD)
        }
        source.resume()
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(clientFD, &buf, buf.count)
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            detach()
            onDisconnect()
            return
        }
        if n == 0 {
            detach()
            onDisconnect()
            return
        }
        guard let chunk = String(bytes: buf[0..<n], encoding: .utf8) else { return }
        buffer += chunk
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            onLine(obj)
        }
    }

    func detach() {
        readSource?.setEventHandler {}
        readSource?.cancel()
        readSource = nil
        buffer = ""
    }

    deinit { detach() }
}

final class Bridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?
    private var namePrefix: String
    private var emitter: LineEmitter
    private var connected = false
    private var autoConnect = true
    private var wantsScan = true
    private var scanning = false
    private var discovered: [String: (name: String, rssi: Int, peripheral: CBPeripheral)] = [:]

    init(namePrefix: String, emitter: LineEmitter) {
        self.namePrefix = namePrefix
        self.emitter = emitter
        super.init()
    }

    private func ensureManager() -> CBCentralManager {
        if let manager { return manager }
        let created = CBCentralManager(delegate: self, queue: nil)
        manager = created
        return created
    }

    func attachClient(clientFD: Int32, onAcceptNext: @escaping () -> Void) -> ClientSession {
        emitter = LineEmitter(fileDescriptor: clientFD, closeOnDealloc: false)
        emitter.emit(["type": "ready"])
        emitScanState()
        emitDiscoveredCache()
        if connected, let p = peripheral {
            let id = p.identifier.uuidString
            let name = p.name ?? discovered[id]?.name ?? "?"
            if discovered[id] == nil {
                discovered[id] = (name: name, rssi: 0, peripheral: p)
            }
            emitter.emit([
                "type": "discovered",
                "device": ["id": id, "name": name, "rssi": discovered[id]?.rssi ?? 0],
            ])
            setConnected(true, name: name, id: id)
        }
        let session = ClientSession(clientFD: clientFD, onLine: { [weak self] obj in
            self?.handleCommand(obj)
        }, onDisconnect: { [weak self] in
            self?.emitter.invalidate()
            onAcceptNext()
        })
        // Defer CoreBluetooth init so the socket handshake completes first.
        DispatchQueue.main.async { [weak self] in
            _ = self?.ensureManager()
        }
        return session
    }

    private func log(_ text: String) {
        emitter.emit(["type": "log", "text": text])
    }

    private func emitScanState() {
        emitter.emit(["type": "scan_state", "scanning": scanning, "auto_connect": autoConnect])
    }

    private func setConnected(_ value: Bool, name: String? = nil, id: String? = nil) {
        connected = value
        var msg: [String: Any] = ["type": "connected", "value": value]
        if let name { msg["name"] = name }
        if let id { msg["id"] = id }
        emitter.emit(msg)
    }

    private func emitDiscoveredCache() {
        for (id, entry) in discovered.sorted(by: { $0.value.rssi > $1.value.rssi }) {
            emitter.emit([
                "type": "discovered",
                "device": ["id": id, "name": entry.name, "rssi": entry.rssi],
            ])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = stateName(central.state)
        log("BLE state=\(state)")
        emitter.emit(["type": "ble_state", "state": state])
        switch central.state {
        case .poweredOn:
            if wantsScan && !connected { beginScan() }
        case .unauthorized:
            log("BLE unauthorized — System Settings → Privacy → Bluetooth → enable “OpenVibble BLE Helper”")
            setConnected(false)
            stopScanning()
        default:
            setConnected(false)
            stopScanning()
        }
    }

    private func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "other"
        }
    }

    private func beginScan() {
        let manager = ensureManager()
        guard manager.state == .poweredOn, wantsScan, !connected else { return }
        manager.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true,
        ])
        scanning = true
        emitScanState()
        log("BLE scan started filter=\(namePrefix.isEmpty ? "<any>" : namePrefix)")
    }

    private func stopScanning() {
        guard scanning, let manager else { return }
        manager.stopScan()
        scanning = false
        emitScanState()
        log("BLE scan stopped")
    }

    private func nameMatches(_ name: String) -> Bool {
        if namePrefix.isEmpty { return true }
        return name.lowercased().hasPrefix(namePrefix.lowercased())
    }

    private func recordDiscovery(_ peripheral: CBPeripheral, name: String, rssi: Int) {
        let id = peripheral.identifier.uuidString
        discovered[id] = (name: name, rssi: rssi, peripheral: peripheral)
        emitter.emit([
            "type": "discovered",
            "device": ["id": id, "name": name, "rssi": rssi],
        ])
    }

    private func connectPeripheral(_ target: CBPeripheral, label: String) {
        stopScanning()
        peripheral = target
        target.delegate = self
        log("BLE connecting \(label)…")
        ensureManager().connect(target, options: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ""
        guard nameMatches(advertised) else { return }
        recordDiscovery(peripheral, name: advertised, rssi: RSSI.intValue)
        guard autoConnect, !connected else { return }
        connectPeripheral(peripheral, label: advertised)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("BLE linked \(peripheral.name ?? "?")")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("BLE connect error: \(error?.localizedDescription ?? "unknown")")
        resetPeripheral()
        if wantsScan { beginScan() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("BLE disconnected")
        resetPeripheral()
        if wantsScan {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.beginScan() }
        }
    }

    private func resetPeripheral() {
        setConnected(false)
        peripheral?.delegate = nil
        peripheral = nil
        rxChar = nil
        txChar = nil
    }

    func userDisconnect() {
        wantsScan = false
        stopScanning()
        if let p = peripheral, let manager {
            manager.cancelPeripheralConnection(p)
        } else {
            resetPeripheral()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("BLE discover services: \(error.localizedDescription)")
            manager?.cancelPeripheralConnection(peripheral)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            log("BLE NUS service missing")
            manager?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("BLE discover chars: \(error.localizedDescription)")
            manager?.cancelPeripheralConnection(peripheral)
            return
        }
        for c in service.characteristics ?? [] {
            if c.uuid == rxUUID { rxChar = c }
            if c.uuid == txUUID {
                txChar = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
        guard rxChar != nil else {
            log("BLE missing RX")
            manager?.cancelPeripheralConnection(peripheral)
            return
        }
        setConnected(true, name: peripheral.name ?? "?", id: peripheral.identifier.uuidString)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == txUUID, let data = characteristic.value else { return }
        let text = String(data: data, encoding: .utf8) ?? ""
        log("BLE ← \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))")
    }

    func handleCommand(_ obj: [String: Any]) {
        guard let type = obj["type"] as? String else { return }
        switch type {
        case "scan_start":
            autoConnect = false
            wantsScan = true
            if obj["clear"] as? Bool ?? true { discovered.removeAll() }
            if let prefix = obj["prefix"] as? String { namePrefix = prefix }
            if let p = peripheral, let manager {
                manager.cancelPeripheralConnection(p)
                resetPeripheral()
            } else {
                resetPeripheral()
            }
            beginScan()
        case "scan_stop":
            wantsScan = false
            stopScanning()
        case "auto_connect":
            autoConnect = obj["value"] as? Bool ?? true
            wantsScan = true
            emitScanState()
            log("BLE auto_connect=\(autoConnect)")
            if autoConnect && !connected { beginScan() }
        case "connect":
            autoConnect = false
            wantsScan = false
            guard let id = obj["id"] as? String else { return }
            if let entry = discovered[id] {
                connectPeripheral(entry.peripheral, label: entry.name)
            } else if let uuid = UUID(uuidString: id),
                      let found = ensureManager().retrievePeripherals(withIdentifiers: [uuid]).first {
                connectPeripheral(found, label: found.name ?? id)
            } else {
                log("BLE connect failed: unknown id \(id)")
            }
        case "disconnect":
            userDisconnect()
        case "snapshot":
            if let snap = obj["data"] as? [String: Any],
               JSONSerialization.isValidJSONObject(snap),
               let data = try? JSONSerialization.data(withJSONObject: snap),
               let line = String(data: data, encoding: .utf8) {
                _ = sendLine(line)
            }
        case "raw":
            if let text = obj["line"] as? String { _ = sendLine(text) }
        default:
            break
        }
    }

    private func sendLine(_ line: String) -> Bool {
        guard connected, let p = peripheral, let rx = rxChar else { return false }
        let payload = line.hasSuffix("\n") ? line : line + "\n"
        let data = Data(payload.utf8)
        let type: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        let mtu = max(20, p.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < data.count {
            let end = min(offset + mtu, data.count)
            p.writeValue(data.subdata(in: offset..<end), for: rx, type: type)
            offset = end
        }
        return true
    }
}

private func runProbe() {
    let emitter = LineEmitter(fileDescriptor: STDOUT_FILENO)
    final class Probe: NSObject, CBCentralManagerDelegate {
        let emitter: LineEmitter
        init(_ emitter: LineEmitter) { self.emitter = emitter }
        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            emitter.emit(["type": "log", "text": "probe state=\(central.state.rawValue)"])
            exit(0)
        }
    }
    _ = CBCentralManager(delegate: Probe(emitter), queue: nil)
    RunLoop.main.run()
}

private func bindUnixSocket(_ path: String) -> Int32? {
    func tryBind() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        path.withCString { cstr in
            strncpy(&addr.sun_path.0, cstr, maxLen)
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len) == 0
            }
        }
        guard ok, listen(fd, 1) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    unlink(path)
    if let fd = tryBind() { return fd }
    // Stale socket file — unlink again and retry once.
    unlink(path)
    return tryBind()
}

private func pidAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

private func redirectStderrToLog() {
    let path = NSHomeDirectory() + "/Library/Logs/openvibble-ble-helper.log"
    path.withCString { cstr in
        freopen(cstr, "a", stderr)
    }
}

private func runServe(socketPath: String) {
    redirectStderrToLog()
    let pidPath = socketPath + ".pid"
    if let existing = try? String(contentsOfFile: pidPath, encoding: .utf8),
       let n = Int32(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
       n > 1, pidAlive(n) {
        fputs("helper already running pid=\(n)\n", stderr)
        exit(0)
    }

    guard let listenFD = bindUnixSocket(socketPath) else {
        fputs("bind failed for \(socketPath)\n", stderr)
        exit(1)
    }
    fputs("listening on \(socketPath) pid=\(getpid())\n", stderr)
    try? "\(getpid())".write(toFile: pidPath, atomically: true, encoding: .utf8)

    let prefix = ProcessInfo.processInfo.environment["OVD_BLE_NAME_PREFIX"] ?? "Claude"
    var bridge: Bridge?
    var client: ClientSession?

    func acceptNext() {
        DispatchQueue.global(qos: .userInitiated).async {
            let clientFD = accept(listenFD, nil, nil)
            DispatchQueue.main.async {
                guard clientFD >= 0 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { acceptNext() }
                    return
                }
                if bridge == nil {
                    bridge = Bridge(
                        namePrefix: prefix,
                        emitter: LineEmitter(fileDescriptor: STDOUT_FILENO)
                    )
                }
                // New node client replaces any previous (e.g. daemon restart); keep BLE state.
                client?.detach()
                client = bridge!.attachClient(clientFD: clientFD, onAcceptNext: acceptNext)
            }
        }
    }

    acceptNext()
    RunLoop.main.run()
}

let args = CommandLine.arguments
if args.contains("--probe") {
    runProbe()
} else if let idx = args.firstIndex(of: "--serve"), idx + 1 < args.count {
    runServe(socketPath: args[idx + 1])
} else {
    fputs("Usage: mac-ble-helper --probe | --serve <unix-socket-path>\n", stderr)
    exit(2)
}
