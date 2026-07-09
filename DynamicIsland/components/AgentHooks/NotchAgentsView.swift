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

/// Expanded-notch Agents tab: lists every live agent session and hosts the
/// interactive prompts (permission Allow/Deny, question options) that used
/// to live on the closed-notch wings. Sessions with a pending prompt expand
/// inline so the user can answer directly.
struct NotchAgentsView: View {
    @ObservedObject var manager = AgentSessionManager.shared

    private var orderedSessions: [AgentSessionManager.Session] {
        manager.sessions.sorted { lhs, rhs in
            let lhsPending = manager.pendingPrompt(for: lhs) != nil
            let rhsPending = manager.pendingPrompt(for: rhs) != nil
            if lhsPending != rhsPending { return lhsPending }
            return lhs.lastUpdated > rhs.lastUpdated
        }
    }

    var body: some View {
        Group {
            if manager.sessions.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(orderedSessions) { session in
                            AgentSessionRow(session: session, manager: manager)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: manager.sessions)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.gray)
            Text("No active agent sessions")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One session row: provider icon + project + status, with the pending
/// permission/question controls expanded inline when a decision is awaited.
private struct AgentSessionRow: View {
    let session: AgentSessionManager.Session
    @ObservedObject var manager: AgentSessionManager

    private var accent: Color {
        manager.accentColor(for: session.provider)
    }

    private var pendingPrompt: AgentSessionManager.PendingPrompt? {
        manager.pendingPrompt(for: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let prompt = pendingPrompt {
                switch prompt {
                case .permission(let request):
                    permissionControls(for: request)
                case .question(let request):
                    questionControls(for: request)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(pendingPrompt != nil ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(pendingPrompt != nil ? accent.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Header (provider / project / status)

    private var header: some View {
        HStack(spacing: 8) {
            (manager.provider(for: session.provider)?.icon ?? .system(name: "asterisk"))
                .view(size: 14)
                .foregroundStyle(accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(manager.provider(for: session.provider)?.displayName ?? session.provider)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
                Text(statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if session.status.isBusy {
                elapsedIndicator
            } else {
                Image(systemName: session.status.iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
        }
    }

    private var statusText: String {
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

    private var elapsedIndicator: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(session.statusChangedAt)))
            Text(String(format: "%d:%02d", min(seconds / 60, 99), seconds % 60))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - Permission (Allow / Deny)

    private func permissionControls(for request: AgentPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.orange)
                Text(request.toolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Text(request.inputSummary)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: 8) {
                decisionButton(label: String(localized: "Allow"), systemName: "checkmark.circle.fill", tint: .green) {
                    manager.answerPendingPermission(sessionKey: session.id, allow: true)
                }
                decisionButton(label: String(localized: "Deny"), systemName: "xmark.circle.fill", tint: .red) {
                    manager.answerPendingPermission(sessionKey: session.id, allow: false)
                }
                // Shell commands only: stores a smart-prefix auto-allow rule
                // (manageable in Settings) and allows this call. Compound
                // commands (multiple segments) or commands with substitution
                // constructs never offer the button — a single prefix rule
                // can't safely cover them.
                if let command = request.rawCommand,
                   AgentCommandMatcher.canSuggestRule(for: command),
                   let prefix = AgentCommandMatcher.smartPrefix(for: command) {
                    decisionButton(
                        label: String(localized: "Always Allow \"\(prefix)\""),
                        systemName: "checkmark.seal.fill",
                        tint: .mint
                    ) {
                        manager.alwaysAllowPendingPermission(sessionKey: session.id)
                    }
                }
            }
        }
    }

    private func decisionButton(label: String, systemName: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Question (option chips)

    private func questionControls(for request: AgentQuestionRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.cyan)
                Text(request.header ?? request.question)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .lineLimit(2)
            }
            if request.header != nil {
                Text(request.question)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
            }
            // Wrap chips onto multiple rows if needed.
            FlowLayoutChips(labels: request.optionLabels) { label in
                manager.answerPendingQuestion(sessionKey: session.id, optionLabel: label)
            }
        }
    }
}

/// Simple chip strip for question options (max 4 options by protocol filter,
/// so a single wrapping HStack is sufficient).
private struct FlowLayoutChips: View {
    let labels: [String]
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels, id: \.self) { label in
                Button {
                    onSelect(label)
                } label: {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.16)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
