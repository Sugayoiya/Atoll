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

@main
struct ClaudeInjectedPromptTests {
    static func main() {
        assertPreview(
            """
            <task-notification>
            <task-id>bash_123</task-id>
            <status>completed</status>
            <summary>Background command "sleep 30" completed (exit code 0)</summary>
            </task-notification>
            Read the output file to retrieve the result: /tmp/output
            """,
            equals: "Background task completed · Background command \"sleep 30\" completed (exit code 0)"
        )
        assertPreview(
            "<task-notification><status>failed</status></task-notification>",
            equals: "Background task failed"
        )
        assertPreview(
            "<task-notification><summary>Task completed</summary></task-notification>",
            equals: "Background task notification · Task completed"
        )
        assertPreview(
            "<task-notification><summary>Truncated",
            equals: "Background task notification"
        )
        assertPreview(
            "<bash-input>git status</bash-input>",
            equals: "Running local command · git status"
        )
        assertPreview(
            "<command-name>/review</command-name>",
            equals: "Running command · /review"
        )
        assertPreview(
            "<local-command-stdout>Changes detected</local-command-stdout>",
            equals: "Command output · Changes detected"
        )
        assertPreview(
            "<system-reminder><important>Refresh context</important></system-reminder>",
            equals: "System reminder · Refresh context"
        )
        assertPreview("Keep   my\nprompt", equals: "Keep   my\nprompt")
        assertPreview("<3 keep this human prompt", equals: "<3 keep this human prompt")
        assertPreview("<unknown-message>Readable fallback</unknown-message>", equals: "Readable fallback")
        assertPreview("<unknown-message>", equals: nil)
    }

    private static func assertPreview(_ prompt: String, equals expected: String?) {
        let actual = ClaudeInjectedPrompt.preview(for: prompt)
        precondition(actual == expected, "Expected \(String(describing: expected)); got \(String(describing: actual))")
    }
}
