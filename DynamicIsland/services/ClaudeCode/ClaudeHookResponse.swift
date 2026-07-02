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

/// Minimal JSON value tree used for `updatedInput`, whose shape is
/// tool-specific and can't be modeled with a fixed struct.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
