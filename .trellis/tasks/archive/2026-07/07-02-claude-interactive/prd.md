# Claude Code Interactive Notch (answer questions + permission control)

## Goal

Extend Atoll's existing one-way Claude Code live activity into a **bidirectional**
integration. Today the notch only *displays* hook events (fire-and-forget over a
Unix socket). We want the notch to also *respond* to Claude Code: answer
`AskUserQuestion` multiple-choice prompts, allow/deny/ask tool permissions, and
enrich the displayed status — so the user can drive a Claude Code session from the
notch without switching to the terminal.

## What I already know

Current implementation (commit 7d0bf2a, branch feat/claude-code-live-activity):
* `ClaudeHookScript.swift` — embedded bash script installed to `~/.claude/hooks/`.
  It POSTs event JSON to `/tmp/atoll-claude.sock` and **discards any reply**
  (`sock.close()` immediately; fire-and-forget).
* `ClaudeHookInstaller.swift` — writes the script + registers it in
  `~/.claude/settings.json` for events: UserPromptSubmit, SessionStart, PreToolUse,
  PostToolUse, PermissionRequest, PreCompact, Stop, SubagentStop, SessionEnd.
* `ClaudeHookSocketServer.swift` — `AF_UNIX` `SOCK_STREAM` server. Reads client
  bytes, decodes `ClaudeHookEvent`, invokes handler. **Never writes back** to the
  client socket.
* `ClaudeCodeManager.swift` — `@MainActor` ObservableObject. Maps events →
  `SessionStatus` (thinking / runningTool / compacting / waitingForInput), drives
  the live activity + sneak-peek.
* `ClaudeHookEvent` fields: provider, session_id, cwd, event, tool, user_prompt.

Hook capabilities confirmed from official docs (code.claude.com/docs/en/hooks):
* **PreToolUse** fires for `AskUserQuestion` and `ExitPlanMode` (among Bash, Edit,
  Write, Read, Glob, Grep, Agent, WebFetch, WebSearch, MCP tools).
* PreToolUse decision is returned in `hookSpecificOutput` (NOT top-level decision):
  `permissionDecision` ∈ {allow, deny, ask, defer}, `permissionDecisionReason`,
  `updatedInput` (replaces full tool input), `additionalContext`.
* **AskUserQuestion**: `tool_input.questions[]` = {question, header, options[].label,
  multiSelect}. To answer programmatically: return `permissionDecision:"allow"` +
  `updatedInput` echoing the `questions` array PLUS an `answers` object
  `{questionText: chosenLabel}` (multi-select = comma-joined labels).
  `"allow"` alone is NOT sufficient for AskUserQuestion/ExitPlanMode.
* **Permission control** via `permissionDecision`: allow (skip prompt) / deny /
  ask (confirm) / defer. Deny+ask permission *rules* still apply regardless.
* Hooks are synchronous: to return a decision the hook must print JSON to **stdout**
  and **exit 0**. Claude blocks while the hook runs (default timeout applies).
* HTTP hooks are also supported (`type:"http"`, POST body = input, response body =
  decision JSON) — an alternative transport to the current Unix socket.

## Critical open question — RESOLVED (PoC PASSED 2026-07-02)

PoC (scripts/poc-askuserquestion/) verified in a real interactive `claude`
session: PreToolUse hook returning `permissionDecision:"allow"` +
`updatedInput` (questions echoed + `answers` map) **pre-answers
AskUserQuestion** — the terminal never prompts and shows
"User answered Claude's questions: Which color do you prefer? → Red".
The AskUserQuestion answer UI (PR3) is therefore unblocked for interactive mode.
(`defer` remains headless-only per docs and stays out of scope.)

## Assumptions (temporary)

* Users run `claude` interactively (not via `claude -p`). Headless is secondary.
* One PreToolUse tool call at a time is the common case (defer requires single call).
* Sub-second notch UI latency is acceptable within the hook timeout window.

