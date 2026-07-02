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

import Foundation
import Combine
import Defaults
import SwiftUI

/// Tracks live Claude Code sessions from hook events and drives the
/// closed-notch Claude Code live activity.
@MainActor
final class ClaudeCodeManager: ObservableObject {
    static let shared = ClaudeCodeManager()

    enum SessionStatus: Equatable {
        case thinking
        case runningTool(String)
        case compacting
        case waitingForInput

        var label: String {
            switch self {
            case .thinking: return String(localized: "Thinking…")
            case .runningTool(let tool): return tool
            case .compacting: return String(localized: "Compacting…")
            case .waitingForInput: return String(localized: "Waiting")
            }
        }

        var iconName: String {
            switch self {
            case .thinking: return "brain"
            case .runningTool: return "hammer.fill"
            case .compacting: return "arrow.down.right.and.arrow.up.left"
            case .waitingForInput: return "bubble.left.and.exclamationmark.bubble.right.fill"
            }
        }

        var isBusy: Bool {
            switch self {
            case .waitingForInput: return false
            default: return true
            }
        }
    }

    struct Session: Identifiable, Equatable {
        let id: String
        var cwd: String
        var status: SessionStatus
        var lastUpdated: Date
        /// When the current status (case + payload) started, for the elapsed indicator.
        var statusChangedAt: Date
        /// Concise summary of the running tool's input (PreToolUse only).
        var toolSummary: String?
        /// Truncated preview of the latest user prompt, shown while thinking.
        var promptPreview: String?

        var projectName: String {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return name.isEmpty ? "Claude" : name
        }
    }

    /// A PreToolUse call awaiting an Allow/Deny decision from the notch.
    struct PermissionRequest: Identifiable, Equatable {
        let id = UUID()
        let sessionId: String
        let toolName: String
        /// Concise, truncated summary of the tool input (e.g. the bash command).
        let inputSummary: String
    }

    /// An AskUserQuestion call awaiting a chosen option from the notch.
    struct QuestionRequest: Identifiable, Equatable {
        let id = UUID()
        let sessionId: String
        let question: ClaudeAskUserQuestion
    }

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var pendingPermission: PermissionRequest?
    @Published private(set) var pendingQuestion: QuestionRequest?

    /// Whether an interactive prompt (permission Allow/Deny OR question
    /// chips — they share this flag) is actually on screen, reported by the
    /// live activity view (onAppear/onDisappear). The closed-notch tap guard
    /// reads this instead of the pending state: a pending request whose
    /// prompt lost the closed-notch priority chain (music/timer occupying the
    /// notch) must not swallow clicks. Not @Published — read imperatively
    /// from click handlers only.
    private(set) var isPermissionPromptVisible = false

    func setPermissionPromptVisible(_ visible: Bool) {
        isPermissionPromptVisible = visible
    }

    var isActive: Bool { !sessions.isEmpty }

    /// The most recently updated session, used for the compact live activity display.
    var primarySession: Session? {
        sessions.max(by: { $0.lastUpdated < $1.lastUpdated })
    }

    static let accentColor = Color(red: 0.85, green: 0.45, blue: 0.25)

    /// Tools that trigger the notch Allow/Deny permission prompt.
    /// AskUserQuestion is NOT listed here: it goes through the dedicated
    /// question-answer flow (PoC verified interactive pre-answering works).
    /// ExitPlanMode stays excluded — answering it from the notch is out of scope.
    static let permissionPromptTools: Set<String> = ["Bash"]

    /// UI budget for a pending prompt (permission or question). Must stay
    /// under the socket server's 4.5s response timeout so a nil resolution
    /// (no decision) still reaches the hook script before it gives up.
    private static let promptTimeout: TimeInterval = 4.0

    private var cancellables = Set<AnyCancellable>()
    private var staleCleanupTask: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    private var isRunning = false
    private let staleSessionTimeout: TimeInterval = 60 * 60

    private var promptContinuation: CheckedContinuation<ClaudeHookResponse?, Never>?
    private var promptTimeoutTask: Task<Void, Never>? { didSet { oldValue?.cancel() } }

    /// Permission and question prompts share a single pending slot: a second
    /// concurrent PreToolUse falls through to the terminal flow.
    private var hasPendingPrompt: Bool {
        pendingPermission != nil || pendingQuestion != nil
    }

    private init() {
        Defaults.publisher(.enableClaudeCodeLiveActivity, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                if change.newValue {
                    self?.startIfNeeded()
                } else {
                    self?.stop()
                }
            }
            .store(in: &cancellables)

        if Defaults[.enableClaudeCodeLiveActivity] {
            startIfNeeded()
        }
    }

