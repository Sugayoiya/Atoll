/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import Defaults

/// Closed-notch live activity that mirrors the state of running agent
/// sessions (Claude Code and future providers, driven by
/// AgentSessionManager hook events). Provider identity shows through the
/// provider's accent color and icon.
struct AgentLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var manager = AgentSessionManager.shared

    @State private var isPulsing = false

    private let wingPadding: CGFloat = 16
    /// Cap for the status label (tool names have no intrinsic length limit).
    private let maxStatusTextWidth: CGFloat = 160

    private var notchContentHeight: CGFloat {
        max(0, vm.effectiveClosedNotchHeight)
    }

    var body: some View {
        if let session = manager.primarySession {
            content(for: session)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder
    private func content(for session: AgentSessionManager.Session) -> some View {
        let wings = wingWidths(for: session)
        HStack(spacing: 0) {
            Color.clear
                .frame(width: wings.left, height: notchContentHeight)
                .background(alignment: .leading) {
                    iconSection(for: session)
                        .padding(.leading, wingPadding / 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width, height: notchContentHeight)

            Color.clear
                .frame(width: wings.right, height: notchContentHeight)
                .background(alignment: .trailing) {
                    statusSection(for: session)
                        .padding(.trailing, wingPadding / 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
                // Never let overflowing content bleed left into the physical notch.
                .clipped()
        }
        .frame(width: wings.left + vm.closedNotchSize.width + wings.right, height: notchContentHeight, alignment: .center)
        .onAppear { isPulsing = true }
    }

    private func iconSection(for session: AgentSessionManager.Session) -> some View {
        let accent = accentColor(for: session)
        return ZStack {
            Image(systemName: providerIconName(for: session))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(accent)
                .opacity(session.status.isBusy ? (isPulsing ? 0.4 : 1.0) : 1.0)
                .animation(
                    session.status.isBusy
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )
        }
        .frame(width: iconDiameter, height: notchContentHeight, alignment: .center)
    }

    private func statusSection(for session: AgentSessionManager.Session) -> some View {
        let accent = accentColor(for: session)
        return HStack(spacing: 5) {
            if let prompt = manager.pendingPrompt(for: session) {
                // Pending decision indicator (status only — the interactive
                // controls live in the expanded-notch Agents tab).
                Image(systemName: pendingIconName(for: prompt))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(pendingTint(for: prompt))
            }
            if manager.sessions.count > 1 {
                Text("\(manager.sessions.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accent))
            }
            Text(statusText(for: session))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .frame(maxWidth: maxStatusTextWidth, alignment: .trailing)
            if session.status.isBusy {
                elapsedIndicator(for: session)
            }
        }
        .frame(height: notchContentHeight, alignment: .center)
    }

    /// Small dimmed "m:ss" counter showing how long the current status has
    /// been running (thinking / tool / compacting).
    private func elapsedIndicator(for session: AgentSessionManager.Session) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(elapsedText(since: session.statusChangedAt, now: context.date))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    private func elapsedText(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let minutes = min(seconds / 60, 99)
        return String(format: "%d:%02d", minutes, seconds % 60)
    }

    private func pendingIconName(for prompt: AgentSessionManager.PendingPrompt) -> String {
        switch prompt {
        case .permission: return "shield.lefthalf.filled"
        case .question: return "questionmark.bubble.fill"
        }
    }

    private func pendingTint(for prompt: AgentSessionManager.PendingPrompt) -> Color {
        switch prompt {
        case .permission: return .orange
        case .question: return .cyan
        }
    }

    private func statusText(for session: AgentSessionManager.Session) -> String {
        switch session.status {
        case .runningTool(let tool):
            if let summary = session.toolSummary, summary != tool {
                return "\(tool) · \(summary)"
            }
            return tool
        case .thinking:
            return session.promptPreview ?? session.status.label
        default:
            return session.status.label
        }
    }

    private func accentColor(for session: AgentSessionManager.Session) -> Color {
        session.status == .waitingForInput ? .cyan : manager.accentColor(for: session.provider)
    }

    private func providerIconName(for session: AgentSessionManager.Session) -> String {
        manager.provider(for: session.provider)?.iconName ?? "asterisk"
    }

    private var leftWingWidth: CGFloat {
        wingPadding + iconDiameter
    }

    /// The whole HStack is centered on the physical notch, so asymmetric wings
    /// shift the center black segment sideways and let the hardware notch
    /// occlude the wider wing's inner content (e.g. the session-count badge).
    /// Balancing both wings to the same width keeps the center segment aligned.
    private func wingWidths(for session: AgentSessionManager.Session) -> (left: CGFloat, right: CGFloat) {
        let balanced = max(leftWingWidth, rightWingWidth(for: session))
        return (balanced, balanced)
    }

    private func rightWingWidth(for session: AgentSessionManager.Session) -> CGFloat {
        let textWidth = min(
            measureTextWidth(
                statusText(for: session),
                font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ),
            maxStatusTextWidth
        )
        var width = wingPadding + textWidth
        if manager.pendingPrompt(for: session) != nil {
            // Pending indicator icon (~14pt) + HStack spacing (5pt).
            width += 14 + 5
        }
        if session.status.isBusy {
            // Elapsed counter: reserve for "00:00" so the wing doesn't resize
            // every second while the counter ticks + HStack spacing (5pt).
            let elapsedWidth = measureTextWidth(
                "00:00",
                font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            )
            width += elapsedWidth + 5
        }
        if manager.sessions.count > 1 {
            // Badge: measured digits + horizontal padding (4pt x2) + capsule stroke slack + HStack spacing (5pt)
            let badgeTextWidth = measureTextWidth(
                "\(manager.sessions.count)",
                font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            )
            width += badgeTextWidth + 8 + 2 + 5
        }
        return max(width + 18, 76)
    }

    private func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil(NSAttributedString(string: text, attributes: attributes).size().width)
    }

    private var iconDiameter: CGFloat {
        max(notchContentHeight - 8, 26)
    }
}
