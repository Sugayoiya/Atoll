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

/// Closed-notch live activity that mirrors the state of running
/// Claude Code sessions (driven by ClaudeCodeManager hook events).
struct ClaudeCodeLiveActivity: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var manager = ClaudeCodeManager.shared

    @State private var isPulsing = false

    private let wingPadding: CGFloat = 16

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
    private func content(for session: ClaudeCodeManager.Session) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: leftWingWidth, height: notchContentHeight)
                .background(alignment: .leading) {
                    iconSection(for: session)
                        .padding(.leading, wingPadding / 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width, height: notchContentHeight)

            Color.clear
                .frame(width: rightWingWidth(for: session), height: notchContentHeight)
                .background(alignment: .trailing) {
                    statusSection(for: session)
                        .padding(.trailing, wingPadding / 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
        }
        .frame(height: notchContentHeight, alignment: .center)
        .onAppear { isPulsing = true }
    }

    private func iconSection(for session: ClaudeCodeManager.Session) -> some View {
        let accent = accentColor(for: session)
        return ZStack {
            Image(systemName: "asterisk")
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

    private func statusSection(for session: ClaudeCodeManager.Session) -> some View {
        let accent = accentColor(for: session)
        return HStack(spacing: 5) {
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
                .contentTransition(.opacity)
        }
        .frame(height: notchContentHeight, alignment: .center)
    }

    private func statusText(for session: ClaudeCodeManager.Session) -> String {
        session.status.label
    }

    private func accentColor(for session: ClaudeCodeManager.Session) -> Color {
        session.status == .waitingForInput ? .cyan : ClaudeCodeManager.accentColor
    }

    private var leftWingWidth: CGFloat {
        wingPadding + iconDiameter
    }

    private func rightWingWidth(for session: ClaudeCodeManager.Session) -> CGFloat {
        let textWidth = measureTextWidth(
            statusText(for: session),
            font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        )
        var width = wingPadding + textWidth
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
