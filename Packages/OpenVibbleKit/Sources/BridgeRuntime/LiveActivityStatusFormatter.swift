// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Hook log lines split for Live Activity: green header (`primary`) vs white body
/// (`secondary`, optional `tool` after ` · `).
public struct LiveActivityStatusLines: Equatable, Sendable {
    /// `HH:mm:ss Event [project]` — green status row.
    public let primary: String
    /// Conversation title or detail — white body row.
    public let secondary: String?
    /// Tool / file fragment after ` · ` — second white body row.
    public let tool: String?

    public init(primary: String, secondary: String? = nil, tool: String? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.tool = tool
    }
}

public enum LiveActivityStatusFormatter {
    /// Middle dot separator emitted by Desktop / node-bridge `appendHookLine`.
    private static let detailSeparator = " · "

    public static let bodyMaxLength = 80
    public static let toolMaxLength = 72

    public static func format(raw: String) -> LiveActivityStatusLines? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let parsed = ProjectEntryParser.parse(trimmed) else {
            return LiveActivityStatusLines(primary: truncate(trimmed, max: bodyMaxLength))
        }

        var prefixParts = [parsed.time, parsed.event]
        if let project = parsed.project?.trimmingCharacters(in: .whitespacesAndNewlines), !project.isEmpty {
            prefixParts.append("[\(project)]")
        }
        let header = prefixParts.joined(separator: " ")

        guard let detail = parsed.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty
        else {
            return LiveActivityStatusLines(primary: header)
        }

        if let range = detail.range(of: detailSeparator) {
            let title = String(detail[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let toolPart = String(detail[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LiveActivityStatusLines(
                primary: header,
                secondary: title.isEmpty ? nil : truncate(title, max: bodyMaxLength),
                tool: toolPart.isEmpty ? nil : truncate(toolPart, max: toolMaxLength)
            )
        }

        return LiveActivityStatusLines(
            primary: header,
            secondary: truncate(detail, max: bodyMaxLength)
        )
    }

    private static func truncate(_ value: String, max: Int) -> String {
        guard value.count > max else { return value }
        guard max > 1 else { return "…" }
        return String(value.prefix(max - 1)) + "…"
    }
}
