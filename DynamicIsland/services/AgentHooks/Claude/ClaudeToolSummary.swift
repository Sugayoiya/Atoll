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

/// Pure helpers that turn a Claude Code tool call (`tool_name` + `tool_input`)
/// into a concise, one-line, human-readable summary for the live activity.
enum ClaudeToolSummary {
    /// Builds a display string like `"git status"` (Bash), `"Constants.swift"`
    /// (Edit/Write/Read), or `"pattern"` (Grep/Glob). Falls back to the bare
    /// tool name when the input carries nothing displayable.
    static func summary(tool: String, input: JSONValue?, maxLength: Int = 60) -> String {
        guard let detail = detail(tool: tool, input: input) else { return tool }
        return truncate(collapseWhitespace(detail), to: maxLength, fallback: tool)
    }

    /// The tool-specific detail string, before whitespace collapsing/truncation.
    private static func detail(tool: String, input: JSONValue?) -> String? {
        guard case .object(let fields)? = input else { return nil }

        switch tool {
        case "Bash":
            return string(fields["command"])
        case "Edit", "Write", "Read", "NotebookEdit":
            return string(fields["file_path"]).map { URL(fileURLWithPath: $0).lastPathComponent }
        case "Grep", "Glob":
            return string(fields["pattern"])
        case "WebFetch":
            return string(fields["url"]).flatMap { URL(string: $0)?.host ?? $0 }
        case "WebSearch":
            return string(fields["query"])
        default:
            return nil
        }
    }

    /// Longer-form summary for the permission prompt: prefers the raw command
    /// string (Bash), otherwise joins the string-valued input fields as
    /// `key: value` pairs. Falls back to the bare tool name.
    static func permissionSummary(tool: String, input: JSONValue?, maxLength: Int = 120) -> String {
        guard case .object(let fields)? = input else { return tool }

        let detail: String
        if case .string(let command)? = fields["command"] {
            detail = command
        } else {
            detail = fields
                .sorted { $0.key < $1.key }
                .compactMap { key, value -> String? in
                    guard case .string(let string) = value, !string.isEmpty else { return nil }
                    return "\(key): \(string)"
                }
                .joined(separator: ", ")
        }

        return truncate(collapseWhitespace(detail), to: maxLength, fallback: tool)
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value, !string.isEmpty else { return nil }
        return string
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String, to maxLength: Int, fallback: String) -> String {
        guard !text.isEmpty else { return fallback }
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }
}