    func startIfNeeded() {
        guard !isRunning else { return }
        isRunning = true

        Task.detached(priority: .utility) {
            ClaudeHookInstaller.installIfNeeded()
        }

        ClaudeHookSocketServer.shared.start { event in
            await ClaudeCodeManager.shared.process(event: event)
        }

        startStaleCleanup()
        Logger.log("Claude Code live activity started", category: .lifecycle)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        ClaudeHookSocketServer.shared.stop()
        staleCleanupTask = nil
        resolvePendingPrompt(with: nil)
        withAnimation(.smooth) {
            sessions.removeAll()
        }
        Logger.log("Claude Code live activity stopped", category: .lifecycle)
    }

    /// Removes the hook from Claude Code settings.json (called from Settings UI).
    func uninstallHook() {
        Task.detached(priority: .utility) {
            ClaudeHookInstaller.uninstall()
        }
    }

    /// Socket-server entry point: updates the live activity state and, for
    /// answerable PreToolUse calls, blocks (bounded) on a notch prompt.
    /// Returning nil sends no reply, so Claude's normal terminal flow runs.
    private func process(event: ClaudeHookEvent) async -> Data? {
        handle(event: event)

        // Empty session ids are dropped by handle(event:), so no session (and
        // no live activity) would exist to display the prompt — skip it too.
        guard event.event == "PreToolUse",
              !event.sessionId.isEmpty,
              Defaults[.enableClaudeCodeLiveActivity],
              let tool = event.tool else {
            return nil
        }

        if tool == "AskUserQuestion" {
            guard Defaults[.claudeCodeQuestionAnswerEnabled],
                  let question = ClaudeAskUserQuestion.parse(toolInput: event.toolInput) else {
                return nil
            }
            return await requestQuestionAnswer(for: event, question: question)?.encoded()
        }

        guard Defaults[.claudeCodePermissionPromptEnabled],
              Self.permissionPromptTools.contains(tool) else {
            return nil
        }
        return await requestPermissionDecision(for: event, tool: tool)?.encoded()
    }

