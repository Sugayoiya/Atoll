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

/// Tracks live agent sessions (Claude Code, and future providers) from hook
/// events and drives the closed-notch agent live activity.
///
/// Provider-specific behavior (event normalization, reply encoding, hook
/// installation) lives in `AgentProvider` adapters; this manager owns the
/// shared session list, the per-session pending prompts, and their timeout chain.
@MainActor
final class AgentSessionManager: ObservableObject {
    static let shared = AgentSessionManager()

    /// Registered provider adapters, keyed by envelope `provider` id.
    /// PR2 adds Cursor here.
    let providers: [String: AgentProvider]

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
        /// Provider id ("claude", ...) — sessions are keyed by (provider, sessionId).
        let provider: String
        let sessionId: String
        var cwd: String
        var status: SessionStatus
        var lastUpdated: Date
        /// When the current status (case + payload) started, for the elapsed indicator.
        var statusChangedAt: Date
        /// Concise summary of the running tool's input (toolWillRun only).
        var toolSummary: String?
        /// Truncated preview of the latest user prompt, shown while thinking.
        var promptPreview: String?

        var id: String { "\(provider):\(sessionId)" }

        var projectName: String {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return name.isEmpty ? "Agent" : name
        }
    }

    /// An interactive prompt (permission Allow/Deny or question) awaiting a
    /// user decision, presented in the expanded-notch Agents tab.
    enum PendingPrompt: Identifiable {
        case permission(AgentPermissionRequest)
        case question(AgentQuestionRequest)

        var id: UUID {
            switch self {
            case .permission(let request): return request.id
            case .question(let request): return request.id
            }
        }

        /// Session key ("provider:sessionId") this prompt belongs to.
        var sessionKey: String {
            switch self {
            case .permission(let request): return "\(request.provider):\(request.sessionId)"
            case .question(let request): return "\(request.provider):\(request.sessionId)"
            }
        }
    }

    @Published private(set) var sessions: [Session] = []
    /// Per-session pending prompts, keyed by session key ("provider:sessionId").
    /// Multiple sessions can wait concurrently; a second prompt for the SAME
    /// session while one is pending falls through to the provider's own flow.
    @Published private(set) var pendingPrompts: [String: PendingPrompt] = [:]

    var hasPendingPrompts: Bool { !pendingPrompts.isEmpty }

    func pendingPrompt(for session: Session) -> PendingPrompt? {
        pendingPrompts[session.id]
    }

    var isActive: Bool { !sessions.isEmpty }

    /// The most recently updated session, used for the compact live activity display.
    var primarySession: Session? {
        sessions.max(by: { $0.lastUpdated < $1.lastUpdated })
    }

    /// Fallback accent when no provider context is available (sneak peek etc.).
    static let defaultAccentColor = Color(red: 0.85, green: 0.45, blue: 0.25)

    func provider(for id: String) -> AgentProvider? {
        providers[id]
    }

    func accentColor(for providerId: String) -> Color {
        providers[providerId]?.accentColor ?? Self.defaultAccentColor
    }

    /// UI budget for a pending prompt (permission or question), giving the
    /// user time to expand the notch and answer in the Agents tab. Must stay
    /// under the socket server's response timeout (UI+5s) so a nil resolution
    /// (no decision) still reaches the hook script before it gives up.
    /// Chain invariant: UI < server (UI+5) < script recv (UI+10) < host hook timeout (UI+20).
    /// User-configurable; read at schedule time so changes apply immediately.
    private static var promptTimeout: TimeInterval { AgentPromptTimeout.uiSeconds }

    private var cancellables = Set<AnyCancellable>()
    private var staleCleanupTask: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    private var isRunning = false
    private let staleSessionTimeout: TimeInterval = 60 * 60

    /// Per-session continuations resolving with the provider-encoded reply
    /// bytes (nil = no decision), keyed by session key.
    private var promptContinuations: [String: CheckedContinuation<Data?, Never>] = [:]
    private var promptTimeoutTasks: [String: Task<Void, Never>] = [:]

    private var anyProviderEnabled: Bool {
        providers.values.contains { $0.isEnabled }
    }

    private init() {
        let claude = ClaudeProvider()
        let cursor = CursorProvider()
        providers = [claude.id: claude, cursor.id: cursor]

        // Each provider's enable toggle starts/stops the shared socket server:
        // it runs while ANY provider is enabled. The prompt-timeout key is
        // included so changing it re-runs installIfNeeded(): the installers'
        // content diffing rewrites the hook scripts and config timeouts.
        Defaults.publisher(keys: .enableClaudeCodeLiveActivity, .enableCursorLiveActivity, .agentPromptTimeoutSeconds, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshRunningState()
            }
            .store(in: &cancellables)

        if anyProviderEnabled {
            startIfNeeded()
        }
    }

    private func refreshRunningState() {
        if anyProviderEnabled {
            startIfNeeded()
            // A provider toggled on while the server is already running still
            // needs its hooks installed (startIfNeeded is a no-op then).
            installEnabledProviders()
        } else {
            stop()
        }
        // Drop sessions of providers that were just disabled.
        let disabled = sessions.filter { providers[$0.provider]?.isEnabled != true }
        if !disabled.isEmpty {
            for session in disabled {
                resolvePendingPrompt(sessionKey: session.id, with: nil)
            }
            withAnimation(.smooth) {
                sessions.removeAll { session in disabled.contains(where: { $0.id == session.id }) }
            }
        }
    }

    func startIfNeeded() {
        guard !isRunning else { return }
        isRunning = true

        installEnabledProviders()

        AgentHookSocketServer.shared.start { envelope in
            await AgentSessionManager.shared.process(envelope: envelope)
        }

        startStaleCleanup()
        Logger.log("Agent session live activity started", category: .lifecycle)
    }

    private func installEnabledProviders() {
        let enabledProviders = providers.values.filter { $0.isEnabled }
        Task.detached(priority: .utility) {
            for provider in enabledProviders {
                provider.installIfNeeded()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        AgentHookSocketServer.shared.stop()
        staleCleanupTask = nil
        resolveAllPendingPrompts()
        withAnimation(.smooth) {
            sessions.removeAll()
        }
        Logger.log("Agent session live activity stopped", category: .lifecycle)
    }

    /// Removes a provider's hook installation (called from Settings UI).
    func uninstallHook(providerId: String) {
        guard let provider = providers[providerId] else { return }
        Task.detached(priority: .utility) {
            provider.uninstall()
        }
    }

    /// Socket-server entry point: updates the live activity state and, for
    /// answerable tool calls, blocks (bounded) on a notch prompt.
    /// Returning nil sends no reply, so the provider's normal flow runs.
    private func process(envelope: AgentHookEnvelope) async -> Data? {
        guard let provider = providers[envelope.provider], provider.isEnabled else {
            return nil
        }

        if let event = provider.mapEvent(envelope) {
            handle(event: event)
        }

        // Empty session ids are dropped by handle(event:), so no session (and
        // no live activity) would exist to display the prompt — providers
        // already guard on that inside promptRequest(for:).
        guard let prompt = provider.promptRequest(for: envelope) else {
            return nil
        }
        switch prompt {
        case .permission(let request):
            // Auto-allow (Atoll rules / Cursor allowlist) short-circuits the
            // notch prompt entirely: reply immediately, never enter
            // pendingPrompts. Session status display is unaffected (mapEvent
            // already ran above).
            if let reply = autoAllowReply(for: request) {
                return reply
            }
            return await present(prompt: .permission(request))
        case .question(let request):
            return await present(prompt: .question(request))
        }
    }

    /// Returns the encoded allow reply when the request's shell command
    /// matches an Atoll auto-allow rule or (Cursor only) the user's existing
    /// Cursor allowlist. nil = no auto decision, show the notch prompt.
    private func autoAllowReply(for request: AgentPermissionRequest) -> Data? {
        guard let command = request.rawCommand,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if Defaults[.agentAutoAllowEnabled] {
            let rules = Defaults[.agentAutoAllowRules]
                .filter { $0.provider == nil || $0.provider == request.provider }
                .map(\.ruleText)
            if AgentCommandMatcher.command(command, isFullyAllowedBy: rules) {
                Logger.log("Auto-allowed \(request.provider) command by Atoll rule", category: .debug)
                return request.encodeDecision(.allow(reason: "Auto-allowed by Atoll rule"))
            }
        }

        if request.provider == CursorProvider.providerId, Defaults[.cursorAllowlistAutoAllowEnabled] {
            let entries = CursorAllowlistReader.shared.allowlistEntries(workspaceRoot: request.workspaceRoot)
            if AgentCommandMatcher.command(command, isFullyAllowedBy: entries) {
                Logger.log("Auto-allowed Cursor command by Cursor allowlist", category: .debug)
                return request.encodeDecision(.allow(reason: "Auto-allowed by Cursor allowlist"))
            }
        }

        return nil
    }

    /// Presents the prompt in the Agents tab and suspends until the user
    /// answers, the UI budget elapses, or the session ends — whichever
    /// happens first. A second prompt for the SAME session while one is
    /// pending resolves to nil immediately (provider's own flow runs).
    private func present(prompt: PendingPrompt) async -> Data? {
        let key = prompt.sessionKey
        guard pendingPrompts[key] == nil else { return nil }

        withAnimation(.smooth(duration: 0.25)) {
            pendingPrompts[key] = prompt
        }
        schedulePromptTimeout(for: key)

        return await withCheckedContinuation { continuation in
            // The request may already have been resolved (e.g. a Stop event)
            // in the suspension gap above; resume immediately in that case.
            if pendingPrompts[key]?.id == prompt.id {
                promptContinuations[key] = continuation
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    private func schedulePromptTimeout(for key: String) {
        promptTimeoutTasks[key]?.cancel()
        promptTimeoutTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.promptTimeout))
            guard !Task.isCancelled else { return }
            self?.resolvePendingPrompt(sessionKey: key, with: nil)
        }
    }

    /// Called from the Agents tab when the user taps Allow or Deny.
    func answerPendingPermission(sessionKey: String, allow: Bool) {
        // Guard against a stale tap resolving a prompt of the other kind: a
        // bare allow/deny must never answer a pending QUESTION (question
        // replies need the provider's answer encoding, so that would silently
        // drop the answer).
        guard case .permission(let request)? = pendingPrompts[sessionKey] else { return }
        let decision: AgentDecision = allow
            ? .allow(reason: "Allowed from Atoll notch")
            : .deny(reason: "Denied from Atoll notch")
        resolvePendingPrompt(sessionKey: sessionKey, with: request.encodeDecision(decision))
    }

    /// Called from the Agents tab when the user taps "Always Allow": stores a
    /// smart-prefix auto-allow rule (first word, or first two words for
    /// multi-subcommand tools like git/npm) and resolves the prompt with allow.
    func alwaysAllowPendingPermission(sessionKey: String) {
        guard case .permission(let request)? = pendingPrompts[sessionKey] else { return }
        if let command = request.rawCommand,
           AgentCommandMatcher.canSuggestRule(for: command),
           let prefix = AgentCommandMatcher.smartPrefix(for: command) {
            var rules = Defaults[.agentAutoAllowRules]
            if !rules.contains(where: { $0.ruleText == prefix && $0.provider == nil }) {
                rules.append(AgentAutoAllowRule(ruleText: prefix))
                Defaults[.agentAutoAllowRules] = rules
            }
        }
        resolvePendingPrompt(sessionKey: sessionKey, with: request.encodeDecision(.allow(reason: "Allowed from Atoll notch")))
    }

    /// Called from the Agents tab when the user taps an answer option.
    func answerPendingQuestion(sessionKey: String, optionLabel: String) {
        guard case .question(let request)? = pendingPrompts[sessionKey] else { return }
        resolvePendingPrompt(sessionKey: sessionKey, with: request.encodeAnswer(optionLabel))
    }

    /// Resolves (at most once) the session's pending prompt and tears down
    /// its UI. `nil` means "no decision": the hook exits silently and the
    /// provider's normal flow takes over.
    private func resolvePendingPrompt(sessionKey key: String, with reply: Data?) {
        promptTimeoutTasks[key]?.cancel()
        promptTimeoutTasks[key] = nil
        guard pendingPrompts[key] != nil || promptContinuations[key] != nil else { return }
        withAnimation(.smooth(duration: 0.25)) {
            _ = pendingPrompts.removeValue(forKey: key)
        }
        let continuation = promptContinuations.removeValue(forKey: key)
        continuation?.resume(returning: reply)
    }

    private func resolveAllPendingPrompts() {
        for key in Set(pendingPrompts.keys).union(promptContinuations.keys) {
            resolvePendingPrompt(sessionKey: key, with: nil)
        }
    }

    private func handle(event: AgentEvent) {
        guard !event.sessionId.isEmpty else { return }

        // A stop/end for a session invalidates its pending prompt.
        let endsSession: Bool
        switch event.kind {
        case .sessionEnd, .stopped, .subagentStopped: endsSession = true
        default: endsSession = false
        }
        if endsSession {
            resolvePendingPrompt(sessionKey: "\(event.provider):\(event.sessionId)", with: nil)
        }

        switch event.kind {
        case .sessionEnd:
            removeSession(provider: event.provider, sessionId: event.sessionId)
            return
        case .sessionStart:
            upsertSession(event: event, status: .waitingForInput)
        case .promptSubmit, .toolDidRun:
            upsertSession(event: event, status: .thinking)
        case .toolWillRun(let tool):
            upsertSession(event: event, status: .runningTool(tool ?? "Tool"))
        case .compacting:
            upsertSession(event: event, status: .compacting)
        case .stopped, .subagentStopped, .permissionRequested:
            let wasBusy = sessions.first(where: { $0.provider == event.provider && $0.sessionId == event.sessionId })?.status.isBusy ?? false
            upsertSession(event: event, status: .waitingForInput)
            if wasBusy, event.kind != .subagentStopped {
                showAttentionSneakPeek(for: event)
            }
        }
    }

    private func upsertSession(event: AgentEvent, status: SessionStatus) {
        let now = Date()

        // Display enrichment derived from the event, independent of status mapping.
        let toolSummary: String?? // .some(nil) clears, nil keeps the current value
        switch event.toolSummary {
        case .keep: toolSummary = nil
        case .clear: toolSummary = .some(nil)
        case .set(let summary): toolSummary = .some(summary)
        }
        let promptPreview: String?
        if case .promptSubmit(let preview) = event.kind {
            promptPreview = preview?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            promptPreview = nil
        }

        withAnimation(.smooth(duration: 0.25)) {
            if let index = sessions.firstIndex(where: { $0.provider == event.provider && $0.sessionId == event.sessionId }) {
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
                    provider: event.provider,
                    sessionId: event.sessionId,
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

    private func removeSession(provider: String, sessionId: String) {
        withAnimation(.smooth(duration: 0.25)) {
            sessions.removeAll { $0.provider == provider && $0.sessionId == sessionId }
        }
    }

    private func showAttentionSneakPeek(for event: AgentEvent) {
        guard Defaults[.claudeCodeSneakPeekEnabled] else { return }
        let providerName = providers[event.provider]?.displayName ?? "Agent"
        let projectName = URL(fileURLWithPath: event.cwd ?? "").lastPathComponent
        let title = projectName.isEmpty ? providerName : projectName
        let subtitle = event.kind == .permissionRequested
            ? String(localized: "Permission requested")
            : String(localized: "Ready for input")
        DynamicIslandViewCoordinator.shared.toggleSneakPeek(
            status: true,
            type: .claudeCode,
            duration: 3,
            // Brand asset name so the sneak peek shows the provider's logo
            // (empty falls back to the asterisk SF Symbol in ContentView).
            icon: providers[event.provider]?.icon.assetName ?? "",
            title: title,
            subtitle: subtitle,
            accentColor: accentColor(for: event.provider)
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
