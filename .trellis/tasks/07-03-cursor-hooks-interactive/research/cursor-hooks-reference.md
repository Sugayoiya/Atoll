# Cursor Hooks Reference (distilled from https://cursor.com/cn/docs/hooks)

> Research artifact for task 07-03-cursor-hooks-interactive.
> Source: official Cursor hooks docs (fetched 2026-07-03, uploaded copy).

## Execution model

- Hooks are defined in `hooks.json`; sources merge with priority
  Enterprise → Team → Project (`<project>/.cursor/hooks.json`) → User (`~/.cursor/hooks.json`).
- **User hooks run with cwd `~/.cursor/`**; project hooks run from project root.
- Command hooks: spawned process, **JSON on stdin → JSON on stdout**, synchronous.
  - exit 0 = success (stdout JSON used)
  - exit 2 = block operation (same as `permission: "deny"`)
  - other exit codes = hook failed, operation continues (fail-open by default;
    `failClosed: true` flips this)
- Cursor watches `hooks.json` and hot-reloads on save.
- Per-script options: `command`, `type` (command|prompt), `timeout` (seconds,
  platform default), `loop_limit` (stop/subagentStop, default 5), `failClosed`,
  `matcher`.
- Env vars for hook scripts: `CURSOR_PROJECT_DIR`, `CURSOR_VERSION`,
  `CURSOR_USER_EMAIL`, `CURSOR_TRANSCRIPT_PATH`, `CURSOR_CODE_REMOTE`,
  `CLAUDE_PROJECT_DIR` (compat alias).
- Cursor can also load Claude Code hooks (third-party hooks compat), but native
  hooks.json is the first-class path.

## Common input fields (all agent hooks)

```json
{
  "conversation_id": "stable per conversation",
  "generation_id": "changes per user message",
  "model": "legacy slug", "model_id": "structured id",
  "model_params": [{"id": "thinking", "value": "true"}],
  "hook_event_name": "...",
  "cursor_version": "1.7.2",
  "workspace_roots": ["/abs/path"],
  "user_email": "string|null",
  "transcript_path": "string|null"
}
```

Note: `conversation_id` ≈ Claude's `session_id`. `workspace_roots[0]` ≈ cwd for
session-level display purposes (per-tool hooks also carry `cwd`).

## Event mapping vs Claude Code integration

| Claude event (installed today) | Cursor equivalent | Notes |
|---|---|---|
| SessionStart | `sessionStart` | fire-and-forget; input: session_id, is_background_agent, composer_mode |
| SessionEnd | `sessionEnd` | fire-and-forget; reason: completed/aborted/error/window_close/user_close |
| UserPromptSubmit | `beforeSubmitPrompt` | input: prompt, attachments; output `{continue: bool}` can BLOCK submit |
| PreToolUse | `preToolUse` | generic, all tools; output permission allow/deny (+updated_input); "ask" accepted but NOT enforced |
| PostToolUse | `postToolUse` | input has tool_output JSON string + duration |
| PermissionRequest | `beforeShellExecution` / `beforeMCPExecution` | THE permission-control hooks; output `permission: allow|deny|ask` + user_message/agent_message |
| PreCompact | `preCompact` | observe-only; rich context stats input |
| Stop | `stop` | input status completed/aborted/error + loop_count; output followup_message |
| SubagentStop | `subagentStop` | rich input (type/status/summary/duration) |
| — | `postToolUseFailure` | new: error tracking (error_message, failure_type, is_interrupt) |
| — | `subagentStart` | can deny subagent creation |
| — | `afterShellExecution` / `afterMCPExecution` | audit with output/duration |
| — | `afterFileEdit` | file_path + edits array |
| — | `beforeReadFile` | access control, can deny |
| — | `afterAgentResponse` / `afterAgentThought` | observe agent text/thinking |
| — | `workspaceOpen` | app lifecycle, no conversation context |
| — | Tab hooks (`beforeTabFileRead`, `afterTabFileEdit`) | inline completions, separate policy |

## Permission control semantics (bidirectional part)

- `beforeShellExecution` input: `{command, cwd, sandbox}`;
  output: `{permission: "allow"|"deny"|"ask", user_message, agent_message}`.
- `beforeMCPExecution` input: `{tool_name, tool_input}` + `url` or `command`.
- `preToolUse` output: `{permission: "allow"|"deny", user_message, agent_message,
  updated_input}` — "ask" tolerated by schema, currently NOT enforced.
- Fail-open default; `failClosed: true` for security-critical hooks.
- **No AskUserQuestion equivalent**: Cursor's AskQuestion tool has no
  hook-based answering path (nothing like Claude's updatedInput answers trick).
  The interactive question-answering feature does NOT port.
- `stop.followup_message` CAN inject the next user message (loop_limit default 5)
  — this is a potential "continue from notch" feature, distinct from Claude.

## Key differences from Claude Code hooks (protocol level)

1. Registration: single JSON config `hooks.json` mapping event → `[{command}]`;
   no matcher-wrapper nesting like Claude's settings.json (`matcher` is a flat
   optional string field per entry).
2. User-level hooks cwd is `~/.cursor/`, so command should use an absolute path
   (e.g. `~/.cursor/hooks/atoll-cursor-hook.sh`) to be robust.
3. stdout decision schema is flat (`permission` top-level), NOT nested under
   `hookSpecificOutput` like Claude's PreToolUse.
4. Exit code 2 = deny (Claude-compatible behavior).
5. `conversation_id` not `session_id`; per-event payloads differ (see doc).
6. Timeout is per-hook-entry configurable in hooks.json (seconds); we control
   our own budget rather than relying on Claude's 60s default.

## Reusable Atoll infra (from 07-02-claude-interactive)

- `ClaudeHookSocketServer.swift` — generic AF_UNIX SOCK_STREAM server with
  bidirectional reply support (handler returns Data? to write back).
- Timeout chain invariant pattern: UI budget < server semaphore < script recv
  < host timeout. For Cursor we can set hooks.json `timeout` explicitly.
- Spec: `.trellis/spec/backend/claude-hook-socket-protocol.md`.
