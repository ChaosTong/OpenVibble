// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
@preconcurrency import ActivityKit

struct BuddyLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var connection: String
        var running: Int
        var waiting: Int
        var promptPending: Bool
        var personaSlug: String
        var messagePreview: String?
        var activityStatusLine: String?
        /// Conversation title / detail — white body under the green header.
        var activityStatusSubline: String?
        /// Tool / file fragment after ` · ` — optional second white body line.
        var activityStatusToolLine: String?
        var promptID: String?

        init(
            connection: String,
            running: Int,
            waiting: Int,
            promptPending: Bool,
            personaSlug: String = "idle",
            messagePreview: String? = nil,
            activityStatusLine: String? = nil,
            activityStatusSubline: String? = nil,
            activityStatusToolLine: String? = nil,
            promptID: String? = nil
        ) {
            self.connection = connection
            self.running = running
            self.waiting = waiting
            self.promptPending = promptPending
            self.personaSlug = personaSlug
            self.messagePreview = messagePreview
            self.activityStatusLine = activityStatusLine
            self.activityStatusSubline = activityStatusSubline
            self.activityStatusToolLine = activityStatusToolLine
            self.promptID = promptID
        }
    }

    var title: String
}
