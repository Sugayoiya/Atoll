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

/// One user-created auto-allow rule for agent shell permission prompts.
/// Matching is word-prefix based (see `AgentCommandMatcher`); rules apply to
/// all providers (Claude Code and Cursor) — per-provider scoping can be added
/// later without a storage migration thanks to the optional `provider` field.
struct AgentAutoAllowRule: Codable, Defaults.Serializable, Identifiable, Hashable {
    let id: UUID
    /// Normalized rule text, e.g. "git push" — each word must equal the
    /// corresponding leading word of the command for the rule to match.
    let ruleText: String
    /// Provider id ("claude"/"cursor") this rule is scoped to; nil = all providers.
    let provider: String?
    let createdAt: Date

    init(ruleText: String, provider: String? = nil, createdAt: Date = Date()) {
        self.id = UUID()
        self.ruleText = ruleText
        self.provider = provider
        self.createdAt = createdAt
    }
}

/// Word-prefix matching semantics shared by Atoll's own auto-allow rules and
/// the imported Cursor allowlist entries (mirrors Cursor's allowlist behavior:
/// entry "git push" matches "git push origin main" but not "git pushx").
///
/// Compound commands are split on top-level connectors (`&&`, `||`, `;`, `|`,
/// `&`, newline) and EVERY segment must match some rule for the whole command
/// to be auto-allowed — otherwise `git pull && rm -rf ~` would ride on a `git`
/// rule. Commands containing command substitution (`$(`, backticks) or process
/// substitution (`<(`, `>(`) are never auto-allowed.
///
/// Covered cases (see `commandSegments` / `command(_:isFullyAllowedBy:)`):
/// - `git pull && rm -rf ~` + rule `git`            → NO match
/// - `git pull && git push` + rule `git`            → match
/// - `echo "a && b"` + rule `echo`                  → match (quoted, not split)
/// - `git pull; echo done` + rules `git`, `echo`    → match
/// - `echo $(whoami)`                               → never auto-allowed
/// - `ls | grep foo` + rules `ls`, `grep`           → match
enum AgentCommandMatcher {
    /// Multi-subcommand tools: "always allow" takes the first TWO words for
    /// these (e.g. `git push` instead of the overly broad `git`). Extend this
    /// set when another tool with meaningful subcommands shows up in prompts.
    static let multiSubcommandTools: Set<String> = [
        "git", "npm", "pnpm", "yarn", "npx", "python3", "python", "pip", "pip3",
        "cargo", "brew", "docker", "kubectl", "gh", "make", "swift", "xcrun",
        "bundle", "rake",
    ]

    /// Trims, collapses runs of whitespace, and splits into words.
    static func tokenize(_ command: String) -> [String] {
        command
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// True when every word of `rule` equals the corresponding leading word
    /// of `command` (word-by-word prefix, never substring matching).
    static func rule(_ rule: String, matches command: String) -> Bool {
        let ruleTokens = tokenize(rule)
        guard !ruleTokens.isEmpty else { return false }
        let commandTokens = tokenize(command)
        guard commandTokens.count >= ruleTokens.count else { return false }
        return zip(ruleTokens, commandTokens).allSatisfy { $0 == $1 }
    }

    /// Splits `command` into top-level segments on `&&`, `||`, `;`, `|`, `&`
    /// and newlines, ignoring connectors inside single/double quotes (with
    /// minimal backslash-escape handling). Returns nil when the command must
    /// never be auto-allowed:
    /// - command substitution `$(` or backticks (also inside double quotes,
    ///   where the shell still expands them),
    /// - process substitution `<(` / `>(` outside quotes,
    /// - unterminated quotes, or an empty segment (e.g. a trailing `&&`).
    /// Plain redirections (`>`, `>>`, `<`) are NOT rejected and do not split.
    static func commandSegments(_ command: String) -> [String]? {
        var segments: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inSingleQuote {
                if c == "'" { inSingleQuote = false }
                current.append(c)
                i += 1
                continue
            }
            if c == "\\" {
                // Backslash escapes the next character outside single quotes;
                // keep both so an escaped connector (\;) never splits.
                current.append(c)
                if i + 1 < chars.count { current.append(chars[i + 1]) }
                i += 2
                continue
            }
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            // Command substitution expands even inside double quotes.
            if c == "`" || (c == "$" && next == "(") { return nil }
            if inDoubleQuote {
                if c == "\"" { inDoubleQuote = false }
                current.append(c)
                i += 1
                continue
            }
            // Process substitution outside quotes.
            if (c == "<" || c == ">") && next == "(" { return nil }
            switch c {
            case "'":
                inSingleQuote = true
                current.append(c)
                i += 1
            case "\"":
                inDoubleQuote = true
                current.append(c)
                i += 1
            case "&", "|", ";", "\n":
                segments.append(current)
                current = ""
                // Consume both characters of `&&` / `||` as one connector.
                i += ((c == "&" || c == "|") && next == c) ? 2 : 1
            default:
                current.append(c)
                i += 1
            }
        }
        guard !inSingleQuote, !inDoubleQuote else { return nil }
        segments.append(current)
        let trimmed = segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.isEmpty, trimmed.allSatisfy({ !$0.isEmpty }) else { return nil }
        return trimmed
    }

    /// The shared auto-allow verdict for a full (possibly compound) command
    /// against a rule set: the command splits into safe segments and EVERY
    /// segment word-prefix-matches at least one rule. Both Atoll's own rules
    /// and the Cursor allowlist check MUST go through this single entry point
    /// so the splitting semantics can never diverge.
    static func command<S: Sequence>(_ command: String, isFullyAllowedBy rules: S) -> Bool where S.Element == String {
        guard let segments = commandSegments(command) else { return false }
        let ruleList = Array(rules)
        guard !ruleList.isEmpty else { return false }
        return segments.allSatisfy { segment in
            ruleList.contains { rule($0, matches: segment) }
        }
    }

    /// Whether the "Always Allow" button may offer a rule for this command:
    /// only single-segment commands without conservative-reject constructs
    /// qualify (a smart prefix is meaningless for compound commands).
    static func canSuggestRule(for command: String) -> Bool {
        guard let segments = commandSegments(command) else { return false }
        return segments.count == 1
    }

    /// "Smart prefix" for a new always-allow rule: the command's first word,
    /// or the first two words when the first word is a multi-subcommand tool.
    /// Callers must gate on `canSuggestRule(for:)` first.
    static func smartPrefix(for command: String) -> String? {
        let tokens = tokenize(command)
        guard let first = tokens.first else { return nil }
        if multiSubcommandTools.contains(first), tokens.count >= 2 {
            return "\(first) \(tokens[1])"
        }
        return first
    }
}
