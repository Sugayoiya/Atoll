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

    static let contents = #"""
#!/bin/bash
# Atoll Hook - forwards Claude Code events to Atoll via Unix socket

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

if hook_event == 'UserPromptSubmit':
    prompt = input_data.get('prompt', '')
    if prompt:
        output['user_prompt'] = prompt[:200]

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(1)
    sock.connect('$SOCKET_PATH')
    sock.sendall(json.dumps(output).encode())
    sock.close()
except Exception:
    pass
"
"""#
}
