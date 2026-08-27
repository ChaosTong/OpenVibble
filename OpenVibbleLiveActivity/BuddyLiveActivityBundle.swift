// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import WidgetKit
import SwiftUI
@preconcurrency import ActivityKit

@main
struct BuddyLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        BuddyLiveActivityWidget()
    }
}

struct BuddyLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BuddyLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(state: context.state)
                .activityBackgroundTint(TerminalStyleLite.lcdBg)
                .activitySystemActionForegroundColor(TerminalStyleLite.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailing(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(state: context.state)
                }
            } compactLeading: {
                PersonaGlyph(slug: context.state.personaSlug, size: 12)
                    .padding(.leading, 2)
            } compactTrailing: {
                compactTrailingView(state: context.state)
                    .padding(.trailing, 2)
            } minimal: {
                PersonaGlyph(slug: context.state.personaSlug, size: 12)
            }
            .widgetURL(URL(string: "openvibble://status"))
            .keylineTint(TerminalStyleLite.accent)
        }
    }

    // MARK: - Expanded

    @ViewBuilder
    private func expandedLeading(state: BuddyLiveActivityAttributes.ContentState) -> some View {
        HStack(spacing: 6) {
            PersonaGlyph(slug: state.personaSlug, size: 16)
            Text("live.title")
                .font(TerminalStyleLite.mono(11, weight: .semibold))
                .foregroundStyle(TerminalStyleLite.ink)
                .lineLimit(1)
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func expandedTrailing(state: BuddyLiveActivityAttributes.ContentState) -> some View {
        HStack(spacing: 8) {
            countChip(key: "live.label.running", value: state.running, color: TerminalStyleLite.good)
            countChip(key: "live.label.waiting", value: state.waiting, color: TerminalStyleLite.ink)
        }
        .padding(.trailing, 2)
    }

    @ViewBuilder
    private func expandedBottom(state: BuddyLiveActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                LiveActivityStatusHeader.view(state: state, fontSize: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(state.connection)
                    .font(TerminalStyleLite.mono(10))
                    .foregroundStyle(TerminalStyleLite.inkDim)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if state.promptPending {
                HStack(alignment: .center, spacing: 8) {
                    Text(state.messagePreview ?? String(localized: "live.alert.body"))
                        .font(TerminalStyleLite.mono(11))
                        .foregroundStyle(TerminalStyleLite.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let id = state.promptID, !id.isEmpty {
                        HStack(spacing: 6) {
                            Button(intent: ApprovePromptIntent(promptID: id)) {
                                actionLabel(key: "live.action.approve", color: TerminalStyleLite.good)
                            }
                            .buttonStyle(.plain)
                            Button(intent: DenyPromptIntent(promptID: id)) {
                                actionLabel(key: "live.action.deny", color: TerminalStyleLite.bad)
                            }
                            .buttonStyle(.plain)
                        }
                        .fixedSize()
                    }
                }
            } else {
                LiveActivityStatusBody.view(state: state, fontSize: 11, toolSize: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Compact trailing

    @ViewBuilder
    private func compactTrailingView(state: BuddyLiveActivityAttributes.ContentState) -> some View {
        if state.promptPending {
            Text("[!]")
                .font(TerminalStyleLite.mono(12, weight: .bold))
                .foregroundStyle(TerminalStyleLite.accent)
        } else {
            Text("\(state.running)")
                .font(TerminalStyleLite.mono(12, weight: .semibold).monospacedDigit())
                .foregroundStyle(TerminalStyleLite.good)
        }
    }

    private func countChip(key: LocalizedStringKey, value: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(TerminalStyleLite.mono(9))
                .foregroundStyle(TerminalStyleLite.inkDim)
            Text("\(value)")
                .font(TerminalStyleLite.mono(12, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func actionLabel(key: LocalizedStringKey, color: Color) -> some View {
        Text(key)
            .font(TerminalStyleLite.mono(10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(TerminalStyleLite.lcdPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(color.opacity(0.7), lineWidth: 1)
            )
    }
}

// MARK: - Status header (shared by island + lock screen)

private enum LiveActivityStatusHeader {
    static func fallbackText(state: BuddyLiveActivityAttributes.ContentState) -> String {
        if state.promptPending {
            return String(localized: "live.header.prompt")
        }
        if let line = state.activityStatusLine?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            return line
        }
        return String(localized: "live.header.status")
    }

    @ViewBuilder
    static func view(state: BuddyLiveActivityAttributes.ContentState, fontSize: CGFloat) -> some View {
        let color = state.promptPending ? TerminalStyleLite.accent : TerminalStyleLite.good
        Text(fallbackText(state: state))
            .font(TerminalStyleLite.mono(fontSize))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
}

// MARK: - Status body (white text under green header)

private enum LiveActivityStatusBody {
    @ViewBuilder
    static func view(state: BuddyLiveActivityAttributes.ContentState, fontSize: CGFloat, toolSize: CGFloat) -> some View {
        let body = state.activityStatusSubline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tool = state.activityStatusToolLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.isEmpty && tool.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if !body.isEmpty {
                    Text(body)
                        .font(TerminalStyleLite.mono(fontSize))
                        .foregroundStyle(TerminalStyleLite.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                if !tool.isEmpty {
                    Text(tool)
                        .font(TerminalStyleLite.mono(toolSize))
                        .foregroundStyle(TerminalStyleLite.inkDim)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
            }
        }
    }
}

// MARK: - Lock screen

private struct LockScreenLiveActivityView: View {
    let state: BuddyLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                LiveActivityStatusHeader.view(state: state, fontSize: 11)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(state.connection)
                    .font(TerminalStyleLite.mono(10))
                    .foregroundStyle(TerminalStyleLite.inkDim)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 10) {
                PersonaGlyph(slug: state.personaSlug, size: 20)

                if state.promptPending {
                    Text(state.messagePreview ?? String(localized: "live.alert.body"))
                        .font(TerminalStyleLite.mono(12))
                        .foregroundStyle(TerminalStyleLite.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if state.activityStatusSubline?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            || state.activityStatusToolLine?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    LiveActivityStatusBody.view(state: state, fontSize: 12, toolSize: 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("live.title")
                        .font(TerminalStyleLite.mono(13, weight: .semibold))
                        .foregroundStyle(TerminalStyleLite.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                countBlock(key: "live.label.running", value: state.running, color: TerminalStyleLite.good)
                countBlock(key: "live.label.waiting", value: state.waiting, color: TerminalStyleLite.ink)
            }

            if state.promptPending, let id = state.promptID, !id.isEmpty {
                HStack(spacing: 8) {
                    Button(intent: ApprovePromptIntent(promptID: id)) {
                        lockButtonLabel(key: "live.action.approve", color: TerminalStyleLite.good)
                    }
                    .buttonStyle(.plain)
                    Button(intent: DenyPromptIntent(promptID: id)) {
                        lockButtonLabel(key: "live.action.deny", color: TerminalStyleLite.bad)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func countBlock(key: LocalizedStringKey, value: Int, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(key)
                .font(TerminalStyleLite.mono(9))
                .foregroundStyle(TerminalStyleLite.inkDim)
            Text("\(value)")
                .font(TerminalStyleLite.mono(14, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func lockButtonLabel(key: LocalizedStringKey, color: Color) -> some View {
        Text(key)
            .font(TerminalStyleLite.mono(11, weight: .semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(TerminalStyleLite.lcdPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color.opacity(0.7), lineWidth: 1)
            )
    }
}

// MARK: - Persona glyph

/// Terminal-style ASCII glyph for the Buddy persona. Readable at 10–16pt on
/// the Dynamic Island; emoji rendered too small and washed out.
struct PersonaGlyph: View {
    let slug: String
    let size: CGFloat

    var body: some View {
        Text(glyph)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .fixedSize()
            .frame(minWidth: size + 4)
    }

    private var glyph: String {
        switch slug {
        case "sleep":     return "[z]"
        case "busy":      return "[*]"
        case "attention": return "[!]"
        case "celebrate": return "[+]"
        case "dizzy":     return "[~]"
        case "heart":     return "[♥]"
        case "idle":      return "[.]"
        default:          return "[.]"
        }
    }

    private var color: Color {
        switch slug {
        case "attention", "heart": return TerminalStyleLite.accent
        case "busy", "celebrate":  return TerminalStyleLite.good
        case "sleep", "dizzy":     return TerminalStyleLite.inkDim
        default:                    return TerminalStyleLite.ink
        }
    }
}
