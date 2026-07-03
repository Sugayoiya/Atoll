# Agent Hook ↔ Atoll Socket Protocol (Code-Spec)

> Executable contract for the bidirectional Unix-socket channel between
> installed agent hook scripts (Claude Code and Cursor) and Atoll's
> in-app socket server. Established in task 07-02-claude-interactive;
> generalized to the provider-agnostic envelope + Cursor provider in
> 07-03-cursor-hooks-interactive.

## 1. Scope / Trigger

Cross-layer request/response contract: bash/python hook script (Claude:
installed to `~/.claude/hooks/`) ↔ `AgentHookSocketServer` ↔
`AgentSessionManager` (+ per-provider `AgentProvider` adapter) ↔ notch UI.
Any change to envelope fields, reply schema, or timeout values MUST update this
doc and bump the affected script version marker.

## 2. Signatures

- Socket: `AF_UNIX` `SOCK_STREAM` at `/tmp/atoll-agent.sock`, `chmod 0600`.
- Server handler: `typealias EventHandler = (AgentHookEnvelope) async -> Data?`
  — return `nil` = no decision (fire-and-forget parity); return the provider's
  encoded reply bytes = decision written back on the SAME client fd.
- Claude script (embedded in `ClaudeHookScript.swift`, version marker
  `atoll-hook-version: N`, currently v4):
  - All events: connect (1s timeout) → send envelope JSON.
  - `PreToolUse` only: `shutdown(SHUT_WR)` (half-close signals EOF to server) →
    `recv()` with 5s timeout → if reply parses as JSON, print to stdout, exit 0;
    else exit 0 with NO stdout output.
  - Non-PreToolUse events: `close()` immediately after send (never wait).
- Cursor script (embedded in `CursorHookScript.swift`, version marker
  `atoll-cursor-hook-version: N`, currently v2; installed to
  `~/.cursor/hooks/`, registered in `~/.cursor/hooks.json`):
  - Same envelope send; ONLY `beforeShellExecution` / `beforeMCPExecution` do
    the reply dance (`shutdown(SHUT_WR)` → 5s recv → JSON-validate → stdout);
    all other events (incl. `preToolUse`) are fire-and-forget.
  - The hooks.json entries for those two events carry an explicit
    `"timeout": 10` (seconds); display-event entries have no timeout override.

## 3. Contracts

Wire envelope (script → Atoll), all providers:

```json
{ "provider": "claude", "event": "<provider-native event name>", "payload": { "...": "provider's RAW hook stdin JSON, untouched" } }
```

Normalization happens in Swift only: each provider's `AgentProvider` adapter
maps `payload` → normalized `AgentEvent` and encodes generic `AgentDecision`s
into the provider's reply schema. Scripts stay thin forwarders.

For Claude, `payload` carries Claude's raw hook input (`session_id`, `cwd`,
`hook_event_name`, `tool_name`, `tool_input`, `prompt`, ...), decoded via
`JSONValue`.

Reply JSON is provider-specific, built by the provider adapter's decision
encoder. Claude (Atoll → script → Claude stdout) — `ClaudeHookResponse`:

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

Cursor (Atoll → script → Cursor stdout) — flat schema, NO `hookSpecificOutput`
nesting; only for `beforeShellExecution` / `beforeMCPExecution`:

```json
{
  "permission": "allow | deny",
  "user_message": "optional string, shown to the user",
  "agent_message": "optional string, shown to the agent"
}
```

- `ask` is tolerated by Cursor's schema but Atoll never sends it — the generic
  `.ask` decision encodes to no reply (identical to a timeout, fail-open).
- Cursor identity: `conversation_id` plays the role of `session_id`;
  `workspace_roots[0]` serves as the display cwd.
- Cursor `preToolUse` output tolerates `ask` but does NOT enforce it — the two
  before*Execution hooks are the only permission-control path.

## 4. Validation & Error Matrix

| Condition | Behavior |
|---|---|
| No reply within script's 5s recv timeout | Script exits 0, no stdout → Claude runs normal permission flow |
| Server handler exceeds 4.5s semaphore window | Server closes fd without reply (same as above) |
| Reply bytes fail `json.loads` (truncated write) | Script silently discards, exits 0 |
| Handler returns `nil` | Server closes fd immediately (fire-and-forget parity) |
| Event has empty `session_id` | Manager ignores it for permission prompts (no invisible pending state) |
| Second PreToolUse while one prompt pending | New one resolves to `nil` immediately |
| Cursor: no reply within 5s recv / invalid JSON | Script exits 0, no stdout → Cursor runs its own permission flow (fail-open) |

**Timeout chain invariant (MUST hold)**: UI budget 4.0s < server semaphore 4.5s
< script recv 5s < host hook timeout (Claude default 60s; Cursor: explicit
`"timeout": 10` on the two permission entries in hooks.json). The notch is an
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
