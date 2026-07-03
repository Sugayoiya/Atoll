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
import SwiftUI

/// One agent CLI/IDE integration (Claude Code, Cursor, ...). A provider
/// adapter owns everything provider-specific: hook installation, mapping raw
/// envelope payloads to normalized `AgentEvent`s, deriving interactive prompt
/// requests, and encoding decisions back into the provider's reply schema.
///
/// Adding a new provider = implementing this protocol + registering the
/// instance in `AgentSessionManager.providers`.
@MainActor
protocol AgentProvider {
    /// Stable id matching the envelope's `provider` field, e.g. "claude".
    var id: String { get }
    /// Human-readable name for UI, e.g. "Claude Code".
    var displayName: String { get }
    /// Accent color used by the live activity while the session is busy.
    var accentColor: Color { get }
    /// SF Symbol shown on the live activity's left wing.
    var iconName: String { get }

    /// Whether the user has this provider's live activity enabled.
    var isEnabled: Bool { get }

    /// Maps a raw envelope to a normalized event. Return nil to ignore the event.
    func mapEvent(_ envelope: AgentHookEnvelope) -> AgentEvent?

    /// Derives an interactive prompt (permission Allow/Deny or question) for a
    /// raw envelope, if this event should suspend for a notch decision.
    /// Returning nil means fire-and-forget (no reply to the hook script).
    /// The returned request carries the provider-specific reply encoder.
    func promptRequest(for envelope: AgentHookEnvelope) -> AgentPromptRequest?

    /// Installs the hook script + registration idempotently (background thread).
    nonisolated func installIfNeeded()
    /// Removes only Atoll-managed hook entries (background thread).
    nonisolated func uninstall()
    nonisolated var isInstalled: Bool { get }
}
