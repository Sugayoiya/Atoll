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

/// The shell script installed into `~/.cursor/hooks/` that forwards Cursor
/// hook events to Atoll over the shared agent Unix socket.
/// Embedded as a string so it survives without a bundled resource file.
enum CursorHookScript {
    static let fileName = "atoll-cursor-hook.sh"
    static let socketPath = AgentHookSocketServer.socketPath

    /// Absolute path used as the hooks.json `command`. User-level Cursor hooks
    /// run with cwd `~/.cursor/`, so the command must not rely on a relative path.
    static var hookCommand: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/hooks/\(fileName)")
            .path
    }

    /// Bump when the script contents change in a way that requires re-install.
    /// The installer rewrites the script whenever the on-disk copy differs,
    /// so this marker mainly documents the protocol revision.
    /// v2: beforeShellExecution/beforeMCPExecution wait (bounded) for a flat
    /// `{permission, ...}` decision reply and print it to stdout; every other
    /// event stays fire-and-forget.
    /// v3: permission recv timeout raised 5s → 70s so the user can answer the
    /// prompt from the expanded-notch Agents tab (UI budget 60s).
    static let version = 3

    static let contents = #"""
#!/bin/bash
# Atoll Hook - forwards Cursor events to Atoll via Unix socket
# atoll-cursor-hook-version: 3 (envelope wire format {provider, event, payload})

SOCKET_PATH="/tmp/atoll-agent.sock"

# Exit silently if socket doesn't exist (Atoll not running)
[ -S "$SOCKET_PATH" ] || exit 0

/usr/bin/python3 -c "
import json
import socket
import sys

try:
    input_data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

hook_event = input_data.get('hook_event_name', '')

# Envelope: the raw hook input is forwarded untouched; all normalization
# happens inside Atoll (per-provider Swift adapter).
output = {
    'provider': 'cursor',
    'event': hook_event,
    'payload': input_data,
}

reply = b''
try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(1)
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())
    if hook_event in ('beforeShellExecution', 'beforeMCPExecution'):
        # Only the permission-control hooks can receive a decision reply.
        # Half-close the write side so Atoll sees EOF, then wait (bounded)
        # for the optional reply.
        sock.shutdown(socket.SHUT_WR)
        sock.settimeout(70)
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            reply += chunk
    # All other events stay fire-and-forget: close immediately so the hook
    # never blocks Cursor on Atoll's event processing.
    sock.close()
except Exception:
    # Timeout / socket error: fall through with whatever we have (usually
    # nothing) so Cursor's own permission flow continues.
    pass

# A non-empty reply is a decision JSON: print it to stdout for Cursor.
# Validate first so a truncated reply (recv timeout mid-write) is discarded
# rather than fed to Cursor as malformed JSON.
# Empty/invalid reply = no decision = Cursor's normal flow. Always exit 0.
if reply:
    try:
        json.loads(reply)
        sys.stdout.write(reply.decode())
    except Exception:
        pass
sys.exit(0)
"
"""#
}
