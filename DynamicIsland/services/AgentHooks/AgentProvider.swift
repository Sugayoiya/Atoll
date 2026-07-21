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

/// Icon shown for a provider in the live activity / Agents tab: either an
/// SF Symbol or a bundled template asset (official brand logo).
enum AgentProviderIcon {
    case system(name: String)
    case asset(name: String)

    /// Asset catalog name when this is a bundled asset icon, nil for SF Symbols.
    var assetName: String? {
        if case .asset(let name) = self { return name }
        return nil
    }

    /// Renders the icon at roughly the visual size of an SF Symbol with the
    /// given point size. Asset icons are template-rendered so `foregroundStyle`
    /// tinting applies to both cases.
    @ViewBuilder
    func view(size: CGFloat, weight: Font.Weight = .bold) -> some View {
        switch self {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
        case .asset(let name):
            Image(name)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}

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
    /// Icon shown on the live activity's left wing (SF Symbol or brand asset).
    var icon: AgentProviderIcon { get }

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
