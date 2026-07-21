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

import AppKit
import SwiftUI

/// Shared dimmed elapsed counter ("Ns" under a minute, "m:ss" after) showing
/// how long the current agent status has
/// been running. Used by both the closed-notch `AgentLiveActivity` and the
/// expanded-notch `NotchAgentsView` rows so both apply identical visibility
/// rules:
///
/// - Only while the session is busy (thinking / tool / compacting).
/// - Never while a prompt (permission / question) is pending — an
///   AskUserQuestion keeps the session "busy" via PreToolUse, and a counter
///   ticking next to a question is just noise.
/// - Only after the current status has persisted for `revealDelay`. This kills
///   the misleading clipped `"0"` / `"0s"` flash between PreToolUse (busy) and
///   the PermissionRequest that follows within a second or two.
struct AgentElapsedIndicator: View {
    let session: AgentSessionManager.Session
    let hasPendingPrompt: Bool

    /// How long a status must persist before the counter appears.
    static let revealDelay: TimeInterval = 2

    /// Width reserved while the reveal delay runs — matches the `"00:00"`
    /// sample used by `AgentLiveActivity.fixedRightWingWidth`. Must never be
    /// backed by a digit `Text` (even `.hidden()`): NotchShape clipping can
    /// still leak a lone leading `"0"` at the wing edge.
    static let reservedWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil(NSAttributedString(string: "00:00", attributes: attributes).size().width)
    }()

    /// Whether the counter could appear for this session (ignoring the
    /// time-based reveal delay). Layout code that reserves width should use
    /// this so the layout doesn't resize when the delay elapses.
    ///
    /// `hasPendingPrompt` is the hard gate: Cursor keeps `runningTool`
    /// across beforeShellExecution until the manager clears busy, and a
    /// clipped `"0s"` / `"0:00"` at the wing edge is worse than a layout jump.
    static func couldShow(session: AgentSessionManager.Session, hasPendingPrompt: Bool) -> Bool {
        !hasPendingPrompt && session.status.isBusy
    }

    static func isVisible(session: AgentSessionManager.Session, hasPendingPrompt: Bool, now: Date) -> Bool {
        couldShow(session: session, hasPendingPrompt: hasPendingPrompt)
            && now.timeIntervalSince(session.statusChangedAt) >= revealDelay
    }

    /// Under a minute renders as "Ns" (e.g. "4s") — a leading "0:" or "0s"
    /// reads as a bare "0" when NotchShape clips the wing edge. From one
    /// minute on, "m:ss" with minutes capped at 99 (never "0:ss").
    static func elapsedText(since start: Date, now: Date) -> String {
        // Floor at 1 so a race that paints before revealDelay cannot emit "0s".
        let seconds = max(1, Int(now.timeIntervalSince(start)))
        guard seconds >= 60 else { return "\(seconds)s" }
        let minutes = min(seconds / 60, 99)
        return String(format: "%d:%02d", minutes, seconds % 60)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // Clear-frame spacer (no digit glyphs) so intrinsic width matches
            // `fixedRightWingWidth`'s reservation while the reveal delay runs —
            // otherwise the trailing status text jumps left when the counter
            // finally appears.
            let visible = Self.isVisible(
                session: session,
                hasPendingPrompt: hasPendingPrompt,
                now: context.date
            )
            ZStack(alignment: .trailing) {
                Color.clear
                    .frame(width: Self.reservedWidth, height: 1)
                    .accessibilityHidden(true)
                if visible {
                    Text(Self.elapsedText(since: session.statusChangedAt, now: context.date))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
        }
    }
}
