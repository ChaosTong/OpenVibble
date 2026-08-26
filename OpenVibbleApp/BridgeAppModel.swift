// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import UIKit
import Combine
import CoreBluetooth
import BridgeRuntime
import NUSPeripheral
import BuddyProtocol
import BuddyStorage
import BuddyStats
import BuddyPersona

@MainActor
final class BridgeAppModel: ObservableObject {
    @Published private(set) var snapshot: BridgeSnapshot = .empty
    @Published private(set) var prompt: PromptRequest?
    @Published private(set) var transfer: TransferProgress = .idle
    @Published private(set) var connectionState: NUSConnectionState = .stopped
    @Published private(set) var bluetoothStateNote: String = "蓝牙状态未知"
    @Published private(set) var bluetoothPowerState: CBManagerState = .unknown
    @Published private(set) var advertisingNote: String = "未广播"
    @Published private(set) var activeDisplayName: String = "Claude"
    @Published private(set) var diagnosticLogs: [String] = []
    @Published private(set) var recentEvents: [String] = []
    /// Client-side accumulation of heartbeat `entries`. The bridge replaces
    /// its list every heartbeat (see REFERENCE.md — "capped to a few"), so
    /// `snapshot.entries` by itself never grows past ~3 items. We merge each
    /// heartbeat into a longer scrollback here, newest first, deduping
    /// against a sliding window so a line that stays in the bridge's top-N
    /// across several heartbeats doesn't get re-prepended.
    @Published private(set) var parsedEntries: [String] = []
    private static let parsedEntriesMax = 200
    private static let parsedEntriesDedupWindow = 16
    @Published private(set) var lastInstalledCharacter: String?
    @Published private(set) var recentLevelUp: Bool = false
    @Published private(set) var lastQuickApprovalAt: Date?
    /// Bumped each time a heartbeat with `completed: true` arrives. Drives a
    /// 3-second celebrate animation via `PersonaController` — matches the h5
    /// demo's `triggerOneShot("celebrate", 3000)` and the firmware's
    /// `P_CELEBRATE` state derivation.
    @Published private(set) var lastCompletedAt: Date?
    /// True once the user has responded to the current prompt but the desktop
    /// has not yet cleared it from the next heartbeat. Used by the prompt
    /// panel to swap the "A approve / B deny" hint for a "SENT" state so
    /// users see immediate feedback instead of the waited-timer ticking on.
    @Published private(set) var responseSent: Bool = false
    /// Mirrors `BuddyPeripheralService.authorizationState` so views can react
    /// to the user granting/denying the BLE permission.
    @Published private(set) var bluetoothAuthorization: CBManagerAuthorization = CBPeripheralManager.authorization

    private let quickApprovalThreshold: TimeInterval = 5
    private let liveActivityManager = BuddyLiveActivityManager()

    let statsStore: PersonaStatsStore

    private let runtime = BridgeRuntime()
    private let peripheral = BuddyPeripheralService()
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var lastPromptId: String?
    private var lastPromptAt: Date?
    private var statusSampleTimer: Timer?

    var charactersRootURL: URL { runtime.charactersRootURL }

    /// Per-project grouping of the rolling heartbeat entries, used by the
    /// INFO > CLAUDE page. Recomputed on every read — SwiftUI diffs the
    /// resulting list, and the input (`parsedEntries` + `prompt`) already
    /// triggers view invalidation via `@Published`.
    var projects: [ProjectSummary] {
        ProjectSummaryBuilder.build(entries: parsedEntries, hasPrompt: prompt != nil)
    }

