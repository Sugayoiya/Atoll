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

/// The shell script installed into `~/.claude/hooks/` that forwards
/// Claude Code hook events to Atoll over a Unix domain socket.
/// Embedded as a string so it survives without a bundled resource file.
enum ClaudeHookScript {
    static let fileName = "atoll-claude-hook.sh"
    static let socketPath = "/tmp/atoll-claude.sock"
    static let hookCommand = "\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/\(fileName)\""

    /// Bump when the script contents change in a way that requires re-install.
    /// The installer rewrites the script whenever the on-disk copy differs,
    /// so this marker mainly documents the protocol revision.
    static let version = 3

    static let contents = #"""
#!/bin/bash
# Atoll Hook - forwards Claude Code events to Atoll via Unix socket
# atoll-hook-version: 3 (bidirectional + tool_input forwarding for PreToolUse)

SOCKET_PATH="/tmp/atoll-claude.sock"

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

output = {
    'provider': 'claude',
    'session_id': input_data.get('session_id', ''),
    'cwd': input_data.get('cwd', ''),
    'event': hook_event,
}

tool = input_data.get('tool_name', '')
if tool:
    output['tool'] = tool

# Forward the raw tool input on PreToolUse so Atoll can summarize the call
# (e.g. the bash command string) in its permission prompt.
if hook_event == 'PreToolUse':
    tool_input = input_data.get('tool_input')
    if isinstance(tool_input, dict):
        output['tool_input'] = tool_input

if hook_event == 'UserPromptSubmit':
    prompt = input_data.get('prompt', '')
    if prompt:
        output['user_prompt'] = prompt[:200]

reply = b''
try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(1)
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())
    if hook_event == 'PreToolUse':
        # Only PreToolUse can receive a decision reply. Half-close the write
        # side so Atoll sees EOF, then wait (bounded) for the optional reply.
        sock.shutdown(socket.SHUT_WR)
        sock.settimeout(5)
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            reply += chunk
    # All other events stay fire-and-forget: close immediately so the hook
    # never blocks Claude on Atoll's event processing.
    sock.close()
except Exception:
    # Timeout / socket error: fall through with whatever we have (usually
    # nothing) so Claude's normal permission flow continues.
    pass

# A non-empty reply is a hook decision JSON: print it to stdout for Claude.
# Validate first so a truncated reply (recv timeout mid-write) is discarded
# rather than fed to Claude as malformed JSON.
# Empty/invalid reply = no decision = normal flow. Always exit 0.
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
