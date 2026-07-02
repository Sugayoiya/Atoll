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

/// Installs/uninstalls the Atoll hook script into the Claude Code
/// configuration directory (`~/.claude` or `$CLAUDE_CONFIG_DIR`) and
/// registers it for the hook events Atoll cares about in `settings.json`.
enum ClaudeHookInstaller {
    private static let hookEvents: [String] = [
        "UserPromptSubmit",
        "SessionStart",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "PreCompact",
        "Stop",
        "SubagentStop",
        "SessionEnd",
    ]

    static var claudeConfigDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    private static var hooksDirectory: URL {
        claudeConfigDirectory.appendingPathComponent("hooks", isDirectory: true)
    }

    private static var hookScriptURL: URL {
        hooksDirectory.appendingPathComponent(ClaudeHookScript.fileName)
    }

    private static var settingsURL: URL {
        claudeConfigDirectory.appendingPathComponent("settings.json")
    }

    static var isClaudeCodeInstalled: Bool {
        FileManager.default.fileExists(atPath: claudeConfigDirectory.path)
    }

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains {
                    ($0["command"] as? String)?.contains(ClaudeHookScript.fileName) == true
                }
            }
        }
    }

    @discardableResult
    static func installIfNeeded() -> Bool {
        guard isClaudeCodeInstalled else {
            Logger.log("Claude Code config dir not found at \(claudeConfigDirectory.path); skipping hook install", category: .warning)
            return false
        }

        do {
            try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
            let scriptData = Data(ClaudeHookScript.contents.utf8)
            let existing = try? Data(contentsOf: hookScriptURL)
            if existing != scriptData {
                try scriptData.write(to: hookScriptURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)
        } catch {
            Logger.log("Failed to install Claude hook script: \(error.localizedDescription)", category: .error)
            return false
        }

        return updateSettings()
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: hookScriptURL)

        guard let data = try? Data(contentsOf: settingsURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return
        }

        var updatedHooks: [String: Any] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                updatedHooks[event] = value
                continue
            }
            let pruned = pruneManagedHooks(from: entries)
            if !pruned.isEmpty {
                updatedHooks[event] = pruned
            }
        }

        if updatedHooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = updatedHooks
        }

        if let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? output.write(to: settingsURL)
        }
    }

    private static func updateSettings() -> Bool {
        let existingData = try? Data(contentsOf: settingsURL)

        var json: [String: Any] = [:]
        if let existingData,
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            json = existing
        }

        let hookEntry: [[String: Any]] = [["type": "command", "command": ClaudeHookScript.hookCommand]]
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        for event in hookEvents {
            let defaultConfig: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]

            if var existingEvent = hooks[event] as? [[String: Any]] {
                var foundExistingHook = false
                for index in existingEvent.indices {
                    guard var entryHooks = existingEvent[index]["hooks"] as? [[String: Any]] else { continue }
                    var didUpdateEntry = false
                    for hookIndex in entryHooks.indices {
                        let cmd = entryHooks[hookIndex]["command"] as? String ?? ""
                        guard cmd.contains(ClaudeHookScript.fileName) else { continue }
                        foundExistingHook = true
                        didUpdateEntry = true
                        if cmd != ClaudeHookScript.hookCommand {
                            entryHooks[hookIndex]["command"] = ClaudeHookScript.hookCommand
                        }
                    }
                    if didUpdateEntry {
                        existingEvent[index]["hooks"] = entryHooks
                    }
                }
                if !foundExistingHook {
                    existingEvent.append(contentsOf: defaultConfig)
                }
                hooks[event] = existingEvent
            } else {
                hooks[event] = defaultConfig
            }
        }

        json["hooks"] = hooks

        guard let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            Logger.log("Failed to serialize Claude settings.json", category: .error)
            return false
        }

        guard output != existingData else { return true }

        do {
            try output.write(to: settingsURL)
            Logger.log("Installed Atoll hook into Claude Code settings.json", category: .success)
            return true
        } catch {
            Logger.log("Failed to write Claude settings.json: \(error.localizedDescription)", category: .error)
            return false
        }
    }

    private static func pruneManagedHooks(from entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return entry }
            let filtered = entryHooks.filter {
                !(($0["command"] as? String ?? "").contains(ClaudeHookScript.fileName))
            }
            guard !filtered.isEmpty else { return nil }
            var updated = entry
            updated["hooks"] = filtered
            return updated
        }
    }
}