    init(statsStore: PersonaStatsStore = PersonaStatsStore()) {
        self.statsStore = statsStore
        runtime.onCharacterInstalled = { [weak self] name in
            Task { @MainActor [weak self] in
                self?.lastInstalledCharacter = name
                self?.recordEvent("系统 已安装宠物：\(name)")
            }
        }

        runtime.onSpeciesChanged = { [weak self] idx in
            Task { @MainActor [weak self] in
                if idx == PersonaSpeciesCatalog.gifSentinel {
                    self?.recordEvent("系统 切换宠物 → GIF")
                } else if let name = PersonaSpeciesCatalog.name(at: idx) {
                    self?.recordEvent("系统 切换宠物 → \(name) (idx=\(idx))")
                }
            }
        }

        runtime.onTaskCompleted = { [weak self] in
            Task { @MainActor [weak self] in
                self?.lastCompletedAt = Date()
            }
        }

        enableBatteryMonitoring()

        peripheral.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.pushLiveActivity()
            }
            .store(in: &cancellables)

        // React to the user toggling the Live Activity preference in Settings:
        // flipping it off mid-session should tear down any running activity
        // immediately instead of waiting for the next heartbeat.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pushLiveActivity()
            }
            .store(in: &cancellables)

        peripheral.$bluetoothStateNote
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.bluetoothStateNote = note
            }
            .store(in: &cancellables)

        peripheral.$bluetoothPowerState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.bluetoothPowerState = state
            }
            .store(in: &cancellables)

        peripheral.$advertisingNote
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.advertisingNote = note
            }
            .store(in: &cancellables)

        peripheral.$diagnostics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] logs in
                self?.diagnosticLogs = logs
            }
            .store(in: &cancellables)

        peripheral.$authorizationState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] auth in
                self?.bluetoothAuthorization = auth
            }
            .store(in: &cancellables)

        peripheral.onLineReceived = { [weak self] line in
            guard let self else { return }
            self.recordEvent("接收  \(line)")
            let outbound = self.runtime.ingestLine(line)
            self.refreshFromRuntime()
            for response in outbound {
                self.recordEvent("发送  \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
                _ = self.peripheral.sendLine(response)
            }
        }

        subscribeLiveActivityDecisions()
    }

    /// Listens for Approve/Deny decisions posted by the Live Activity AppIntent
    /// (running in the widget process). We register a Darwin notification so we
    /// hear it regardless of app foreground state, then drain the shared
    /// `UserDefaults` record on the main actor.
    private func subscribeLiveActivityDecisions() {
        let rawName = LiveActivitySharedStore.decisionChangedDarwinName
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, _, _, _, _ in
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: .liveActivityDecisionReceived,
                        object: nil
                    )
                }
            },
            rawName as CFString,
            nil,
            .deliverImmediately
        )

        NotificationCenter.default.publisher(for: .liveActivityDecisionReceived)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.drainPendingLiveActivityDecision()
            }
            .store(in: &cancellables)
    }

    private func drainPendingLiveActivityDecision() {
        guard let record = LiveActivitySharedStore.takePendingDecision() else { return }
        guard let current = prompt, current.id == record.id else {
            // Stale or already-answered prompt — just refresh the island.
            pushLiveActivity()
            return
        }
        let decision: PermissionDecision = record.decision == .approve ? .once : .deny
        respondPermission(decision)
    }

    func start(displayName: String? = nil, includeServiceUUIDInAdvertisement: Bool = true) {
        guard !started else { return }
        let finalName = resolvedDisplayName(displayName)
        activeDisplayName = finalName
        peripheral.setAdvertisementMode(includeServiceUUID: includeServiceUUIDInAdvertisement)
        peripheral.start(displayName: finalName)
        recordEvent("系统 请求启动广播：\(finalName)")
        refreshFromRuntime()
        started = true
        pushLiveActivity()
    }

    /// Called by onboarding to show the Bluetooth permission sheet after an
    /// explicit user tap (no auto-prompt at launch).
    func requestBluetoothAuthorization() {
        peripheral.requestAuthorization()
    }

    func stop() {
        guard started else { return }
        peripheral.stop()
        recordEvent("系统 BLE 外设已停止")
        started = false
        Task {
            await liveActivityManager.end()
        }
    }

    @discardableResult
    func respondPermission(_ decision: PermissionDecision) -> TimeInterval? {
        let answeredId = prompt?.id
        guard let line = runtime.respondPermission(decision) else { return nil }
        let direction = decision == .once ? "允许" : "拒绝"
        recordEvent("发送  权限\(direction)")
        _ = peripheral.sendLine(line)

        let elapsed = lastPromptAt.map { Date().timeIntervalSince($0) }
        switch decision {
        case .once:
            statsStore.onApproval(secondsToRespond: elapsed ?? 0)
            if let elapsed, elapsed < quickApprovalThreshold {
                lastQuickApprovalAt = Date()
            }
        case .deny:
            statsStore.onDenial()
        }
        lastPromptAt = nil
        lastPromptId = nil
        responseSent = true
        // Optimistically clear the prompt and refresh the Live Activity so the
        // Dynamic Island / lock-screen buttons collapse immediately instead of
        // waiting ~one heartbeat for the desktop to reflect the response. The
        // runtime is now idempotent against the same id, so a stale heartbeat
        // won't re-seat it. Also sweep any delivered local notification for
        // this prompt id — its quick actions would otherwise reappear.
        prompt = nil
        if let answeredId {
            BuddyNotificationCenter.shared.clearPromptNotifications(promptID: answeredId)
        }
        pushStatusSample()
        pushLiveActivity()
        return elapsed
    }

    /// Wipes the log surfaces visible in the home log sheet — heartbeat
    /// entries, BLE wire events, and diagnostic logs. Remote sources
    /// (heartbeat.entries) will refill on the next desktop tick; the intent is
    /// to give the user a clean slate, not to permanently suppress logs.
    func clearLogs() {
        recentEvents.removeAll()
        diagnosticLogs.removeAll()
        parsedEntries.removeAll()
        snapshot.entries.removeAll()
    }

    /// Records a user-visible device-menu interaction (MENU / SETTINGS /
    /// RESET apply) into the recent event log. Menu state itself is local —
    /// this is the only surface the user has to see what changed.
    func logDeviceMenuEvent(_ description: String) {
        recordEvent("设备 \(description)")
    }

    /// Incoming heartbeat `entries` arrive newest-first. Walk from oldest to
    /// newest and prepend any line that isn't already in our recent window —
    /// lines that stay in the bridge's top-N across several heartbeats get
    /// skipped instead of duplicated. Keeping the dedup to a window (not the
    /// whole history) means a legitimate repeat later on still records.
    private func mergeParsedEntries(from incoming: [String]) {
        guard !incoming.isEmpty else { return }
        for entry in incoming.reversed() {
            let window = parsedEntries.prefix(Self.parsedEntriesDedupWindow)
            if window.contains(entry) { continue }
            parsedEntries.insert(entry, at: 0)
        }
        if parsedEntries.count > Self.parsedEntriesMax {
            parsedEntries.removeLast(parsedEntries.count - Self.parsedEntriesMax)
        }
    }

    private func refreshFromRuntime() {
        let newSnapshot = runtime.currentSnapshot()
        mergeParsedEntries(from: newSnapshot.entries)
        snapshot = newSnapshot
        transfer = runtime.transferProgress()

        let newPrompt = runtime.pendingPrompt()
        if let newPrompt, newPrompt.id != lastPromptId {
            lastPromptId = newPrompt.id
            lastPromptAt = Date()
            responseSent = false
            BuddyNotificationCenter.shared.notifyPromptIfNeeded(
                promptID: newPrompt.id,
                tool: newPrompt.tool,
                enabled: notificationsEnabled
            )
        } else if newPrompt == nil {
            lastPromptAt = nil
            lastPromptId = nil
            responseSent = false
        }
        prompt = newPrompt

        let leveledUp = statsStore.onBridgeTokens(newSnapshot.tokens)
        if leveledUp {
            recentLevelUp = true
            recordEvent("系统 升级！等级 \(statsStore.stats.level)")
            BuddyNotificationCenter.shared.notifyLevelUpIfNeeded(
                level: UInt16(statsStore.stats.level),
                enabled: notificationsEnabled
            )
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.recentLevelUp = false
            }
        }
        pushStatusSample()
        pushLiveActivity()
    }

    /// Single chokepoint for Live Activity updates. Honours the user's
    /// `buddy.liveActivityEnabled` toggle and the "only show when connected"
    /// rule — anything else tears the activity down instead of updating it.
    private func pushLiveActivity() {
        guard liveActivityEnabled, case .connected = connectionState else {
            Task { await liveActivityManager.end() }
            return
        }
        let slug = currentPersonaSlug(connection: connectionState, snapshot: snapshot)
        let preview = prompt.map(previewFor(prompt:))
        let state = connectionState
        let snap = snapshot
        let hasPrompt = prompt != nil
        let promptID = prompt?.id
        Task {
            await liveActivityManager.startOrUpdate(
                state: state,
                snapshot: snap,
                hasPrompt: hasPrompt,
                personaSlug: slug,
                messagePreview: preview,
                promptID: promptID
            )
        }
    }

    private func currentPersonaSlug(connection: NUSConnectionState, snapshot: BridgeSnapshot) -> String {
        let connected: Bool
        if case .connected = connection { connected = true } else { connected = false }
        let input = PersonaDeriveInput(
            connected: connected,
            sessionsRunning: snapshot.running,
            sessionsWaiting: snapshot.waiting,
            recentlyCompleted: recentLevelUp
        )
        return derivePersonaState(input).slug
    }

    private func previewFor(prompt: PromptRequest) -> String {
        let tool = prompt.tool.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = prompt.hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if tool.isEmpty && hint.isEmpty { return String(localized: "live.alert.body") }
        if tool.isEmpty { return hint }
        if hint.isEmpty { return tool }
        return "\(tool): \(hint)"
    }

    private func enableBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushStatusSample() }
            .store(in: &cancellables)
        pushStatusSample()
    }

    private func pushStatusSample() {
        let device = UIDevice.current
        let rawLevel = device.batteryLevel
        let percent: Int = rawLevel < 0 ? 100 : Int((rawLevel * 100).rounded())
        let usb = (device.batteryState == .charging || device.batteryState == .full)
        let battery = BatterySample(percent: percent, millivolts: 0, milliamps: 0, usb: usb)
        let s = statsStore.stats
        let stats = StatsSample(
            approvals: Int(s.approvals),
            denials: Int(s.denials),
            velocityMedianSeconds: Int(s.medianVelocitySeconds),
            napSeconds: Int(s.napSeconds),
            level: Int(s.level)
        )
        runtime.updateStatusSample(StatusSample(battery: battery, stats: stats))
    }

    private func recordEvent(_ line: String) {
        recentEvents.insert(line, at: 0)
        if recentEvents.count > 120 {
            recentEvents.removeLast(recentEvents.count - 120)
        }
    }

    private func resolvedDisplayName(_ requested: String?) -> String {
        // OpenVibble Desktop 做大小写无关前缀匹配（"claude"），所以广播用
        // 全小写 "claude.openvibble" 让 OpenVibble 设备在扫描列表里可被一眼
        // 辨识。Claude Desktop 官方是大小写敏感的 "Claude" 前缀，要走它需要
        // 用户把 iPhone 系统名改成 Claude 开头后在后台运行（help sheet 说明）。
        _ = requested
        return "claude.openvibble"
    }

    private var notificationsEnabled: Bool {
        if UserDefaults.standard.object(forKey: "buddy.notificationsEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "buddy.notificationsEnabled")
    }

    private var liveActivityEnabled: Bool {
        if UserDefaults.standard.object(forKey: "buddy.liveActivityEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "buddy.liveActivityEnabled")
    }
}

extension Notification.Name {
    static let liveActivityDecisionReceived = Notification.Name("com.easyulife.openvibble.liveActivityDecisionReceived")
}
