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

/// Turns Claude Code's machine-injected `UserPromptSubmit` payloads into
/// readable live-activity text while preserving human prompts verbatim.
enum ClaudeInjectedPrompt {
    private enum Kind: CaseIterable {
        case taskNotification
        case commandName
        case bashInput
        case localCommandStdout
        case systemReminder

        var tag: String {
            switch self {
            case .taskNotification: return "task-notification"
            case .commandName: return "command-name"
            case .bashInput: return "bash-input"
            case .localCommandStdout: return "local-command-stdout"
            case .systemReminder: return "system-reminder"
            }
        }

        var label: String {
            switch self {
            case .taskNotification: return "Background task notification"
            case .commandName: return "Running command"
            case .bashInput: return "Running local command"
            case .localCommandStdout: return "Command output"
            case .systemReminder: return "System reminder"
            }
        }
    }

    /// Returns a display preview. Human prompts keep the existing prefix-based
    /// truncation; machine messages are classified from their wrapper tag.
    static func preview(for prompt: String, maxLength: Int = 200) -> String? {
        guard let kind = Kind.allCases.first(where: { hasOpeningTag($0.tag, in: prompt) }) else {
            guard startsWithTagLikeText(prompt) else {
                return truncate(prompt, to: maxLength)
            }
            return truncate(readableText(from: prompt), to: maxLength)
        }

        let preview: String
        switch kind {
        case .taskNotification:
            preview = taskNotificationPreview(prompt)
        default:
            preview = labelled(kind.label, detail: readableText(from: prompt))
        }
        return truncate(preview, to: maxLength)
    }

    private static func taskNotificationPreview(_ prompt: String) -> String {
        let status = tagContent("status", in: prompt)?.lowercased()
        let label: String
        switch status {
        case "completed": label = "Background task completed"
        case "failed": label = "Background task failed"
        case "stopped": label = "Background task stopped"
        default: label = Kind.taskNotification.label
        }
        return labelled(label, detail: tagContent("summary", in: prompt))
    }

    private static func labelled(_ label: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return label }
        return "\(label) · \(detail)"
    }

    private static func hasOpeningTag(_ tag: String, in prompt: String) -> Bool {
        let pattern = "^\\s*<\(NSRegularExpression.escapedPattern(for: tag))\\b[^>]*>"
        return prompt.range(of: pattern, options: .regularExpression) != nil
    }

    private static func startsWithTagLikeText(_ prompt: String) -> Bool {
        prompt.range(
            of: "^\\s*<[A-Za-z][A-Za-z0-9:_-]*(?:\\s[^>]*)?>",
            options: .regularExpression
        ) != nil
    }

    private static func tagContent(_ tag: String, in prompt: String) -> String? {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escapedTag)\\b[^>]*>([\\s\\S]*?)</\(escapedTag)\\s*>"
        guard let range = prompt.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let match = String(prompt[range])
        guard let openingEnd = match.firstIndex(of: ">") else { return nil }
        let content = String(match[match.index(after: openingEnd)..<match.endIndex])
        guard let closingRange = content.range(of: "</", options: .backwards) else { return nil }
        return readableText(from: String(content[..<closingRange.lowerBound]))
    }

    private static func readableText(from prompt: String) -> String? {
        let withoutTags = prompt.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        let collapsed = decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func truncate(_ text: String?, to maxLength: Int) -> String? {
        guard let text, !text.isEmpty, maxLength > 0 else { return nil }
        return String(text.prefix(maxLength))
    }
}
