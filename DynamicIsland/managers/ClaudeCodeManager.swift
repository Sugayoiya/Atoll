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

        var projectName: String {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return name.isEmpty ? "Claude" : name
        }
    }

    @Published private(set) var sessions: [Session] = []

    var isActive: Bool { !sessions.isEmpty }

    /// The most recently updated session, used for the compact live activity display.
    var primarySession: Session? {
        sessions.max(by: { $0.lastUpdated < $1.lastUpdated })
    }

    static let accentColor = Color(red: 0.85, green: 0.45, blue: 0.25)

    private var cancellables = Set<AnyCancellable>()
    private var staleCleanupTask: Task<Void, Never>? { didSet { oldValue?.cancel() } }
    private var isRunning = false
    private let staleSessionTimeout: TimeInterval = 60 * 60

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
            Task { @MainActor in
                ClaudeCodeManager.shared.handle(event: event)
            }
        }

        startStaleCleanup()
        Logger.log("Claude Code live activity started", category: .lifecycle)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        ClaudeHookSocketServer.shared.stop()
        staleCleanupTask = nil
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

    private func handle(event: ClaudeHookEvent) {
        guard Defaults[.enableClaudeCodeLiveActivity] else { return }
        guard !event.sessionId.isEmpty else { return }

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
        withAnimation(.smooth(duration: 0.25)) {
            if let index = sessions.firstIndex(where: { $0.id == event.sessionId }) {
                sessions[index].status = status
                sessions[index].lastUpdated = now
                if let cwd = event.cwd, !cwd.isEmpty {
                    sessions[index].cwd = cwd
                }
            } else {
                sessions.append(Session(
                    id: event.sessionId,
                    cwd: event.cwd ?? "",
                    status: status,
                    lastUpdated: now
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
