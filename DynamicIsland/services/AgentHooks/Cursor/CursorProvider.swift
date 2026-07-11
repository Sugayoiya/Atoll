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

/// Cursor provider adapter: maps raw Cursor hook payloads to normalized
/// `AgentEvent`s and derives permission prompts for
/// beforeShellExecution/beforeMCPExecution, encoding decisions into Cursor's
/// flat `{permission, user_message, agent_message}` reply schema.
@MainActor
final class CursorProvider: AgentProvider {
    static let providerId = "cursor"

    let id = CursorProvider.providerId
    let displayName = "Cursor"
    // Neutral blue, distinct from Claude's orange (Cursor brand is dark/white).
    let accentColor = Color(red: 0.35, green: 0.55, blue: 0.95)
    let icon: AgentProviderIcon = .asset(name: "AgentLogoCursor")

    var isEnabled: Bool {
        Defaults[.enableCursorLiveActivity]
    }

    func mapEvent(_ envelope: AgentHookEnvelope) -> AgentEvent? {
        let payload = envelope.payload
        // Cursor's stable per-conversation id plays the role of session_id.
        let sessionId = payload["conversation_id"]?.stringValue ?? ""
        // workspace_roots[0] serves as the session cwd for display; absent on
        // some events — the manager's upsert keeps the prior value then.
        let cwd: String?
        if case .array(let roots)? = payload["workspace_roots"], let first = roots.first {
            cwd = first.stringValue
        } else {
            cwd = nil
        }

        let kind: AgentEvent.Kind
        var toolSummary: AgentEvent.ToolSummaryUpdate = .keep
        switch envelope.event {
        case "sessionStart":
            kind = .sessionStart
        case "sessionEnd":
            kind = .sessionEnd
        case "beforeSubmitPrompt":
            let preview = payload["prompt"]?.stringValue.map { String($0.prefix(200)) }
            kind = .promptSubmit(preview: preview)
        case "preToolUse":
            let tool = payload["tool_name"]?.stringValue
            kind = .toolWillRun(tool: tool)
            if let tool {
                toolSummary = .set(Self.toolSummary(tool: tool, input: payload["tool_input"]))
            }
        case "postToolUse":
            kind = .toolDidRun
            toolSummary = .clear
        case "preCompact":
            kind = .compacting
        case "stop":
            kind = .stopped
            toolSummary = .clear
        case "subagentStop":
            kind = .subagentStopped
            toolSummary = .clear
        case "beforeShellExecution":
            // Keep runningTool for the tool label / summary; `present()` clears
            // busy to waitingForInput for the Allow wait (mirrors Claude's
            // PermissionRequest path without firing sneak-peek on every shell).
            kind = .toolWillRun(tool: "Shell")
            if let command = payload["command"]?.stringValue {
                toolSummary = .set(Self.truncate(command, maxLength: 60))
            }
        case "beforeMCPExecution":
            let mcpTool = Self.mcpToolName(payload: payload)
            kind = .toolWillRun(tool: mcpTool)
            toolSummary = .set(Self.truncate(Self.mcpSummary(payload: payload), maxLength: 60))
        default:
            return nil
        }

        return AgentEvent(provider: id, sessionId: sessionId, cwd: cwd, kind: kind, toolSummary: toolSummary)
    }

