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

/// Normalized agent hook event, produced by a provider adapter from a raw
/// `AgentHookEnvelope`. This is the only event vocabulary the session
/// manager understands.
struct AgentEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionStart
        case sessionEnd
        /// Truncated preview of the submitted user prompt, when available.
        case promptSubmit(preview: String?)
        /// A tool is about to run. `tool` may be nil if the provider didn't
        /// name it; the display falls back to a generic label.
        case toolWillRun(tool: String?)
        case toolDidRun
        case compacting
        /// Agent finished a turn and awaits input (sneak peek eligible).
        case stopped
        /// A subagent finished; awaits input but never sneak-peeks.
        case subagentStopped
        /// The provider surfaced a permission request outside the notch flow.
        case permissionRequested
    }

    /// How this event affects the session's displayed tool summary.
    enum ToolSummaryUpdate: Equatable, Sendable {
        case keep
        case clear
        case set(String)
    }

    let provider: String
    let sessionId: String
    let cwd: String?
    let kind: Kind
    let toolSummary: ToolSummaryUpdate

    init(provider: String, sessionId: String, cwd: String?, kind: Kind, toolSummary: ToolSummaryUpdate = .keep) {
        self.provider = provider
        self.sessionId = sessionId
        self.cwd = cwd
        self.kind = kind
        self.toolSummary = toolSummary
    }
}

/// Generic tool-permission decision made from the notch. Each provider
/// encodes it into its own hook reply schema.
enum AgentDecision: Equatable, Sendable {
    case allow(reason: String?)
    case deny(reason: String?)
    case ask(reason: String?)
}

/// A tool call awaiting an Allow/Deny decision from the notch.
/// `encodeDecision` is supplied by the provider adapter and turns the generic
/// decision into the provider's reply bytes (nil = send no reply).
struct AgentPermissionRequest: Identifiable {
    let id = UUID()
    let provider: String
    let sessionId: String
    let toolName: String
    /// Concise, truncated summary of the tool input (e.g. the bash command).
    let inputSummary: String
    /// Full, untruncated shell command for auto-allow rule matching.
    /// nil for non-shell tools (e.g. MCP calls) — those never auto-allow.
    let rawCommand: String?
    /// Workspace root from the hook payload (Cursor `workspace_roots[0]`),
    /// used to locate the workspace-level Cursor allowlist. nil otherwise.
    let workspaceRoot: String?
    let encodeDecision: @Sendable (AgentDecision) -> Data?

    init(
        provider: String,
        sessionId: String,
        toolName: String,
        inputSummary: String,
        rawCommand: String? = nil,
        workspaceRoot: String? = nil,
        encodeDecision: @escaping @Sendable (AgentDecision) -> Data?
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.toolName = toolName
        self.inputSummary = inputSummary
        self.rawCommand = rawCommand
        self.workspaceRoot = workspaceRoot
        self.encodeDecision = encodeDecision
    }
}

/// One or more questions awaiting chosen options from the notch (Claude-only
/// today). `encodeAnswer` turns the full answer set — selected labels keyed by
/// question text — into the provider's reply bytes (nil = send no reply).
struct AgentQuestionRequest: Identifiable {
    struct Question: Equatable, Sendable {
        /// Full question text; also the key in the answer set.
        let text: String
        /// Short topic tag (e.g. "Color"), preferred over the text when present.
        let header: String?
        let multiSelect: Bool
        let optionLabels: [String]
    }

    let id = UUID()
    let provider: String
    let sessionId: String
    let questions: [Question]
    let encodeAnswer: @Sendable ([String: [String]]) -> Data?

    /// True when a single tap can answer the whole request (one single-select
    /// question); otherwise the UI collects selections and submits explicitly.
    var isSingleTapAnswerable: Bool {
        questions.count == 1 && !(questions.first?.multiSelect ?? false)
    }
}

/// An interactive prompt derived by a provider adapter from a raw envelope.
enum AgentPromptRequest {
    case permission(AgentPermissionRequest)
    case question(AgentQuestionRequest)
}
