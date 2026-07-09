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
import SQLite3

/// Read-only aggregator of the user's existing Cursor terminal allowlists,
/// used to auto-allow matching `beforeShellExecution` prompts without showing
/// the notch. Sources (merged, deduped):
///
/// 1. `~/.cursor/permissions.json` — `terminalAllowlist` (global)
/// 2. `<workspace>/.cursor/permissions.json` — `terminalAllowlist` (per repo)
/// 3. Cursor's `state.vscdb` SQLite — `$.composerState.yoloCommandAllowlist`
///
/// All reads are strictly read-only and fail silently (empty result): a
/// missing file, locked database, or changed JSON shape must never crash or
/// spam the log. Parsed results are cached per source keyed by file mtime.
/// Only allow pre-answering is done here — Cursor's own denylist/flow still
/// applies whenever Atoll sends no reply.
final class CursorAllowlistReader {
    static let shared = CursorAllowlistReader()

    private struct CacheEntry {
        let modificationDate: Date
        let entries: [String]
    }

    /// Cache keyed by absolute file path; invalidated when the mtime changes.
    private var cache: [String: CacheEntry] = [:]
    private let queue = DispatchQueue(label: "com.atoll.cursor-allowlist-reader")
    /// One-shot debug-log flags so degraded sources don't spam the log.
    private var loggedFailures: Set<String> = []

    private var globalPermissionsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".cursor/permissions.json")
    }

    private var stateDatabasePath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Merged, deduped allowlist entries from all sources. `workspaceRoot`
    /// (from the hook payload's `workspace_roots[0]`) locates the per-repo
    /// permissions.json; pass nil to skip that source.
    func allowlistEntries(workspaceRoot: String?) -> [String] {
        queue.sync {
            var merged: [String] = []
            merged.append(contentsOf: cachedEntries(path: globalPermissionsPath, load: loadPermissionsJSON))
            if let workspaceRoot, !workspaceRoot.isEmpty {
                let workspacePath = (workspaceRoot as NSString)
                    .appendingPathComponent(".cursor/permissions.json")
                merged.append(contentsOf: cachedEntries(path: workspacePath, load: loadPermissionsJSON))
            }
            merged.append(contentsOf: cachedEntries(path: stateDatabasePath, load: loadYoloAllowlist))
            var seen = Set<String>()
            return merged.filter { seen.insert($0).inserted }
        }
    }

    // MARK: - mtime cache

    private func cachedEntries(path: String, load: (String) -> [String]) -> [String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            cache[path] = nil
            return []
        }
        if let entry = cache[path], entry.modificationDate == modificationDate {
            return entry.entries
        }
        let entries = load(path)
        cache[path] = CacheEntry(modificationDate: modificationDate, entries: entries)
        return entries
    }

    // MARK: - Sources

    /// `permissions.json` → `terminalAllowlist` string array.
    private func loadPermissionsJSON(path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let allowlist = object["terminalAllowlist"] as? [String] else {
            logFailureOnce("Cursor permissions.json unreadable or missing terminalAllowlist: \(path)")
            return []
        }
        return allowlist
    }

    /// `state.vscdb` → `$.composerState.yoloCommandAllowlist` string array.
    /// Opens the (Cursor-owned, WAL-mode) SQLite database strictly read-only;
    /// any failure degrades silently to an empty list.
    private func loadYoloAllowlist(path: String) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            logFailureOnce("Could not open Cursor state.vscdb read-only")
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT json_extract(value, '$.composerState.yoloCommandAllowlist') FROM ItemTable
        WHERE key = 'src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser';
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            logFailureOnce("Could not prepare Cursor state.vscdb allowlist query")
            return []
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0) else {
            return []
        }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8),
              let allowlist = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            logFailureOnce("Cursor yoloCommandAllowlist has unexpected shape")
            return []
        }
        return allowlist
    }

    private func logFailureOnce(_ message: String) {
        guard loggedFailures.insert(message).inserted else { return }
        Logger.log(message, category: .debug)
    }
}
