# Claude Code Hooks — Decision Control Reference (for bidirectional notch)

> Source: https://code.claude.com/docs/en/hooks (fetched 2026-07-02; full copy was at /tmp/cc-hooks.md — volatile, key facts extracted here).

## PreToolUse decision control (the mechanism we build on)

- PreToolUse fires for tools: `Bash`, `Edit`, `Write`, `Read`, `Glob`, `Grep`, `Agent`,
  `WebFetch`, `WebSearch`, `AskUserQuestion`, `ExitPlanMode`, and MCP tool names.
- Decision is returned inside `hookSpecificOutput` (NOT top-level `decision` — that
  form is deprecated for PreToolUse):

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "My reason",
    "updatedInput": { "field": "new value" },
    "additionalContext": "optional string added to Claude's context"
  }
}
```

- `permissionDecision` values:
  - `allow` — skips the permission prompt
  - `deny` — prevents the tool call (reason shown to Claude)
  - `ask` — prompts the user to confirm (prompt shows source label, e.g. `[User]`)
  - `defer` — exits gracefully so the tool can be resumed later (headless `-p` only)
- Deny/ask permission *rules* (settings) are still evaluated regardless of hook output.
- Multiple hooks precedence: `deny` > `defer` > `ask` > `allow`.
- `updatedInput` **replaces the entire input object** — include unchanged fields.
- Hook mechanics: read JSON from stdin, print decision JSON to **stdout**, `exit 0`.
  Exiting 0 with NO stdout JSON = no decision, normal permission flow applies
  (this is our timeout fallback path).
- Hooks block Claude synchronously until they complete (default timeout applies).
  `"async": true` hooks CANNOT return decisions.

## AskUserQuestion answering

- `tool_input.questions[]` = `{question, header, options[{label}], multiSelect}`.
- `answers` object: `{"<question text>": "<chosen label>"}`; multi-select joins
  labels with commas. Claude never sets it — supplied via `updatedInput`.
- To answer programmatically: return `permissionDecision: "allow"` + `updatedInput`
  that echoes the original `questions` array AND adds the `answers` object.
  **`"allow"` alone is NOT sufficient** for AskUserQuestion/ExitPlanMode.

## defer — headless-only (docs explicit)

- `defer` is honored ONLY in non-interactive `claude -p` mode (v2.1.89+). In
  interactive sessions Claude "logs a warning and ignores the hook result".
- Headless round-trip: defer → process exits `stop_reason: "tool_deferred"` with
  `deferred_tool_use {id,name,input}` → caller collects answer → `--resume` →
  hook returns allow+updatedInput. No timeout; single-tool-call turns only.

## CRITICAL UNKNOWN (PoC Phase 0)

Docs state the allow+updatedInput pre-answer trick in the context of
non-interactive mode ("normally block in non-interactive mode with the -p flag").
They do NOT state whether, in an **interactive** session, allow+updatedInput
pre-answers AskUserQuestion so the terminal never prompts. This must be verified
with a throwaway shell-script hook before building the AskUserQuestion UI.

Permission control (allow/deny/ask) and `updatedInput` for normal tools are
documented without interactive-mode caveats → considered known-good.

## HTTP hooks (alternative transport — rejected in ADR)

- `type: "http"`: POST hook input as JSON body; response body = same decision JSON.
- Non-2xx / connection failure / timeout are non-blocking (execution continues).
- Rejected: we keep the existing Unix socket and make it bidirectional instead
  (no localhost port surface).

## PermissionRequest decision control (secondary)

- Different shape: `hookSpecificOutput.decision = {behavior: "allow"|"deny", updatedInput?, ...}`.
- `updatedInput` for `allow` only; re-evaluated against deny/ask rules.

## Current Atoll implementation touchpoints

- `DynamicIsland/services/ClaudeCode/ClaudeHookScript.swift` — embedded bash hook,
  POSTs to `/tmp/atoll-claude.sock`, currently fire-and-forget (needs `recv()` +
  echo reply to stdout + exit 0).
- `ClaudeHookSocketServer.swift` — AF_UNIX SOCK_STREAM server; needs to write the
  reply JSON on the same client fd before closing.
- `ClaudeHookInstaller.swift` — registers hooks in `~/.claude/settings.json`.
- `ClaudeCodeManager.swift` — @MainActor event → SessionStatus mapping.
- Timeout UX decision: notch waits a bounded window well under hook timeout; on
  no-response, hook exits 0 with no stdout JSON → terminal flow continues.
