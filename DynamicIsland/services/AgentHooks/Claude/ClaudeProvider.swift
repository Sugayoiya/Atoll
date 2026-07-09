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
import Defaults
import SwiftUI

/// Claude Code provider adapter: maps raw Claude hook payloads to normalized
/// `AgentEvent`s and encodes decisions into Claude's `hookSpecificOutput`
/// reply schema. Claude-only extras (AskUserQuestion pre-answering) live here.
@MainActor
final class ClaudeProvider: AgentProvider {
    static let providerId = "claude"

    let id = ClaudeProvider.providerId
    let displayName = "Claude Code"
    let accentColor = Color(red: 0.85, green: 0.45, blue: 0.25)
    let icon: AgentProviderIcon = .asset(name: "AgentLogoClaude")

    /// Tools that trigger the notch Allow/Deny permission prompt.
    /// AskUserQuestion is NOT listed here: it goes through the dedicated
    /// question-answer flow (PoC verified interactive pre-answering works).
    /// ExitPlanMode stays excluded — answering it from the notch is out of scope.
    static let permissionPromptTools: Set<String> = ["Bash"]

    var isEnabled: Bool {
        Defaults[.enableClaudeCodeLiveActivity]
    }

    func mapEvent(_ envelope: AgentHookEnvelope) -> AgentEvent? {
        let payload = envelope.payload
        let sessionId = payload["session_id"]?.stringValue ?? ""
        let cwd = payload["cwd"]?.stringValue
        let tool = payload["tool_name"]?.stringValue

        let kind: AgentEvent.Kind
        var toolSummary: AgentEvent.ToolSummaryUpdate = .keep
        switch envelope.event {
        case "SessionStart":
            kind = .sessionStart
        case "SessionEnd":
            kind = .sessionEnd
        case "UserPromptSubmit":
            let preview = payload["prompt"]?.stringValue.map { String($0.prefix(200)) }
            kind = .promptSubmit(preview: preview)
        case "PreToolUse":
            kind = .toolWillRun(tool: tool)
            if let tool {
                toolSummary = .set(ClaudeToolSummary.summary(tool: tool, input: payload["tool_input"]))
            }
        case "PostToolUse":
            kind = .toolDidRun
            toolSummary = .clear
        case "PreCompact":
            kind = .compacting
        case "Stop":
            kind = .stopped
            toolSummary = .clear
        case "SubagentStop":
            kind = .subagentStopped
            toolSummary = .clear
        case "PermissionRequest":
            kind = .permissionRequested
            toolSummary = .clear
        default:
            return nil
        }

        return AgentEvent(provider: id, sessionId: sessionId, cwd: cwd, kind: kind, toolSummary: toolSummary)
    }

    func promptRequest(for envelope: AgentHookEnvelope) -> AgentPromptRequest? {
        let payload = envelope.payload
        guard let sessionId = payload["session_id"]?.stringValue, !sessionId.isEmpty,
              let tool = payload["tool_name"]?.stringValue else {
            return nil
        }
        let toolInput = payload["tool_input"]

        switch envelope.event {
        case "PreToolUse":
            // AskUserQuestion pre-answering stays on PreToolUse: it relies on
            // `permissionDecision: allow` + `updatedInput` (PoC-verified), which
            // only exists on this event.
            guard tool == "AskUserQuestion",
                  Defaults[.claudeCodeQuestionAnswerEnabled],
                  let question = ClaudeAskUserQuestion.parse(toolInput: toolInput) else {
                return nil
            }
            return .question(AgentQuestionRequest(
                provider: id,
                sessionId: sessionId,
                question: question.question,
                header: question.header,
                optionLabels: question.optionLabels,
                encodeAnswer: { label in
                    // Pre-answers AskUserQuestion: allow + updatedInput carrying
                    // the original questions (echoed verbatim) plus the `answers`
                    // map — `allow` alone is not sufficient for AskUserQuestion.
                    ClaudeHookResponse(
                        hookSpecificOutput: .init(
                            permissionDecision: .allow,
                            permissionDecisionReason: "Answered from Atoll notch",
                            updatedInput: question.updatedInput(choosing: label)
                        )
                    ).encoded()
                }
            ))

        case "PermissionRequest":
            // The Allow/Deny notch prompt hangs off PermissionRequest so that
            // allowlisted commands (which never trigger this event) skip the
            // notch entirely instead of waiting out the prompt timeout.
            guard Defaults[.claudeCodePermissionPromptEnabled],
                  Self.permissionPromptTools.contains(tool) else {
                return nil
            }
            return .permission(AgentPermissionRequest(
                provider: id,
                sessionId: sessionId,
                toolName: tool,
                inputSummary: ClaudeToolSummary.permissionSummary(tool: tool, input: toolInput),
                // Full command for auto-allow rule matching (Bash only today).
                rawCommand: tool == "Bash" ? toolInput?["command"]?.stringValue : nil,
                encodeDecision: { decision in
                    // PermissionRequest has no "ask": no reply = Claude shows
                    // its normal permission dialog.
                    switch decision {
                    case .allow:
                        return ClaudePermissionRequestResponse(behavior: .allow).encoded()
                    case .deny(let reason):
                        return ClaudePermissionRequestResponse(behavior: .deny, message: reason).encoded()
                    case .ask:
                        return nil
                    }
                }
            ))

        default:
            return nil
        }
    }

    nonisolated func installIfNeeded() {
        ClaudeHookInstaller.installIfNeeded()
    }

    nonisolated func uninstall() {
        ClaudeHookInstaller.uninstall()
    }

    nonisolated var isInstalled: Bool {
        ClaudeHookInstaller.isInstalled
    }
}
