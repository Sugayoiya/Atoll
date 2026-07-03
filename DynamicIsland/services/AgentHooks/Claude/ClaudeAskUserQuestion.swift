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

/// Typed view of an AskUserQuestion PreToolUse `tool_input`, gated by what the
/// closed-notch wings can physically fit.
///
/// MVP limits — any input outside these falls back to `nil`, meaning the hook
/// sends no decision and Claude's normal terminal question prompt runs:
/// - exactly ONE question (multi-question payloads → terminal)
/// - `multiSelect == false` (comma-joined multi answers deferred)
/// - 2–4 options, every label non-empty and unique (chips are identified and
///   answered by label)
/// - per-label and combined label length caps so the option chips fit the wing
struct ClaudeAskUserQuestion: Equatable, Sendable {
    let question: String
    /// Short topic tag (e.g. "Color"); optional in the tool schema.
    let header: String?
    let optionLabels: [String]
    /// The full original `tool_input` object fields, kept verbatim so the
    /// allow+updatedInput reply echoes the `questions` subtree unmodified
    /// (re-encoding through this typed model would drop unknown fields).
    let originalInput: [String: JSONValue]

    private static let optionCountRange = 2...4
    private static let maxOptionLabelLength = 16
    private static let maxCombinedLabelLength = 40

    /// Parses and fit-checks a raw `tool_input` tree. Returns nil when the
    /// payload can't be answered from the notch (see MVP limits above).
    static func parse(toolInput: JSONValue?) -> ClaudeAskUserQuestion? {
        guard case .object(let fields)? = toolInput,
              case .array(let questions)? = fields["questions"],
              questions.count == 1,
              case .object(let questionFields) = questions[0],
              case .string(let questionText)? = questionFields["question"],
              !questionText.isEmpty,
              case .array(let options)? = questionFields["options"],
              optionCountRange.contains(options.count) else {
            return nil
        }

        if case .bool(true)? = questionFields["multiSelect"] {
            return nil
        }

        var labels: [String] = []
        for option in options {
            guard case .object(let optionFields) = option,
                  case .string(let label)? = optionFields["label"],
                  !label.isEmpty,
                  label.count <= maxOptionLabelLength else {
                return nil
            }
            labels.append(label)
        }
        guard labels.reduce(0, { $0 + $1.count }) <= maxCombinedLabelLength,
              Set(labels).count == labels.count else {
            return nil
        }

        let header: String?
        if case .string(let headerText)? = questionFields["header"], !headerText.isEmpty {
            header = headerText
        } else {
            header = nil
        }

        return ClaudeAskUserQuestion(
            question: questionText,
            header: header,
            optionLabels: labels,
            originalInput: fields
        )
    }

    /// `updatedInput` that pre-answers the question: the original input object
    /// (questions echoed verbatim) plus the `answers` map required by Claude.
    func updatedInput(choosing label: String) -> JSONValue {
        var fields = originalInput
        fields["answers"] = .object([question: .string(label)])
        return .object(fields)
    }
}
