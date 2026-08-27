// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Combine
import CoreBluetooth
import BuddyProtocol
import BuddyPersona
import NUSCentral
import HookBridge
import Security

struct StatusAckSnapshot: Equatable {
    var batteryPct: Int?
    var batteryUsb: Bool?
    var batteryVoltageMv: Int?
    var statsLevel: Int?
    var statsApproved: Int?
    var statsVelocitySec: Int?
    var sysFirmware: String?
    var sysUptimeSec: Int?
    var xferRx: Int?
    var xferTx: Int?
    var rawJson: String?
}

@MainActor
final class AppState: ObservableObject {
    @Published var connection: CentralConnectionState = .unknown
    @Published var bluetoothNote: String = "Bluetooth state unknown"
    @Published var bluetoothPowerState: CBManagerState = .unknown
    @Published var discovered: [DiscoveredPeripheral] = []
    @Published var diagnostics: [String] = []
    @Published var connectedName: String?
    @Published var lastErrorDetail: String?

    @Published var heartbeat: HeartbeatSnapshot?
    @Published var lastAck: BridgeAck?
    @Published var lastTurn: TurnEvent?
    @Published var lastTimeSync: TimeSync?
    @Published var statusSnapshot: StatusAckSnapshot = StatusAckSnapshot()
    @Published var activityLog: [String] = []

    @Published var installProgress: InstallProgress?
    @Published var installRunning: Bool = false
    @Published var installError: String?

    @Published var pendingApproval: PendingApprovalState?
    @Published var hookActivity = HookActivityLog(capacity: 50)
    @Published var registrationStatus: HookRegistrationStatus = .notRegistered
    @Published var bridgeReady: Bool = false
    @Published var bridgePort: UInt16?

    /// When true, scans filter by `customScanPrefix` instead of the default
    /// `NUSCentralUUIDs.claudeNamePrefix`. Lets users discover peripherals
    /// that advertise under their iPhone's system name (the fallback iOS
    /// uses when the app is backgrounded and the explicit `LocalName` from
    /// the advertisement gets dropped).
    @Published var useCustomScanPrefix: Bool {
        didSet { UserDefaults.standard.set(useCustomScanPrefix, forKey: Self.keyUseCustomScanPrefix) }
    }
    @Published var customScanPrefix: String {
        didSet { UserDefaults.standard.set(customScanPrefix, forKey: Self.keyCustomScanPrefix) }
    }

    private static let keyUseCustomScanPrefix = "ovd.scan.useCustomPrefix"
    private static let keyCustomScanPrefix = "ovd.scan.customPrefix"

    struct PendingApprovalState: Equatable, Identifiable {
        let id: UUID
        let projectName: String?
        let toolName: String?
        let hint: String?
        let payload: PreToolUsePayload

        static func == (lhs: PendingApprovalState, rhs: PendingApprovalState) -> Bool {
            lhs.id == rhs.id
                && lhs.projectName == rhs.projectName
                && lhs.toolName == rhs.toolName
                && lhs.hint == rhs.hint
        }
    }

    let central = BuddyCentralService()
    lazy var installer: CharacterInstaller = CharacterInstaller(central: central)

    private var cancellables: Set<AnyCancellable> = []

    private let registrar = HookRegistrar(
        settingsURL: HookRegistrar.defaultSettingsURL(),
        portFilePath: "$HOME/.claude/openvibble.port"
    )
    private let portFileStore = PortFileStore(url: PortFileStore.defaultURL())
    private var bridgeServer: HookBridgeServer?
    private var bridgeStartTask: Task<Void, Never>?

    /// Rolling cache of synthesized hook-event log lines we ship to iOS in each
    /// outbound heartbeat's `entries` field. Newest first. iOS's
    /// `BridgeAppModel.mergeParsedEntries` uses a 16-entry dedup window, so we
    /// keep the cache slightly larger than that to survive the window but not
    /// so large that a single heartbeat balloons in size.
    private var recentHookLines: [String] = []
    private static let recentHookLinesCap = 20

