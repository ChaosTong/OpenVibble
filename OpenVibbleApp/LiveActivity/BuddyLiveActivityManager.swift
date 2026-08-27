// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
@preconcurrency import ActivityKit
import NUSPeripheral
import BridgeRuntime

actor BuddyLiveActivityManager {
    private var activity: Activity<BuddyLiveActivityAttributes>?
    private var lastHadPrompt: Bool = false

    func startOrUpdate(
        state: NUSConnectionState,
        snapshot: BridgeSnapshot,
        hasPrompt: Bool,
        personaSlug: String,
        messagePreview: String?,
        activityStatusLine: String?,
        activityStatusSubline: String?,
        activityStatusToolLine: String?,
        promptID: String?
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let contentState = BuddyLiveActivityAttributes.ContentState(
            connection: connectionTitle(for: state),
            running: snapshot.running,
            waiting: snapshot.waiting,
            promptPending: hasPrompt,
            personaSlug: personaSlug,
            messagePreview: messagePreview,
            activityStatusLine: activityStatusLine,
            activityStatusSubline: activityStatusSubline,
            activityStatusToolLine: activityStatusToolLine,
            promptID: promptID
        )

        let wasNewPrompt = hasPrompt && !lastHadPrompt
        lastHadPrompt = hasPrompt

        if let activity {
            let content = ActivityContent(state: contentState, staleDate: nil)
            if wasNewPrompt {
                let alert = AlertConfiguration(
                    title: "live.alert.title",
                    body: "live.alert.body",
                    sound: .default
                )
                await activity.update(content, alertConfiguration: alert)
            } else {
                await activity.update(content)
            }
            return
        }

        let attributes = BuddyLiveActivityAttributes(title: String(localized: "live.title"))
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: contentState, staleDate: nil)
            )
        } catch {
            activity = nil
        }
    }

    func end() async {
        guard let activity else { return }
        let final = BuddyLiveActivityAttributes.ContentState(
            connection: String(localized: "live.status.offline"),
            running: 0,
            waiting: 0,
            promptPending: false,
            personaSlug: "sleep",
            messagePreview: nil,
            activityStatusLine: nil,
            activityStatusSubline: nil,
            activityStatusToolLine: nil,
            promptID: nil
        )
        await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate)
        self.activity = nil
        lastHadPrompt = false
    }

    private func connectionTitle(for state: NUSConnectionState) -> String {
        switch state {
        case .stopped:
            return String(localized: "live.connection.stopped")
        case .advertising:
            return String(localized: "live.connection.advertising")
        case .connected:
            return String(localized: "live.connection.connected")
        }
    }
}

/// Rising-edge detector extracted so it can be unit-tested without ActivityKit.
struct PromptEdgeDetector {
    private(set) var last: Bool = false

    mutating func consume(_ current: Bool) -> Bool {
        defer { last = current }
        return current && !last
    }
}
