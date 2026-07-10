# Research: Claude Code machine-injected user prompts (`<task-notification>` 等)

- **Query**: What machine-injected user prompts does Claude Code CLI produce, and what is their exact structure?
- **Scope**: external (Anthropic docs, claude-code GitHub issues, community tooling)
- **Date**: 2026-07-10

## Findings

### 1. `<task-notification>` — background task completion

When a background task (Bash with `run_in_background: true`, or a backgrounded subagent/Task) reaches a terminal state, Claude Code injects a **synthetic user-role message** whose `message.content` is a plain **string** (not `tool_result` blocks) of this exact form:

```
<task-notification>
<task-id>bash_AAA</task-id>
<tool-use-id>toolu_AAA</tool-use-id>
<status>completed</status>
<summary>Background command "Long task" completed (exit code 0)</summary>
</task-notification>
Read the output file to retrieve the result: [path]
```

Field semantics (confirmed by GitHub issue captures and the ClaudeCode Elixir SDK's `TaskNotification` type):

| Field | Meaning |
|---|---|
| `task-id` | Background task identifier (e.g. `bash_AAA`, `bd3u30md0`, or subagent id) |
| `tool-use-id` | The `tool_use` block ID that launched the task (`toolu_…`); optional |
| `status` | `completed` / `failed` / `stopped` |
| `summary` | **Human-readable one-line summary**, e.g. `Background command "Check disk usage of cleanup candidates" completed (exit code 0)`. For subagents it can be a result summary like `Analysis complete: found 3 issues` |
| trailing text | Often followed by a plain-text line: `Read the output file to retrieve the result: <path>` (output_file) |

**Key takeaway for display**: `<summary>` is the human-readable payload and includes the task's description and exit status — good candidate for a status bar. `<status>` gives success/failure.

In stream-json / SDK output the same event appears as `{"type":"system","subtype":"task_notification","task_id","tool_use_id","status","output_file","summary","usage":{total_tokens,tool_uses,duration_ms},"uuid","session_id"}` (see ClaudeCode hexdocs). But **in the conversation/JSONL and in `UserPromptSubmit` hooks it arrives as the XML string above in a user-role turn**.

Sources:
- https://github.com/anthropics/claude-code/issues/34637 (exact XML capture)
- https://github.com/anthropics/claude-code/issues/39027 (internals: notification queue `mode === "task-notification"`, materialized as synthetic `type:"user"` message)
- https://github.com/anthropics/claude-code/issues/37602 (multiple simultaneous notifications)
- https://github.com/simonw/claude-code-transcripts/issues/99 (JSONL shape; detection advice)
- https://claude-code.hexdocs.pm/ClaudeCode.Message.SystemMessage.TaskNotification.html (field schema)

### 2. Other machine-injected user-role messages (recognizable markers)

From transcript-parsing tools (claude-sessions ARCHITECTURE.md, agenttree "Clean Chat Rendering", vibe-replay source analysis):

| Marker / flag | Meaning |
|---|---|
| `isMeta: true` (top-level JSONL flag) | System-injected invisible messages: skill injections (`Base directory for this skill: …`), local-command caveats, slash command outputs |
| `isCompactSummary: true` | Compaction summary; content starts with `This session is being continued from a previous conversation…` |
| `<command-name>…` / `<command-message>…` text prefix | Slash-command echo (user typed `/foo`, expanded) |
| `<local-command-stdout>` / `<bash-input>` / `<bash-stdout>` / `<bash-stderr>` | User `!bash` command input/output injections |
| `<system-reminder>…</system-reminder>` | Hook `additionalContext` output and harness reminders (EnterPlanMode, TaskCreate, hook success messages). Wrapped as system reminders, normally not shown as chat messages |
| `<task-notification>` | Background task completion (above) |
| `<custom-title>` | `/rename` command artifact |
| Interruption messages (`[Request interrupted by user]`) | Esc/interrupt artifacts |

For a socket consumer that only sees the prompt string, prefix detection on `<task-notification>`, `<command-name>`, `<bash-input>`, `<local-command-stdout>`, `<system-reminder>` covers the known machine-injected variants.

### 3. UserPromptSubmit hook schema — no machine/human flag

Per official hooks docs (https://code.claude.com/docs/en/hooks) and a captured-payload reference (https://docs.rhi.zone/claude-code-hooks), the UserPromptSubmit stdin JSON contains only:

```
session_id, transcript_path, cwd, permission_mode, hook_event_name ("UserPromptSubmit"), prompt
```

- `prompt` is the raw text, **including injected `<task-notification>` XML** — the hook explicitly fires for these harness callbacks too (rhi.zone confirms from real payloads).
- **There is no field flagging machine-injected vs human prompts.** The only distinguishing signal is the content of `prompt` itself (XML prefix). The `isMeta`/`isCompactSummary` flags exist only in the transcript JSONL (`transcript_path`), not in the hook payload.

### 4. How other tools classify these

- **claude-code-transcripts (simonw)** issue #99: detect `type:"user"` entries whose `message.content` is a *string* starting with `<task-notification>`; parse task-id/tool-use-id/status/summary and render as a background lifecycle event, not a user prompt; fall back to "unknown background notification" if XML parse fails.
- **claude-sessions (gapmiss)**: captures `<task-notification>` from `queue-operation` and user records; skips `isMeta` non-user records, `file-history-snapshot`, sidechains.
- **vibe-replay**: classifies `isMeta` messages (skill injection → labeled context-injection scene; slash-command output → labeled; local-command caveats → filtered out); uses `isCompactSummary` flag rather than string prefix.
- **agenttree**: filters user turns where `isCompactSummary`, `isMeta`, or content starts with `<command-name>`; filters assistant turns with `isVisibleInTranscriptOnly`.

Common pattern: **string-prefix sniffing on the prompt text** for hook-level data; **top-level JSONL flags** when the transcript file is available.

## Caveats / Not Found

- No official Anthropic documentation of the `<task-notification>` XML format itself was found; the format is reconstructed from GitHub issue captures and third-party SDK docs (stable across observed versions, but unofficial and may evolve).
- The observed Atoll example truncates before `<status>`/`<summary>`; full messages should contain them, but a defensive parser should tolerate missing tags.
- Whether subagent (Task tool) completions use the same `<summary>` wording as Bash background commands varies; treat `<summary>` as opaque display text.
