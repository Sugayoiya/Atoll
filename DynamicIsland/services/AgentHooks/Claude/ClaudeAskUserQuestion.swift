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

/// Typed view of an AskUserQuestion PreToolUse `tool_input`, fit-checked
/// against user-configurable limits (questions are answered in the
/// expanded-notch Agents tab, so the old closed-notch wing limits no longer
/// apply).
///
/// Fit-check — any violation falls back to `nil`, meaning the hook sends no
/// decision and Claude's normal terminal question prompt runs:
/// - one or more questions; EVERY question must individually pass the checks
/// - `multiSelect` questions are supported (answers are comma-joined)
/// - option count 2...`claudeCodeQuestionMaxOptionCount` per question
/// - every label non-empty and unique within its question (chips are
///   identified and answered by label)
/// - per-label cap `claudeCodeQuestionMaxOptionLabelLength` and per-question
///   combined cap `claudeCodeQuestionMaxCombinedLabelLength`
struct ClaudeAskUserQuestion: Equatable, Sendable {
    struct Question: Equatable, Sendable {
        let question: String
        /// Short topic tag (e.g. "Color"); optional in the tool schema.
        let header: String?
        let multiSelect: Bool
        let optionLabels: [String]
    }

    let questions: [Question]
    /// The full original `tool_input` object fields, kept verbatim so the
    /// allow+updatedInput reply echoes the `questions` subtree unmodified
    /// (re-encoding through this typed model would drop unknown fields).
    let originalInput: [String: JSONValue]

    /// Hard bounds for the user-configurable limits, applied on read so a
    /// hand-edited Defaults value can't break the fit-check.
    static let optionCountBounds = 2...10

    /// Parses and fit-checks a raw `tool_input` tree. Returns nil when the
    /// payload can't be answered from the notch (see fit-check above).
    static func parse(toolInput: JSONValue?) -> ClaudeAskUserQuestion? {
        let maxOptionCount = min(
            max(Defaults[.claudeCodeQuestionMaxOptionCount], optionCountBounds.lowerBound),
            optionCountBounds.upperBound
        )
        let maxOptionLabelLength = max(Defaults[.claudeCodeQuestionMaxOptionLabelLength], 1)
        let maxCombinedLabelLength = max(Defaults[.claudeCodeQuestionMaxCombinedLabelLength], 1)

        guard case .object(let fields)? = toolInput,
              case .array(let rawQuestions)? = fields["questions"],
              !rawQuestions.isEmpty else {
            return nil
        }

        var parsed: [Question] = []
        for rawQuestion in rawQuestions {
            guard case .object(let questionFields) = rawQuestion,
                  case .string(let questionText)? = questionFields["question"],
                  !questionText.isEmpty,
                  case .array(let options)? = questionFields["options"],
                  (2...maxOptionCount).contains(options.count) else {
                return nil
            }

            let multiSelect: Bool
            if case .bool(let flag)? = questionFields["multiSelect"] {
                multiSelect = flag
            } else {
                multiSelect = false
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

            parsed.append(Question(
                question: questionText,
                header: header,
                multiSelect: multiSelect,
                optionLabels: labels
            ))
        }

        // Answers are keyed by question text; duplicate texts would collide
        // in the answers map, so fall back to terminal.
        guard Set(parsed.map(\.question)).count == parsed.count else {
            return nil
        }

        return ClaudeAskUserQuestion(questions: parsed, originalInput: fields)
    }

    /// `updatedInput` that pre-answers every question: the original input
    /// object (questions echoed verbatim) plus the `answers` map required by
    /// Claude — key = question text, value = chosen label (multiSelect
    /// answers comma-joined). Returns nil unless every question has at least
    /// one selected label.
    func updatedInput(answers: [String: [String]]) -> JSONValue? {
        var answerFields: [String: JSONValue] = [:]
        for question in questions {
            guard let labels = answers[question.question], !labels.isEmpty else {
                return nil
            }
            answerFields[question.question] = .string(labels.joined(separator: ", "))
        }
        var fields = originalInput
        fields["answers"] = .object(answerFields)
        return .object(fields)
    }
}
