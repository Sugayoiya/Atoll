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

/// Decision JSON returned to a Claude Code hook (printed to the hook's stdout).
/// Schema per code.claude.com/docs/en/hooks — PreToolUse decision control lives
/// inside `hookSpecificOutput`, not at the top level.
struct ClaudeHookResponse: Codable, Equatable, Sendable {
    let hookSpecificOutput: HookSpecificOutput

    struct HookSpecificOutput: Codable, Equatable, Sendable {
        /// Always the originating event name, e.g. "PreToolUse".
        let hookEventName: String
        /// "allow" | "deny" | "ask" | "defer" (defer is headless-only).
        let permissionDecision: PermissionDecision
        let permissionDecisionReason: String?
        /// Replaces the ENTIRE tool input object — include unchanged fields.
        let updatedInput: JSONValue?
        /// Optional extra context appended to Claude's context.
        let additionalContext: String?

        init(
            hookEventName: String = "PreToolUse",
            permissionDecision: PermissionDecision,
            permissionDecisionReason: String? = nil,
            updatedInput: JSONValue? = nil,
            additionalContext: String? = nil
        ) {
            self.hookEventName = hookEventName
            self.permissionDecision = permissionDecision
            self.permissionDecisionReason = permissionDecisionReason
            self.updatedInput = updatedInput
            self.additionalContext = additionalContext
        }
    }

    enum PermissionDecision: String, Codable, Sendable {
        case allow
        case deny
        case ask
        case defer_ = "defer"
    }

    init(hookSpecificOutput: HookSpecificOutput) {
        self.hookSpecificOutput = hookSpecificOutput
    }

    /// Serializes the decision for writing back on the hook socket.
    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

/// Decision JSON for the `PermissionRequest` hook event. Unlike PreToolUse's
/// `permissionDecision`, this event expects `decision.behavior` with only
/// "allow" | "deny" — there is no "ask": sending no reply at all lets Claude
/// show its normal permission dialog.
struct ClaudePermissionRequestResponse: Codable, Equatable, Sendable {
    let hookSpecificOutput: HookSpecificOutput

    struct HookSpecificOutput: Codable, Equatable, Sendable {
        /// Always "PermissionRequest".
        let hookEventName: String
        let decision: Decision

        init(decision: Decision) {
            self.hookEventName = "PermissionRequest"
            self.decision = decision
        }
    }

    struct Decision: Codable, Equatable, Sendable {
        let behavior: Behavior
        /// Deny reason, surfaced back to Claude.
        let message: String?
    }

    enum Behavior: String, Codable, Sendable {
        case allow
        case deny
    }

    init(behavior: Behavior, message: String? = nil) {
        self.hookSpecificOutput = HookSpecificOutput(decision: Decision(behavior: behavior, message: message))
    }

    /// Serializes the decision for writing back on the hook socket.
    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
