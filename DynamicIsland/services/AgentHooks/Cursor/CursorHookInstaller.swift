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

/// Installs/uninstalls the Atoll hook script into `~/.cursor/hooks/` and
/// registers it for the hook events Atoll cares about in `~/.cursor/hooks.json`.
/// Cursor hooks.json shape: `{"version": 1, "hooks": {"<event>": [{"command": "..."}]}}`
/// (flat entries — no matcher wrappers like Claude's settings.json).
enum CursorHookInstaller {
    /// Fire-and-forget display events (no timeout override needed).
    private static let displayEvents: [String] = [
        "sessionStart",
        "sessionEnd",
        "beforeSubmitPrompt",
        "preToolUse",
        "postToolUse",
        "preCompact",
        "stop",
        "subagentStop",
    ]

    /// Permission-control events: the script waits (bounded) for a decision
    /// reply, so the hooks.json entry gets an explicit timeout preserving the
    /// chain invariant UI < server (UI+5) < script recv (UI+10) < hook timeout (UI+20).
    private static let permissionEvents: [String] = [
        "beforeShellExecution",
        "beforeMCPExecution",
    ]
    private static var permissionEventTimeoutSeconds: Int { AgentPromptTimeout.hostHookSeconds }

    private static var hookEvents: [String] { displayEvents + permissionEvents }

    static var cursorConfigDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor", isDirectory: true)
    }

    private static var hooksDirectory: URL {
        cursorConfigDirectory.appendingPathComponent("hooks", isDirectory: true)
    }

    private static var hookScriptURL: URL {
        hooksDirectory.appendingPathComponent(CursorHookScript.fileName)
    }

    private static var hooksJSONURL: URL {
        cursorConfigDirectory.appendingPathComponent("hooks.json")
    }

    static var isCursorInstalled: Bool {
        FileManager.default.fileExists(atPath: cursorConfigDirectory.path)
    }

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: hooksJSONURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains {
                ($0["command"] as? String)?.contains(CursorHookScript.fileName) == true
            }
        }
    }

    @discardableResult
    static func installIfNeeded() -> Bool {
        guard isCursorInstalled else {
            Logger.log("Cursor config dir not found at \(cursorConfigDirectory.path); skipping hook install", category: .warning)
            return false
        }

        do {
            try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
            let scriptData = Data(CursorHookScript.contents.utf8)
            let existing = try? Data(contentsOf: hookScriptURL)
            if existing != scriptData {
                try scriptData.write(to: hookScriptURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)
        } catch {
            Logger.log("Failed to install Cursor hook script: \(error.localizedDescription)", category: .error)
            return false
        }

        return updateHooksJSON()
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: hookScriptURL)

        guard let data = try? Data(contentsOf: hooksJSONURL),
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
            let pruned = entries.filter {
                !(($0["command"] as? String ?? "").contains(CursorHookScript.fileName))
            }
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
            try? output.write(to: hooksJSONURL)
        }
    }

    private static func updateHooksJSON() -> Bool {
        let existingData = try? Data(contentsOf: hooksJSONURL)

        var json: [String: Any] = [:]
        if let existingData,
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            json = existing
        }
        if json["version"] == nil {
            json["version"] = 1
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        for event in hookEvents {
            let timeout: Int? = permissionEvents.contains(event) ? permissionEventTimeoutSeconds : nil
            var entries = hooks[event] as? [[String: Any]] ?? []
            var foundExistingHook = false
            for index in entries.indices {
                let cmd = entries[index]["command"] as? String ?? ""
                guard cmd.contains(CursorHookScript.fileName) else { continue }
                foundExistingHook = true
                if cmd != CursorHookScript.hookCommand {
                    entries[index]["command"] = CursorHookScript.hookCommand
                }
                if let timeout {
                    entries[index]["timeout"] = timeout
                } else {
                    entries[index].removeValue(forKey: "timeout")
                }
            }
            if !foundExistingHook {
                var entry: [String: Any] = ["command": CursorHookScript.hookCommand]
                if let timeout {
                    entry["timeout"] = timeout
                }
                entries.append(entry)
            }
            hooks[event] = entries
        }

        json["hooks"] = hooks

        guard let output = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            Logger.log("Failed to serialize Cursor hooks.json", category: .error)
            return false
        }

        guard output != existingData else { return true }

        do {
            try output.write(to: hooksJSONURL)
            Logger.log("Installed Atoll hook into Cursor hooks.json", category: .success)
            return true
        } catch {
            Logger.log("Failed to write Cursor hooks.json: \(error.localizedDescription)", category: .error)
            return false
        }
    }
}
