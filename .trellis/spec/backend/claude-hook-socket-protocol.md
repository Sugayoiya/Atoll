# Claude Code Hook ↔ Atoll Socket Protocol (Code-Spec)

> Executable contract for the bidirectional Unix-socket channel between the
> installed Claude Code hook script and Atoll's in-app socket server.
> Established in task 07-02-claude-interactive.

## 1. Scope / Trigger

Cross-layer request/response contract: bash/python hook script (installed to
`~/.claude/hooks/`) ↔ `ClaudeHookSocketServer` ↔ `ClaudeCodeManager` ↔ notch UI.
Any change to event fields, reply schema, or timeout values MUST update this doc
and bump the script version marker.

## 2. Signatures

- Socket: `AF_UNIX` `SOCK_STREAM` at `/tmp/atoll-claude.sock`, `chmod 0600`.
- Server handler: `typealias EventHandler = (ClaudeHookEvent) async -> Data?`
  — return `nil` = no decision (fire-and-forget parity); return encoded
  `ClaudeHookResponse` bytes = decision written back on the SAME client fd.
- Script (embedded in `ClaudeHookScript.swift`, version marker `atoll-hook-version: N`):
  - All events: connect (1s timeout) → send event JSON.
  - `PreToolUse` only: `shutdown(SHUT_WR)` (half-close signals EOF to server) →
    `recv()` with 5s timeout → if reply parses as JSON, print to stdout, exit 0;
    else exit 0 with NO stdout output.
  - Non-PreToolUse events: `close()` immediately after send (never wait).

## 3. Contracts

Event JSON (script → Atoll), fields: `provider`, `session_id`, `cwd`, `event`,
`tool`, `user_prompt`, and for PreToolUse `tool_input` (raw tool input dict,
serialized via `json.dumps`, decoded into `JSONValue?`).

Reply JSON (Atoll → script → Claude stdout) — `ClaudeHookResponse`:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow | deny | ask | defer",
    "permissionDecisionReason": "optional string",
    "updatedInput": { "...": "optional, replaces ENTIRE tool input" },
    "additionalContext": "optional string"
  }
}
```

- PreToolUse decisions go inside `hookSpecificOutput` — the top-level
  `decision`/`reason` form is DEPRECATED for this event.
- `updatedInput` replaces the whole input object; include unchanged fields.
- AskUserQuestion pre-answering needs `allow` + `updatedInput` echoing the full
  `questions` array plus an `answers` map — `allow` alone is insufficient.
  `defer` is headless-only (`claude -p`); interactive sessions ignore it.
  **PoC-verified 2026-07-02**: this pre-answer trick WORKS in interactive mode
  (terminal never prompts; shows "User answered Claude's questions").
- AskUserQuestion echo rule: keep the ORIGINAL `questions` `JSONValue` subtree
  from the received `tool_input` and embed it verbatim in `updatedInput` — never
  round-trip through a typed model (unknown fields would be dropped).
- Notch answer fallback matrix (all resolve `nil` → terminal answers normally):
  multi-question payloads, `multiSelect=true`, >4 or <2 options, label >16 chars
  or total >40 chars, duplicate option labels, feature toggle off, empty
  `session_id`, a second prompt while one is pending.

## 4. Validation & Error Matrix

| Condition | Behavior |
|---|---|
| No reply within script's 5s recv timeout | Script exits 0, no stdout → Claude runs normal permission flow |
| Server handler exceeds 4.5s semaphore window | Server closes fd without reply (same as above) |
| Reply bytes fail `json.loads` (truncated write) | Script silently discards, exits 0 |
| Handler returns `nil` | Server closes fd immediately (fire-and-forget parity) |
| Event has empty `session_id` | Manager ignores it for permission prompts (no invisible pending state) |
| Second PreToolUse while one prompt pending | New one resolves to `nil` immediately |

**Timeout chain invariant (MUST hold)**: UI budget 4.0s < server semaphore 4.5s
< script recv 5s < Claude hook default timeout (60s). The notch is an
accelerator, never a blocker — every path ends in `exit 0`.

## 5. Good/Base/Bad Cases

- Good: user taps Allow in 2s → reply written in window → Claude skips prompt.
- Base: user ignores prompt → 4s UI timeout → nil → terminal prompts normally.
- Bad (guarded): server writes half a reply then closes at 4.5s → script's
  JSON-validity check discards it → terminal flow unaffected.

## 6. Tests Required

No Xcode test target exists yet. When one is added:
- Encode test: `ClaudeHookResponse` allow/deny round-trips to the exact schema
  above (assert `hookSpecificOutput` nesting, nil fields omitted).
- Socket round-trip (can be scripted, see the standalone tests run in-task):
  reply path (stdout == reply JSON, exit 0), no-reply path (empty stdout, exit 0),
  truncated-reply path (empty stdout, exit 0).

## 7. Wrong vs Correct

### Wrong

```python
# recv() on every event — Stop/UserPromptSubmit block Claude up to 5s each
send(event_json); reply = sock.recv(...)
```

```json
{ "decision": "approve" }  // deprecated top-level form for PreToolUse
```

### Correct

```python
# Only PreToolUse waits; everything else stays fire-and-forget
send(event_json)
if event == "PreToolUse":
    sock.shutdown(SHUT_WR)   # half-close so server sees EOF and can reply
    reply = recv_with_timeout(5)
    if is_valid_json(reply): print(reply)
sock.close(); sys.exit(0)
```

## Design Decisions

- **Unix socket over HTTP hooks**: no localhost port surface; reuse existing
  0600-protected socket. HTTP hooks remain a documented alternative.
- **Semaphore bridge**: `semaphore.wait` only ever blocks the dedicated
  concurrent client queue, never the main thread; the `@MainActor` handler runs
  in a detached Task and signals the semaphore (an abandoned post-timeout signal
  is harmless).
- **Prompt visibility gating**: tap guards key off actual on-screen visibility
  (`isPermissionPromptVisible`, reported via onAppear/onDisappear), NOT off
  pending state — higher-priority live activities can hide the prompt.
