// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// App-group bridge so the Live Activity AppIntents running in the widget
/// process can hand Approve/Deny decisions back to the main app. Writes a
/// record into the shared `UserDefaults`, then posts a Darwin notification so
/// the main app picks it up without having to be foregrounded.
enum LiveActivitySharedStore {
    static let appGroup = "group.com.easyulife.openvibble"
    static let decisionChangedDarwinName = "com.easyulife.openvibble.prompt.decisionChanged"

    enum Decision: String, Sendable {
        case approve
        case deny
    }

    private static let idKey = "pendingPrompt.id"
    private static let decisionKey = "pendingPrompt.decision"
    private static let stampKey = "pendingPrompt.stamp"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static func writePendingDecision(id: String, decision: Decision) {
        guard !id.isEmpty, let defaults else { return }
        defaults.set(id, forKey: idKey)
        defaults.set(decision.rawValue, forKey: decisionKey)
        defaults.set(Date().timeIntervalSince1970, forKey: stampKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(decisionChangedDarwinName as CFString),
            nil, nil, true
        )
    }

    /// Pops the record so the main app never re-processes a stale decision.
    static func takePendingDecision() -> (id: String, decision: Decision)? {
        guard let defaults,
              let id = defaults.string(forKey: idKey),
              let raw = defaults.string(forKey: decisionKey),
              let decision = Decision(rawValue: raw)
        else { return nil }
        defaults.removeObject(forKey: idKey)
        defaults.removeObject(forKey: decisionKey)
        defaults.removeObject(forKey: stampKey)
        return (id, decision)
    }
}
