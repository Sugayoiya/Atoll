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
        if let request = manager.pendingQuestion {
            questionContent(for: request)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                // Same tap-guard contract as the permission prompt: the
                // option chips own clicks only while actually on screen.
                .onAppear { manager.setPermissionPromptVisible(true) }
                .onDisappear { manager.setPermissionPromptVisible(false) }
        } else if let request = manager.pendingPermission {
            permissionContent(for: request)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                // Report on-screen state so the closed-notch tap guard only
                // swallows clicks while the Allow/Deny buttons are visible.
                .onAppear { manager.setPermissionPromptVisible(true) }
                .onDisappear { manager.setPermissionPromptVisible(false) }
        } else if let session = manager.primarySession {
            content(for: session)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: - Permission prompt (Allow / Deny)

    @ViewBuilder
    private func permissionContent(for request: AgentPermissionRequest) -> some View {
        let leftWidth = permissionLeftWingWidth(for: request)
        let rightWidth = permissionRightWingWidth(for: request)
        let balanced = max(leftWidth, rightWidth)
        HStack(spacing: 0) {
            Color.clear
                .frame(width: balanced, height: notchContentHeight)
                .background(alignment: .leading) {
                    HStack(spacing: 5) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.orange)
                        Text(request.toolName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    .padding(.leading, wingPadding / 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width, height: notchContentHeight)

            Color.clear
                .frame(width: balanced, height: notchContentHeight)
                .background(alignment: .trailing) {
                    HStack(spacing: 7) {
                        Text(request.inputSummary)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: maxPermissionSummaryWidth, alignment: .trailing)
                        permissionButton(systemName: "checkmark.circle.fill", tint: .green) {
                            manager.answerPendingPermission(allow: true)
                        }
                        permissionButton(systemName: "xmark.circle.fill", tint: .red) {
                            manager.answerPendingPermission(allow: false)
                        }
                    }
                    .padding(.trailing, wingPadding / 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
                .clipped()
        }
        .frame(width: balanced + vm.closedNotchSize.width + balanced, height: notchContentHeight, alignment: .center)
    }

    private func permissionButton(systemName: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var maxPermissionSummaryWidth: CGFloat { 170 }

    // MARK: - Question prompt (option chips, Claude-only today)

    /// Question wing layout: header/question text on the left wing, the
    /// answer options as compact tappable chips on the right wing. Inputs
    /// that can't fit this layout never reach the UI — they are filtered by
    /// the provider adapter and answered in the terminal instead.
    @ViewBuilder
    private func questionContent(for request: AgentQuestionRequest) -> some View {
        let leftWidth = questionLeftWingWidth(for: request)
        let rightWidth = questionRightWingWidth(for: request)
        let balanced = max(leftWidth, rightWidth)
        HStack(spacing: 0) {
            Color.clear
                .frame(width: balanced, height: notchContentHeight)
                .background(alignment: .leading) {
                    HStack(spacing: 5) {
                        Image(systemName: "questionmark.bubble.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.cyan)
                        Text(questionPromptText(for: request))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.cyan)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: maxQuestionTextWidth, alignment: .leading)
                    }
                    .padding(.leading, wingPadding / 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .clipped()

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width, height: notchContentHeight)

            Color.clear
                .frame(width: balanced, height: notchContentHeight)
                .background(alignment: .trailing) {
                    HStack(spacing: questionChipSpacing) {
                        ForEach(request.optionLabels, id: \.self) { label in
                            questionChip(label: label) {
                                manager.answerPendingQuestion(optionLabel: label)
                            }
                        }
                    }
                    .padding(.trailing, wingPadding / 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
                .clipped()
        }
        .frame(width: balanced + vm.closedNotchSize.width + balanced, height: notchContentHeight, alignment: .center)
    }

    private func questionChip(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, questionChipHorizontalPadding)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Prefer the short header ("Color") when present; fall back to the
    /// question text, which the left wing truncates.
    private func questionPromptText(for request: AgentQuestionRequest) -> String {
        request.header ?? request.question
    }

    private var maxQuestionTextWidth: CGFloat { 170 }
    private var questionChipSpacing: CGFloat { 6 }
    private var questionChipHorizontalPadding: CGFloat { 8 }

    private func questionLeftWingWidth(for request: AgentQuestionRequest) -> CGFloat {
        let textWidth = min(
            measureTextWidth(
                questionPromptText(for: request),
                font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ),
            maxQuestionTextWidth
        )
        // Bubble icon (~15pt) + HStack spacing (5pt) + padding slack.
        return max(wingPadding + 15 + 5 + textWidth + 10, leftWingWidth)
    }

    private func questionRightWingWidth(for request: AgentQuestionRequest) -> CGFloat {
        let labels = request.optionLabels
        let chipsWidth = labels.reduce(CGFloat.zero) { total, label in
            let textWidth = measureTextWidth(label, font: NSFont.systemFont(ofSize: 11, weight: .semibold))
            return total + textWidth + 2 * questionChipHorizontalPadding
        }
        let spacing = CGFloat(max(labels.count - 1, 0)) * questionChipSpacing
        return max(wingPadding + chipsWidth + spacing + 18, 96)
    }

    private func permissionLeftWingWidth(for request: AgentPermissionRequest) -> CGFloat {
        let textWidth = measureTextWidth(
            request.toolName,
            font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        )
        // Shield icon (~15pt) + HStack spacing (5pt) + padding slack.
        return max(wingPadding + 15 + 5 + textWidth + 10, leftWingWidth)
    }

    private func permissionRightWingWidth(for request: AgentPermissionRequest) -> CGFloat {
        let textWidth = min(
            measureTextWidth(
                request.inputSummary,
                font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            ),
            maxPermissionSummaryWidth
        )
        // Summary + two 16pt buttons + HStack spacing (7pt x2) + padding slack.
        let buttonsWidth: CGFloat = 2 * 18 + 2 * 7
        return max(wingPadding + textWidth + buttonsWidth + 18, 96)
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