    /// beforeShellExecution/beforeMCPExecution derive an Allow/Deny prompt.
    /// Everything else (including preToolUse, whose "ask" is not enforced by
    /// Cursor) is fire-and-forget.
    func promptRequest(for envelope: AgentHookEnvelope) -> AgentPromptRequest? {
        guard Defaults[.cursorPermissionPromptEnabled] else { return nil }
        let payload = envelope.payload
        guard let sessionId = payload["conversation_id"]?.stringValue, !sessionId.isEmpty else {
            return nil
        }

        let toolName: String
        let inputSummary: String
        // Full command for auto-allow matching; nil for MCP calls (no shell
        // command → never auto-allowed).
        let rawCommand: String?
        switch envelope.event {
        case "beforeShellExecution":
            toolName = "Shell"
            rawCommand = payload["command"]?.stringValue
            inputSummary = Self.truncate(rawCommand ?? "", maxLength: 120)
        case "beforeMCPExecution":
            toolName = Self.mcpToolName(payload: payload)
            rawCommand = nil
            inputSummary = Self.truncate(Self.mcpSummary(payload: payload), maxLength: 120)
        default:
            return nil
        }

        // workspace_roots[0] locates the workspace-level Cursor allowlist.
        let workspaceRoot: String?
        if case .array(let roots)? = payload["workspace_roots"], let first = roots.first {
            workspaceRoot = first.stringValue
        } else {
            workspaceRoot = nil
        }

        return .permission(AgentPermissionRequest(
            provider: id,
            sessionId: sessionId,
            toolName: toolName,
            inputSummary: inputSummary,
            rawCommand: rawCommand,
            workspaceRoot: workspaceRoot,
            encodeDecision: { decision in
                // Flat Cursor reply — NO hookSpecificOutput nesting. "ask" maps
                // to no reply: Cursor tolerates it in the schema but treating
                // it as "no decision" keeps behavior identical to a timeout.
                let permission: String
                let reason: String?
                switch decision {
                case .allow(let r): permission = "allow"; reason = r
                case .deny(let r): permission = "deny"; reason = r
                case .ask: return nil
                }
                var reply: [String: Any] = ["permission": permission]
                if let reason {
                    reply["user_message"] = reason
                    reply["agent_message"] = reason
                }
                return try? JSONSerialization.data(withJSONObject: reply)
            }
        ))
    }

    nonisolated func installIfNeeded() {
        CursorHookInstaller.installIfNeeded()
    }

    nonisolated func uninstall() {
        CursorHookInstaller.uninstall()
    }

    nonisolated var isInstalled: Bool {
        CursorHookInstaller.isInstalled
    }

    /// Display name for a beforeMCPExecution tool call, prefixed "MCP".
    private static func mcpToolName(payload: JSONValue) -> String {
        if let tool = payload["tool_name"]?.stringValue, !tool.isEmpty {
            return "MCP \(tool)"
        }
        return "MCP"
    }

    /// Summary for a beforeMCPExecution call: joins string-valued tool_input
    /// fields as `key: value` pairs (mirrors Claude's permissionSummary
    /// fallback), falling back to the tool name.
    private static func mcpSummary(payload: JSONValue) -> String {
        guard case .object(let fields)? = payload["tool_input"], !fields.isEmpty else {
            return payload["tool_name"]?.stringValue ?? "MCP"
        }
        let joined = fields
            .sorted { $0.key < $1.key }
            .compactMap { key, value -> String? in
                guard case .string(let string) = value, !string.isEmpty else { return nil }
                return "\(key): \(string)"
            }
            .joined(separator: ", ")
        return joined.isEmpty ? (payload["tool_name"]?.stringValue ?? "MCP") : joined
    }

    /// Collapses newlines and truncates with an ellipsis, like the Claude
    /// summary conventions.
    private static func truncate(_ text: String, maxLength: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }

    /// Concise one-line summary of a Cursor tool call for the live activity.
    /// Cursor's `preToolUse` is generic across tools, so pick the most
    /// displayable string field rather than hardcoding per-tool shapes.
    private static func toolSummary(tool: String, input: JSONValue?, maxLength: Int = 60) -> String {
        guard case .object(let fields)? = input else { return tool }

        let preferredKeys = ["command", "file_path", "path", "pattern", "query", "url"]
        var detail: String?
        for key in preferredKeys {
            if case .string(let value)? = fields[key], !value.isEmpty {
                detail = (key == "file_path" || key == "path") ? URL(fileURLWithPath: value).lastPathComponent : value
                break
            }
        }

        guard let detail else { return tool }
        let collapsed = detail
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return tool }
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }
}