## Open Questions

* ~~[BLOCKING] Does interactive-mode allow+updatedInput pre-answer AskUserQuestion?~~
  → **RESOLVED: YES** (PoC passed 2026-07-02, see section above). PR3 unblocked.

## Decisions (ADR-lite)

**Context**: 4 features selected (AskUserQuestion answering, permission dialog,
display enrichment, PoC). AskUserQuestion carries an unverified interactive-mode
risk; the others are known-good in interactive mode.

* **Sequencing = PoC-first, risk-gated.** Run a throwaway shell-script PoC to
  settle the interactive-mode unknown BEFORE building any UI. Then bidirectional
  socket -> permission dialog -> AskUserQuestion (only if PoC passes) -> display
  enrichment (parallel/independent).
* **Transport = keep the Unix socket, make it bidirectional.** Reuse the existing
  AF_UNIX server: write a JSON reply on the same client fd before closing; the
  hook script does sock.recv() and prints the reply to stdout then exit 0. No HTTP
  listener / port / localhost surface added.
* **Timeout UX = short bounded wait, then fall through to terminal.** Notch waits a
  bounded window well under Claude's hook timeout; on no-response the hook exits 0
  with NO decision JSON so Claude's normal permission flow continues. The notch is a
  convenience accelerator, never a hard blocker.

**Consequences**: AskUserQuestion feature is contingent on Phase 0. If the PoC
fails, that feature becomes headless-only or is dropped, with zero UI wasted.
Bidirectional plumbing + permission dialog + display enrichment are unaffected.

## Requirements (evolving)

* Make the hook <-> Atoll channel bidirectional (request/response on same connection).
* Permission dialog in the notch: allow / deny / ask for PreToolUse tool calls.
* AskUserQuestion answer UI in the notch (pending PoC outcome for interactive mode).
* Richer status display (tool args summary, prompt preview, progress).

## Acceptance Criteria (evolving)

* [x] PoC proves (or disproves) interactive-mode AskUserQuestion pre-answering. → PASSED
* [ ] Hook script reads Atoll's reply from the socket and prints it to stdout.
* [ ] Socket server can write a response back on the same client connection.
* [ ] A dangerous Bash command triggers a notch allow/deny prompt and is honored.
* [ ] No regression to existing one-way live activity when features are disabled.

## Definition of Done (team quality bar)

* Tests added/updated where feasible (socket round-trip, JSON schema encode/decode).
* Lint / typecheck / build green (Xcode project builds).
* Behavior gated behind existing Defaults toggle(s); safe when disabled.
* Rollback: uninstall path cleanly removes hooks (existing `uninstall()` covers it).

## Out of Scope (explicit)

* Headless `claude -p --resume` orchestration driven BY Atoll (separate effort).
* Atoll acting as an MCP server (that's Claude calling Atoll's tools — different).
* Multi-question complex forms beyond AskUserQuestion's native shape.

## Technical Notes

* Files: DynamicIsland/services/ClaudeCode/{ClaudeHookScript,ClaudeHookInstaller,
  ClaudeHookSocketServer}.swift, managers/ClaudeCodeManager.swift,
  components/ClaudeCode/ClaudeCodeLiveActivity.swift.
* Socket: `/tmp/atoll-claude.sock`, chmod 0600.
* Making it bidirectional requires: (a) script `recv()` + echo to stdout + exit 0;
  (b) server keeps client fd open, writes JSON reply, then closes.
* Interactive-mode UI must respond within the hook timeout, else Claude waits/blocks
  the user's terminal — timeout/fallback behavior must be deliberate.

## Research References

* [`research/claude-hooks-decision-control.md`](research/claude-hooks-decision-control.md) —
  PreToolUse decision schema, AskUserQuestion answers format, defer headless-only
  constraint, timeout fallback semantics (extracted from code.claude.com/docs/en/hooks).
