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
    /// One component of the dynamic cap — the wing is additionally clamped to
    /// the hosting window's available width (see `maxWingWidth`).
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
            providerIcon(for: session)
                .view(size: 15)
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
        let pending = manager.pendingPrompt(for: session)
        let hasPendingPrompt = pending != nil
        return HStack(spacing: 5) {
            if let prompt = pending {
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
            Text(AgentSessionManager.displayStatusText(for: session, pending: pending))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .frame(maxWidth: statusTextMaxWidth(for: session), alignment: .trailing)
            if AgentElapsedIndicator.couldShow(session: session, hasPendingPrompt: hasPendingPrompt) {
                AgentElapsedIndicator(session: session, hasPendingPrompt: hasPendingPrompt)
            }
        }
        .frame(height: notchContentHeight, alignment: .center)
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

    private func accentColor(for session: AgentSessionManager.Session) -> Color {
        session.status == .waitingForInput ? .cyan : manager.accentColor(for: session.provider)
    }

    private func providerIcon(for session: AgentSessionManager.Session) -> AgentProviderIcon {
        manager.provider(for: session.provider)?.icon ?? .system(name: "asterisk")
    }

    private var leftWingWidth: CGFloat {
        wingPadding + iconDiameter
    }

    /// The whole HStack is centered on the physical notch, so asymmetric wings
    /// shift the center black segment sideways and let the hardware notch
    /// occlude the wider wing's inner content (e.g. the session-count badge).
    /// Balancing both wings to the same width keeps the center segment aligned.
    private func wingWidths(for session: AgentSessionManager.Session) -> (left: CGFloat, right: CGFloat) {
        let balanced = min(max(leftWingWidth, rightWingWidth(for: session)), maxWingWidth)
        return (balanced, balanced)
    }

    /// Maximum total width the closed-notch hosting window can display. The
    /// window keeps its open-notch width while closed, so anything wider gets
    /// clipped and the NotchShape's bottom corner curves disappear. Reserve
    /// the closed bottom corner radius per side so the curves stay visible.
    private var maxTotalWidth: CGFloat {
        let windowWidth = Defaults[.enableMinimalisticUI]
            ? minimalisticOpenNotchSize(isDynamicIslandMode: shouldUseDynamicIslandMode(for: vm.screen)).width
            : openNotchSize.width
        let cornerSlack = cornerRadiusInsets.closed.bottom * 2
        return windowWidth - cornerSlack
    }

    /// Per-wing cap derived from `maxTotalWidth` (total = 2 wings + notch).
    private var maxWingWidth: CGFloat {
        max(76, (maxTotalWidth - vm.closedNotchSize.width) / 2)
    }

    /// Width of everything in the right wing except the status text (padding,
    /// pending icon, session badge, elapsed counter, trailing slack).
    private func fixedRightWingWidth(for session: AgentSessionManager.Session) -> CGFloat {
        let hasPendingPrompt = manager.pendingPrompt(for: session) != nil
        var width = wingPadding
        if hasPendingPrompt {
            // Pending indicator icon (~14pt) + HStack spacing (5pt).
            width += 14 + 5
        }
        if AgentElapsedIndicator.couldShow(session: session, hasPendingPrompt: hasPendingPrompt) {
            // Elapsed counter: reserve for "00:00" so the wing doesn't resize
            // every second while the counter ticks + HStack spacing (5pt).
            // Deliberately reserved whenever the counter COULD appear (busy,
            // no pending prompt) rather than only after the 2s reveal delay,
            // so the wing doesn't jump when the counter fades in. The
            // indicator itself keeps a matching clear-frame spacer (no digit
            // glyphs) during the delay.
            width += AgentElapsedIndicator.reservedWidth + 5
        }
        if manager.sessions.count > 1 {
            // Badge: measured digits + horizontal padding (4pt x2) + capsule stroke slack + HStack spacing (5pt)
            let badgeTextWidth = measureTextWidth(
                "\(manager.sessions.count)",
                font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            )
            width += badgeTextWidth + 8 + 2 + 5
        }
        return width + 18
    }

    /// Dynamic cap for the status label: the smaller of the static cap and
    /// whatever fits inside `maxWingWidth` next to the fixed elements. Used by
    /// both the measured wing width and the Text's `frame(maxWidth:)` so
    /// measurement and rendering agree.
    private func statusTextMaxWidth(for session: AgentSessionManager.Session) -> CGFloat {
        let available = maxWingWidth - fixedRightWingWidth(for: session)
        return max(40, min(maxStatusTextWidth, available))
    }

    private func rightWingWidth(for session: AgentSessionManager.Session) -> CGFloat {
        let textWidth = min(
            measureTextWidth(
                AgentSessionManager.displayStatusText(for: session, pending: manager.pendingPrompt(for: session)),
                font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ),
            statusTextMaxWidth(for: session)
        )
        return max(fixedRightWingWidth(for: session) + textWidth, 76)
    }

    private func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil(NSAttributedString(string: text, attributes: attributes).size().width)
    }

    private var iconDiameter: CGFloat {
        max(notchContentHeight - 8, 26)
    }
}
