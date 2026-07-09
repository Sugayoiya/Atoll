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
        QuestionPromptControls(request: request, accent: accent) { answers in
            manager.answerPendingQuestion(sessionKey: session.id, answers: answers)
        }
        // Reset local selection state when a different request arrives.
        .id(request.id)
    }
}

/// Interactive controls for a pending question request. A single
/// single-select question keeps the tap-to-answer behavior; multiSelect
/// and/or multi-question requests collect selections locally and submit the
/// full answer set with an explicit button (disabled until every question
/// has at least one selection).
private struct QuestionPromptControls: View {
    let request: AgentQuestionRequest
    let accent: Color
    let onSubmit: ([String: [String]]) -> Void

    /// Selected labels per question index (index-keyed so UI state never
    /// depends on question text uniqueness).
    @State private var selections: [Int: Set<String>] = [:]

    private var allQuestionsAnswered: Bool {
        request.questions.indices.allSatisfy { !(selections[$0] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                questionGroup(question, at: index)
            }
            if !request.isSingleTapAnswerable {
                submitButton
            }
        }
    }

    private func questionGroup(_ question: AgentQuestionRequest.Question, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.cyan)
                Text(question.header ?? question.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .lineLimit(2)
                if question.multiSelect {
                    Text("Select all that apply")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.gray)
                }
            }
            if question.header != nil {
                Text(question.text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(3)
            }
            ChipFlowLayout(spacing: 6) {
                ForEach(question.optionLabels, id: \.self) { label in
                    chip(label: label, question: question, index: index)
                }
            }
        }
    }

    private func chip(label: String, question: AgentQuestionRequest.Question, index: Int) -> some View {
        let isSelected = (selections[index] ?? []).contains(label)
        return Button {
            handleTap(label: label, question: question, index: index)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? accent : .white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(isSelected ? accent.opacity(0.22) : .white.opacity(0.16)))
                .overlay(Capsule().strokeBorder(isSelected ? accent.opacity(0.7) : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func handleTap(label: String, question: AgentQuestionRequest.Question, index: Int) {
        if request.isSingleTapAnswerable {
            onSubmit([question.text: [label]])
            return
        }
        var selected = selections[index] ?? []
        if question.multiSelect {
            if selected.contains(label) {
                selected.remove(label)
            } else {
                selected.insert(label)
            }
        } else {
            selected = selected.contains(label) ? [] : [label]
        }
        withAnimation(.smooth(duration: 0.15)) {
            selections[index] = selected
        }
    }

    private var submitButton: some View {
        Button {
            var answers: [String: [String]] = [:]
            for (index, question) in request.questions.enumerated() {
                let selected = selections[index] ?? []
                // Preserve the option order from the payload for multi answers.
                answers[question.text] = question.optionLabels.filter { selected.contains($0) }
            }
            onSubmit(answers)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Submit")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(allQuestionsAnswered ? accent : .gray)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Capsule().fill(allQuestionsAnswered ? accent.opacity(0.18) : .white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!allQuestionsAnswered)
    }
}

/// Wrapping chip layout: places subviews left-to-right and flows onto new
/// rows when the available width is exceeded (option counts and label
/// lengths are user-configurable now, so a single row no longer suffices).
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map { $0.width }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in computeRows(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let widthIfAdded = current.width + (current.indices.isEmpty ? 0 : spacing) + size.width
            if !current.indices.isEmpty, widthIfAdded > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