    /// Presents the Allow/Deny prompt and suspends until the user acts, the
    /// UI budget elapses, or the session ends — whichever happens first.
    private func requestPermissionDecision(for event: ClaudeHookEvent, tool: String) async -> ClaudeHookResponse? {
        guard !hasPendingPrompt else { return nil }

        let request = PermissionRequest(
            sessionId: event.sessionId,
            toolName: tool,
            inputSummary: ClaudeToolSummary.permissionSummary(tool: tool, input: event.toolInput)
        )
        withAnimation(.smooth(duration: 0.25)) {
            pendingPermission = request
        }
        schedulePromptTimeout()

        return await withCheckedContinuation { continuation in
            // The request may already have been resolved (e.g. a Stop event)
            // in the suspension gap above; resume immediately in that case.
            if pendingPermission?.id == request.id {
                promptContinuation = continuation
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Presents the question chips and suspends until the user picks an
    /// option, the UI budget elapses, or the session ends.
    private func requestQuestionAnswer(for event: ClaudeHookEvent, question: ClaudeAskUserQuestion) async -> ClaudeHookResponse? {
        guard !hasPendingPrompt else { return nil }

        let request = QuestionRequest(sessionId: event.sessionId, question: question)
        withAnimation(.smooth(duration: 0.25)) {
            pendingQuestion = request
        }
        schedulePromptTimeout()

        return await withCheckedContinuation { continuation in
            if pendingQuestion?.id == request.id {
                promptContinuation = continuation
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    private func schedulePromptTimeout() {
        promptTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.promptTimeout))
            guard !Task.isCancelled else { return }
            self?.resolvePendingPrompt(with: nil)
        }
    }

    /// Called from the notch UI when the user taps Allow or Deny.
    func answerPendingPermission(allow: Bool) {
        // Guard against a stale tap resolving a prompt of the other kind: a
        // bare allow/deny must never answer a pending QUESTION (AskUserQuestion
        // requires allow + updatedInput, so that would silently drop the answer).
        guard pendingPermission != nil else { return }
        let decision = ClaudeHookResponse(
            hookSpecificOutput: .init(
                permissionDecision: allow ? .allow : .deny,
                permissionDecisionReason: allow ? "Allowed from Atoll notch" : "Denied from Atoll notch"
            )
        )
        resolvePendingPrompt(with: decision)
    }

    /// Called from the notch UI when the user taps an answer chip.
    /// Pre-answers AskUserQuestion: allow + updatedInput carrying the original
    /// questions (echoed verbatim) plus the `answers` map — `allow` alone is
    /// not sufficient for AskUserQuestion.
    func answerPendingQuestion(optionLabel: String) {
        guard let request = pendingQuestion else { return }
        let decision = ClaudeHookResponse(
            hookSpecificOutput: .init(
                permissionDecision: .allow,
                permissionDecisionReason: "Answered from Atoll notch",
                updatedInput: request.question.updatedInput(choosing: optionLabel)
            )
        )
        resolvePendingPrompt(with: decision)
    }

    /// Resolves (at most once) the pending prompt and tears down its UI.
    /// `nil` means "no decision": the hook exits silently and Claude's normal
    /// terminal flow takes over.
    private func resolvePendingPrompt(with decision: ClaudeHookResponse?) {
        promptTimeoutTask = nil
        guard hasPendingPrompt || promptContinuation != nil else { return }
        withAnimation(.smooth(duration: 0.25)) {
            pendingPermission = nil
            pendingQuestion = nil
        }
        let continuation = promptContinuation
        promptContinuation = nil
        continuation?.resume(returning: decision)
    }

    private func handle(event: ClaudeHookEvent) {
        guard Defaults[.enableClaudeCodeLiveActivity] else { return }
        guard !event.sessionId.isEmpty else { return }

        // A stop/end for the session that owns the pending prompt invalidates it.
        if ["SessionEnd", "Stop", "SubagentStop"].contains(event.event),
           pendingPermission?.sessionId == event.sessionId || pendingQuestion?.sessionId == event.sessionId {
            resolvePendingPrompt(with: nil)
        }

        switch event.event {
        case "SessionEnd":
            removeSession(id: event.sessionId)
            return
        case "SessionStart":
            upsertSession(event: event, status: .waitingForInput)
        case "UserPromptSubmit", "PostToolUse":
            upsertSession(event: event, status: .thinking)
        case "PreToolUse":
            upsertSession(event: event, status: .runningTool(event.tool ?? "Tool"))
        case "PreCompact":
            upsertSession(event: event, status: .compacting)
        case "Stop", "SubagentStop", "PermissionRequest":
            let wasBusy = sessions.first(where: { $0.id == event.sessionId })?.status.isBusy ?? false
            upsertSession(event: event, status: .waitingForInput)
            if wasBusy, event.event != "SubagentStop" {
                showAttentionSneakPeek(for: event)
            }
        default:
            return
        }
    }

    private func upsertSession(event: ClaudeHookEvent, status: SessionStatus) {
        let now = Date()

        // Display enrichment derived from the event, independent of status mapping.
        let toolSummary: String?? // .some(nil) clears, nil keeps the current value
        switch event.event {
        case "PreToolUse":
            toolSummary = event.tool.map { ClaudeToolSummary.summary(tool: $0, input: event.toolInput) }
        case "PostToolUse", "Stop", "SubagentStop", "PermissionRequest":
            toolSummary = .some(nil)
        default:
            toolSummary = nil
        }
        let promptPreview = event.event == "UserPromptSubmit"
            ? event.userPrompt?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        withAnimation(.smooth(duration: 0.25)) {
            if let index = sessions.firstIndex(where: { $0.id == event.sessionId }) {
                if sessions[index].status != status {
                    sessions[index].statusChangedAt = now
                }
                sessions[index].status = status
                sessions[index].lastUpdated = now
                if let cwd = event.cwd, !cwd.isEmpty {
                    sessions[index].cwd = cwd
                }
                if let toolSummary {
                    sessions[index].toolSummary = toolSummary
                }
                if let promptPreview, !promptPreview.isEmpty {
                    sessions[index].promptPreview = promptPreview
                }
            } else {
                sessions.append(Session(
                    id: event.sessionId,
                    cwd: event.cwd ?? "",
                    status: status,
                    lastUpdated: now,
                    statusChangedAt: now,
                    toolSummary: toolSummary ?? nil,
                    promptPreview: (promptPreview?.isEmpty == false) ? promptPreview : nil
                ))
            }
        }
    }

    private func removeSession(id: String) {
        withAnimation(.smooth(duration: 0.25)) {
            sessions.removeAll { $0.id == id }
        }
    }

    private func showAttentionSneakPeek(for event: ClaudeHookEvent) {
        guard Defaults[.claudeCodeSneakPeekEnabled] else { return }
        let projectName = URL(fileURLWithPath: event.cwd ?? "").lastPathComponent
        let title = projectName.isEmpty ? "Claude Code" : projectName
        let subtitle = event.event == "PermissionRequest"
            ? String(localized: "Permission requested")
            : String(localized: "Ready for input")
        DynamicIslandViewCoordinator.shared.toggleSneakPeek(
            status: true,
            type: .claudeCode,
            duration: 3,
            title: title,
            subtitle: subtitle,
            accentColor: Self.accentColor
        )
    }

    private func startStaleCleanup() {
        staleCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self, !Task.isCancelled else { return }
                let cutoff = Date().addingTimeInterval(-self.staleSessionTimeout)
                if self.sessions.contains(where: { $0.lastUpdated < cutoff }) {
                    withAnimation(.smooth) {
                        self.sessions.removeAll { $0.lastUpdated < cutoff }
                    }
                }
            }
        }
    }
}