    /// Per-session lifecycle derived from Claude Code hooks. SessionStart /
    /// UserPromptSubmit / Stop / SessionEnd drive this, and every outbound
    /// hook-heartbeat ships counts computed from here instead of echoing the
    /// firmware's `running`/`total` — the firmware doesn't know about Claude
    /// sessions, the desktop does. PermissionRequest stays out of this map
    /// because it's tracked per-request via `pendingApproval`.
    private enum SessionState { case idle, running }
    private var sessions: [String: SessionState] = [:]

    init() {
        let defaults = UserDefaults.standard
        self.useCustomScanPrefix = defaults.bool(forKey: Self.keyUseCustomScanPrefix)
        self.customScanPrefix = defaults.string(forKey: Self.keyCustomScanPrefix) ?? ""

        central.$connectionState
            .receive(on: DispatchQueue.main)
            .assign(to: &$connection)
        central.$bluetoothStateNote
            .receive(on: DispatchQueue.main)
            .assign(to: &$bluetoothNote)
        central.$bluetoothPowerState
            .receive(on: DispatchQueue.main)
            .assign(to: &$bluetoothPowerState)
        central.$discovered
            .receive(on: DispatchQueue.main)
            .assign(to: &$discovered)
        central.$diagnostics
            .receive(on: DispatchQueue.main)
            .assign(to: &$diagnostics)
        central.$connectedPeripheralName
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectedName)
        central.$lastErrorDetail
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastErrorDetail)

        central.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.ingest(message)
            }
        }

        installer.$progress
            .receive(on: DispatchQueue.main)
            .assign(to: &$installProgress)
        installer.$isRunning
            .receive(on: DispatchQueue.main)
            .assign(to: &$installRunning)
        installer.$lastError
            .receive(on: DispatchQueue.main)
            .assign(to: &$installError)

        refreshRegistrationStatus()
        startBridge()
    }

    deinit { bridgeStartTask?.cancel() }

    func startScan() {
        central.requestAuthorization()
        central.startScan(nameFilter: effectiveScanPrefix)
        appendLog("[scan] started filter=\(effectiveScanPrefix.isEmpty ? "<any>" : effectiveScanPrefix)")
    }

    /// Prefix currently being applied by the scanner. Empty string means the
    /// user opted in to custom mode but left the field blank — every peripheral
    /// advertising NUS will show up (service UUID is still the primary filter).
    var effectiveScanPrefix: String {
        guard useCustomScanPrefix else { return NUSCentralUUIDs.claudeNamePrefix }
        return customScanPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stopScan() {
        central.stopScan()
        appendLog("[scan] stopped")
    }

    func clearLastError() {
        central.clearLastError()
    }

    func connect(_ peripheral: DiscoveredPeripheral) {
        central.connect(id: peripheral.id)
        appendLog("[connect] \(peripheral.name) \(peripheral.id)")
    }

    func disconnect() {
        central.disconnect()
        appendLog("[disconnect] requested")
    }

    func sendStatus() {
        let ok = central.sendEncodable(StatusCommand())
        appendLog(ok ? "[send] cmd:status" : "[send] cmd:status FAILED")
    }

    func sendName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendLog("[send] cmd:name skipped (empty)")
            return
        }
        let ok = central.sendEncodable(NameCommand(name: trimmed))
        appendLog(ok ? "[send] cmd:name \(trimmed)" : "[send] cmd:name FAILED")
    }

    func sendOwner(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendLog("[send] cmd:owner skipped (empty)")
            return
        }
        let ok = central.sendEncodable(OwnerCommand(name: trimmed))
        appendLog(ok ? "[send] cmd:owner \(trimmed)" : "[send] cmd:owner FAILED")
    }

    func sendUnpair() {
        let ok = central.sendEncodable(UnpairCommand())
        appendLog(ok ? "[send] cmd:unpair" : "[send] cmd:unpair FAILED")
    }

    func sendSpecies(index: Int) {
        let ok = central.sendEncodable(SpeciesCommand(idx: index))
        let label = PersonaSpeciesCatalog.name(at: index) ?? (index == PersonaSpeciesCatalog.gifSentinel ? "gif" : "idx=\(index)")
        appendLog(ok ? "[send] cmd:species \(label) (idx=\(index))" : "[send] cmd:species FAILED")
    }

    func approveCurrentPrompt() {
        guard let id = heartbeat?.prompt?.id else {
            appendLog("[send] approve skipped (no pending prompt)")
            return
        }
        let ok = central.sendEncodable(PermissionCommand(id: id, decision: .once))
        appendLog(ok ? "[send] approve id=\(id)" : "[send] approve FAILED")
    }

    func denyCurrentPrompt() {
        guard let id = heartbeat?.prompt?.id else {
            appendLog("[send] deny skipped (no pending prompt)")
            return
        }
        let ok = central.sendEncodable(PermissionCommand(id: id, decision: .deny))
        appendLog(ok ? "[send] deny id=\(id)" : "[send] deny FAILED")
    }

    func sendTimeSync() {
        let now = Date()
        let epoch = Int64(now.timeIntervalSince1970)
        let tz = TimeZone.current.secondsFromGMT(for: now)
        let payload = TimeSync(epochSeconds: epoch, timezoneOffsetSeconds: tz)
        let ok = central.sendEncodable(payload)
        appendLog(ok ? "[send] time \(epoch) tz=\(tz)" : "[send] time FAILED")
    }

    enum HeartbeatPreset: String, CaseIterable, Identifiable {
        case idle, busy, attention, done, clearPrompt, tokenUp
        var id: String { rawValue }
    }

    /// Mirrors h5-demo's preset() at h5-demo.html:1126 — mutate the last-known
    /// heartbeat into a canned state and send it to the device. Used to smoke
    /// the renderer without waiting for Claude to cycle through states.
    func sendHeartbeatPreset(_ preset: HeartbeatPreset) {
        let base = heartbeat
        let baseTokens = base?.tokens ?? 0
        let snapshot: HeartbeatSnapshot
        switch preset {
        case .idle:
            snapshot = HeartbeatSnapshot(
                total: base?.total ?? 0,
                running: 0,
                waiting: 0,
                msg: "idle",
                entries: base?.entries ?? [],
                tokens: base?.tokens,
                tokensToday: base?.tokensToday,
                prompt: nil,
                completed: false
            )
        case .busy:
            snapshot = HeartbeatSnapshot(
                total: 4,
                running: 3,
                waiting: 0,
                msg: "running tasks",
                entries: ["10:44 npm test", "10:43 build"],
                tokens: baseTokens + 1200,
                tokensToday: base?.tokensToday,
                prompt: nil,
                completed: false
            )
        case .attention:
            let promptId = "req_\(String(UUID().uuidString.prefix(6)).lowercased())"
            snapshot = HeartbeatSnapshot(
                total: base?.total ?? 1,
                running: 1,
                waiting: 1,
                msg: "approve: Bash",
                entries: base?.entries ?? [],
                tokens: base?.tokens,
                tokensToday: base?.tokensToday,
                prompt: HeartbeatPrompt(id: promptId, tool: "Bash", hint: "rm -rf /tmp/foo"),
                completed: false
            )
        case .done:
            snapshot = HeartbeatSnapshot(
                total: base?.total ?? 0,
                running: base?.running ?? 0,
                waiting: base?.waiting ?? 0,
                msg: "turn completed",
                entries: ["10:46 done"],
                tokens: baseTokens + 900,
                tokensToday: base?.tokensToday,
                prompt: nil,
                completed: true
            )
        case .clearPrompt:
            snapshot = HeartbeatSnapshot(
                total: base?.total ?? 0,
                running: base?.running ?? 0,
                waiting: 0,
                msg: "prompt resolved",
                entries: base?.entries ?? [],
                tokens: base?.tokens,
                tokensToday: base?.tokensToday,
                prompt: nil,
                completed: base?.completed ?? false
            )
        case .tokenUp:
            snapshot = HeartbeatSnapshot(
                total: base?.total ?? 0,
                running: base?.running ?? 0,
                waiting: base?.waiting ?? 0,
                msg: "token growth +50K",
                entries: base?.entries ?? [],
                tokens: baseTokens + 50_000,
                tokensToday: base?.tokensToday,
                prompt: base?.prompt,
                completed: base?.completed ?? false
            )
        }
        let ok = central.sendEncodable(snapshot)
        appendLog(ok ? "[send] preset:\(preset.rawValue)" : "[send] preset:\(preset.rawValue) FAILED")
    }

    /// Sends one line of raw NDJSON as-is. Caller owns validity — errors from
    /// an unknown `cmd` field surface as an ack with ok=false from the device.
    func sendRawJSON(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendLog("[send] raw skipped (empty)")
            return
        }
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            appendLog("[send] raw skipped (invalid JSON)")
            return
        }
        let ok = central.sendLine(trimmed)
        appendLog(ok ? "[send] raw \(trimmed.prefix(60))" : "[send] raw FAILED")
    }

    func installCharacter(from folder: URL, name: String) {
        Task { @MainActor in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmed.isEmpty ? folder.lastPathComponent : trimmed
            appendLog("[install] begin name=\(finalName) folder=\(folder.lastPathComponent)")
            let result = await installer.install(folder: folder, characterName: finalName)
            switch result {
            case .success:
                appendLog("[install] complete")
            case .failure(let err):
                appendLog("[install] failed: \(err.localizedDescription)")
            }
        }
    }

    func cancelInstall() {
        installer.cancel()
        appendLog("[install] cancel requested")
    }

    func clearLog() {
        activityLog.removeAll()
    }

    private func ingest(_ message: CentralInboundMessage) {
        switch message {
        case .heartbeat(let snapshot):
            heartbeat = snapshot
            appendLog("[recv] heartbeat total=\(snapshot.total) running=\(snapshot.running) waiting=\(snapshot.waiting)")
        case .turn(let turn):
            lastTurn = turn
            appendLog("[recv] turn role=\(turn.role)")
        case .timeSync(let time):
            lastTimeSync = time
            appendLog("[recv] time epoch=\(time.epochSeconds) tz=\(time.timezoneOffsetSeconds)")
        case .ack(let ack):
            lastAck = ack
            if ack.ack == "status", let payload = ack.data {
                statusSnapshot = parseStatus(payload)
            }
            appendLog("[recv] ack=\(ack.ack) ok=\(ack.ok) err=\(ack.error ?? "-")")
        case .permission(let command):
            appendLog("[recv] permission id=\(command.id) decision=\(command.decision.rawValue)")
            if let pending = pendingApproval, pending.id.uuidString == command.id {
                let kind: HookEvent.PermissionDecisionKind = command.decision == .once ? .allow : .deny
                resolve(pending: pending, decision: kind)
            }
        case .unknown(let raw):
            appendLog("[recv] unknown \(raw.prefix(120))")
        }
    }

    private func parseStatus(_ value: JSONValue) -> StatusAckSnapshot {
        var snapshot = StatusAckSnapshot()
        if let bat = value["bat"] {
            snapshot.batteryPct = bat["pct"]?.intValue
            snapshot.batteryUsb = bat["usb"]?.boolValue
            snapshot.batteryVoltageMv = bat["mv"]?.intValue ?? bat["voltage"]?.intValue
        }
        if let stats = value["stats"] {
            snapshot.statsLevel = stats["lvl"]?.intValue
            snapshot.statsApproved = stats["appr"]?.intValue
            snapshot.statsVelocitySec = stats["vel"]?.intValue
        }
        if let sys = value["sys"] {
            snapshot.sysFirmware = sys["fw"]?.stringValue ?? sys["version"]?.stringValue
            snapshot.sysUptimeSec = sys["up"]?.intValue ?? sys["uptime"]?.intValue
        }
        if let xfer = value["xfer"] {
            snapshot.xferRx = xfer["rx"]?.intValue
            snapshot.xferTx = xfer["tx"]?.intValue
        }
        snapshot.rawJson = prettyPrint(value)
        return snapshot
    }

    private func prettyPrint(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let any = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: pretty, encoding: .utf8)
    }

    private func appendLog(_ line: String) {
        let stamp = DateFormatter.logStamp.string(from: Date())
        activityLog.insert("[\(stamp)] \(line)", at: 0)
        if activityLog.count > 200 {
            activityLog.removeLast(activityLog.count - 200)
        }
    }

    // MARK: - Hook bridge lifecycle

    private func startBridge() {
        let token = Self.generateToken()
        let server = HookBridgeServer(token: token) { [weak self] event, body in
            switch event {
            case .permissionRequest:
                let payload = (try? JSONDecoder().decode(PreToolUsePayload.self, from: body)) ?? PreToolUsePayload.empty
                let id = UUID()
                // Push to phone before the HTTP handler blocks waiting for a decision.
                let sem = DispatchSemaphore(value: 0)
                Task { @MainActor [weak self] in
                    self?.pushPending(id: id, payload: payload)
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 2)
                return .pendingApproval(id: id, payload: payload)
            default:
                Task { @MainActor [weak self] in
                    self?.recordFireAndForget(event: event, body: body)
                }
                return .ignore
            }
        }
        self.bridgeServer = server
        bridgeStartTask = Task { [weak self, portFileStore] in
            do {
                let port = try await server.start()
                let payload = PortFile(
                    port: Int(port),
                    token: token,
                    pid: Int(ProcessInfo.processInfo.processIdentifier),
                    version: 1
                )
                try portFileStore.write(payload)
                await MainActor.run {
                    self?.bridgePort = port
                    self?.bridgeReady = true
                    self?.appendLog("[bridge] listening on 127.0.0.1:\(port)")
                }
            } catch {
                await MainActor.run {
                    self?.appendLog("[bridge] start failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    func stopBridge() {
        bridgeStartTask?.cancel()
        let server = bridgeServer
        let store = portFileStore
        Task {
            await server?.stop()
            try? store.remove()
        }
    }

    // MARK: - Pending approval + fire-and-forget

    private func pushPending(id: UUID, payload: PreToolUsePayload) {
        let project = HookEvent.projectName(fromCwd: payload.cwd)
        let hint = (payload.toolInput?["command"]
            ?? payload.toolInput?["description"]
            ?? payload.toolInput?["file_path"]).map { String($0.prefix(120)) }
        let state = PendingApprovalState(
            id: id,
            projectName: project,
            toolName: payload.toolName,
            hint: hint,
            payload: payload
        )
        self.pendingApproval = state
        // A PermissionRequest proves Claude is actively processing this
        // session — mark it running in case we missed UserPromptSubmit (e.g.
        // app launched mid-turn).
        if let sid = payload.sessionId, !sid.isEmpty { sessions[sid] = .running }
        appendLog("[hook] PermissionRequest \(payload.toolName ?? "?") [\(project ?? "?")]")
        hookActivity.append(HookActivityEntry(
            event: .permissionRequest,
            projectName: project,
            toolName: payload.toolName
        ))
        // Stamp the event into the rolling log too so iOS sees it in the
        // parsed log even before the user decides. `pushPromptToPeripheral`
        // ships `recentHookLines` via `entries`, so iOS picks it up on the
        // same BLE write.
        appendHookLine(event: .permissionRequest, projectName: project, toolName: payload.toolName)
        pushPromptToPeripheral(state)
    }

    private func pushPromptToPeripheral(_ pending: PendingApprovalState?) {
        let base = heartbeat
        let promptInfo = Self.promptInfo(from: pending)
        let snapshot = HeartbeatSnapshot(
            total: sessionTotal(base: base),
            running: sessionRunning(),
            waiting: promptInfo == nil ? 0 : 1,
            msg: promptInfo == nil ? "cleared" : "pending",
            // Ship our rolling hook-event log instead of echoing the last
            // inbound heartbeat's entries — iOS reads `entries` into its
            // parsed-log accumulator, so we want our lines to ride every
            // outbound snapshot.
            entries: recentHookLines,
            tokens: base?.tokens,
            tokensToday: base?.tokensToday,
            prompt: promptInfo,
            completed: false
        )
        if !central.sendEncodable(snapshot) {
            appendLog("[hook] BLE prompt push failed — connect OpenVibble on phone")
        }
    }

    private static func promptInfo(from pending: PendingApprovalState?) -> HeartbeatPrompt? {
        pending.map { p in
            let label = p.hint ?? p.toolName ?? "request"
            let hintText = p.projectName.map { "[\($0)] \(label)" } ?? label
            return HeartbeatPrompt(id: p.id.uuidString, tool: p.toolName, hint: hintText)
        }
    }

    private func recordFireAndForget(event: HookEvent, body: Data) {
        let projectName = Self.extractCwd(from: body).flatMap { HookEvent.projectName(fromCwd: $0) }
        let sessionId = Self.extractSessionId(from: body)
        let title = Self.extractConversationTitle(from: body)
        let toolName = Self.extractToolDetail(from: body)
        updateSessions(event: event, sessionId: sessionId)
        hookActivity.append(HookActivityEntry(event: event, projectName: projectName))
        appendLog("[hook] \(event.rawValue) [\(projectName ?? "?")]\(title.map { " \($0)" } ?? "")")
        appendHookLine(
            event: event,
            projectName: projectName,
            toolName: toolName,
            conversationTitle: title
        )
        pushHookSnapshotToPeripheral(event: event)
    }

    private func updateSessions(event: HookEvent, sessionId: String?) {
        switch event {
        case .stop, .stopFailure:
            // Cursor stop hooks often omit session_id (hook falls back to
            // "cursor"), so the id that went running on UserPromptSubmit is
            // missed — clear every running session on turn end.
            for key in sessions.keys where sessions[key] == .running {
                sessions[key] = .idle
            }
            return
        default:
            break
        }
        guard let sid = sessionId, !sid.isEmpty else { return }
        switch event {
        case .sessionStart:
            // Register the session in idle state. UserPromptSubmit is what
            // flips it to running — SessionStart just means "this session now
            // exists" (fresh terminal, resumed session, etc.).
            if sessions[sid] == nil { sessions[sid] = .idle }
        case .userPromptSubmit, .subagentStart:
            sessions[sid] = .running
        case .subagentStop:
            // Turn finished — session goes back to idle. Keep the entry so
            // `total` still counts it; SessionEnd is what removes it.
            if sessions[sid] != nil { sessions[sid] = .idle }
        case .sessionEnd:
            sessions.removeValue(forKey: sid)
        case .preToolUse, .notification, .permissionRequest:
            break
        default:
            break
        }
    }

    /// Prepends one "HH:mm:ss event [project] tool" line into `recentHookLines`
    /// and trims to the cap. iOS parses the leading "HH:mm:ss" token as the
    /// time column and the rest as the message — same format as the embedded
    /// device already uses on its own heartbeat entries.
    private func appendHookLine(
        event: HookEvent,
        projectName: String?,
        toolName: String?,
        conversationTitle: String? = nil
    ) {
        let stamp = DateFormatter.logStamp.string(from: Date())
        var line = "\(stamp) \(event.rawValue)"
        if let project = projectName { line += " [\(project)]" }
        var detailParts: [String] = []
        if let title = conversationTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            detailParts.append(title)
        }
        if let tool = toolName?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty {
            detailParts.append(tool)
        }
        if !detailParts.isEmpty { line += " " + detailParts.joined(separator: " · ") }
        recentHookLines.insert(line, at: 0)
        if recentHookLines.count > Self.recentHookLinesCap {
            recentHookLines.removeLast(recentHookLines.count - Self.recentHookLinesCap)
        }
    }

    /// Fire-and-forget events don't have a pending-prompt of their own, so we
    /// push a heartbeat carrying the new log line plus freshly-derived session
    /// counts. `base?.prompt` is always nil (iOS heartbeats never carry a
    /// prompt field) so `self.pendingApproval` is the authoritative source for
    /// `prompt`/`waiting`. `total`/`running` come from the session map —
    /// `base?.*` is meaningless here because the firmware doesn't know about
    /// Claude sessions.
    ///
    /// `Stop` flips `completed: true` for exactly one heartbeat so iOS's
    /// `lastCompletedAt` bumps and the persona plays its celebrate overlay.
    private func pushHookSnapshotToPeripheral(event: HookEvent? = nil) {
        let base = heartbeat
        let promptInfo = Self.promptInfo(from: pendingApproval)
        let snapshot = HeartbeatSnapshot(
            total: sessionTotal(base: base),
            running: sessionRunning(),
            waiting: promptInfo == nil ? 0 : 1,
            msg: base?.msg ?? "hook",
            entries: recentHookLines,
            tokens: base?.tokens,
            tokensToday: base?.tokensToday,
            prompt: promptInfo,
            completed: event == .stop
        )
        _ = central.sendEncodable(snapshot)
    }

    private func sessionTotal(base: HeartbeatSnapshot?) -> Int {
        // Prefer session-map count once we've seen any hook traffic; fall back
        // to the firmware's last-known total before any hook fires so early
        // heartbeats don't report zero.
        sessions.isEmpty ? (base?.total ?? 0) : sessions.count
    }

    private func sessionRunning() -> Int {
        sessions.values.reduce(into: 0) { acc, s in if s == .running { acc += 1 } }
    }

    private static func extractCwd(from body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return obj["cwd"] as? String
    }

    private static func extractSessionId(from body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return obj["session_id"] as? String
    }

    private static func extractConversationTitle(from body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let title = obj["conversation_title"] as? String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
        }
        if let prompt = obj["prompt"] as? String {
            let trimmed = prompt
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(48)) }
        }
        return nil
    }

    private static func extractToolDetail(from body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let detail = obj["tool_detail"] as? String {
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(160)) }
        }
        let tool = (obj["tool_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var hint: String?
        if let ti = obj["tool_input"] as? [String: Any] {
            hint = (ti["command"] as? String)
                ?? (ti["file_path"] as? String)
                ?? (ti["path"] as? String)
                ?? (ti["description"] as? String)
        }
        hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tool, !tool.isEmpty, let hint, !hint.isEmpty {
            return String("\(tool) \(hint)".prefix(160))
        }
        if let tool, !tool.isEmpty { return String(tool.prefix(40)) }
        if let hint, !hint.isEmpty { return String(hint.prefix(160)) }
        return nil
    }

    func approvePending() {
        guard let pending = pendingApproval else { return }
        resolve(pending: pending, decision: .allow)
    }

    func denyPending() {
        guard let pending = pendingApproval else { return }
        resolve(pending: pending, decision: .deny)
    }

    private func resolve(pending: PendingApprovalState, decision: HookEvent.PermissionDecisionKind) {
        if let server = bridgeServer {
            Task { await server.resolvePending(id: pending.id, decision: decision) }
        }
        self.pendingApproval = nil
        hookActivity.append(HookActivityEntry(
            event: .permissionRequest,
            projectName: pending.projectName,
            toolName: pending.toolName,
            decision: decision
        ))
        pushPromptToPeripheral(nil)
        appendLog("[hook] decide \(decision.rawValue) id=\(pending.id)")
    }

    // MARK: - Registration

    func registerHooks() {
        do {
            try registrar.register()
            refreshRegistrationStatus()
            appendLog("[hook] registered")
        } catch {
            appendLog("[hook] register failed: \(error.localizedDescription)")
        }
    }

    func unregisterHooks() {
        do {
            try registrar.unregister()
            refreshRegistrationStatus()
            appendLog("[hook] unregistered")
        } catch {
            appendLog("[hook] unregister failed: \(error.localizedDescription)")
        }
    }

    func refreshRegistrationStatus() {
        do { registrationStatus = try registrar.status() }
        catch { registrationStatus = .notRegistered }
    }

    var bluetoothStateKey: String {
        switch bluetoothPowerState {
        case .poweredOn: return "desktop.bt.on"
        case .poweredOff: return "desktop.bt.off"
        case .unauthorized: return "desktop.bt.unauth"
        case .unsupported: return "desktop.bt.unsupported"
        case .resetting: return "desktop.bt.resetting"
        case .unknown: return "desktop.bt.unknown"
        @unknown default: return "desktop.bt.unknown"
        }
    }
}

extension PreToolUsePayload {
    static let empty = PreToolUsePayload(
        sessionId: nil, cwd: nil, toolName: nil, toolInput: nil, transcriptPath: nil
    )
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case let .object(dict) = self { return dict[key] }
        return nil
    }

    var intValue: Int? {
        if case let .number(v) = self { return Int(v) }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(v) = self { return v }
        return nil
    }

    var stringValue: String? {
        if case let .string(v) = self { return v }
        return nil
    }
}

private extension DateFormatter {
    static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
