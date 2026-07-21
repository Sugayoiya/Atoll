# Generic Agent Hook Model + Cursor Provider (port of Claude Code integration)

## Goal

Refactor Atoll's Claude-specific hook pipeline into a **provider-agnostic
agent-session model**, then add Cursor as the second provider. Atoll installs
per-provider hooks (Claude: `~/.claude/settings.json`; Cursor:
`~/.cursor/hooks.json` + hook script), receives normalized agent events over
the shared Unix-socket channel, shows live activities per session, and lets
the user allow/deny tool executions from the notch where the provider's hook
API supports it. Future providers (Codex, Gemini CLI, ...) plug in by adding
an installer + event mapping only.

## What I already know

Existing Claude Code integration (branch feat/claude-code-live-activity):

* `ClaudeHookScript.swift` — embedded bash+python script in `~/.claude/hooks/`,
  forwards event JSON to `/tmp/atoll-claude.sock`; PreToolUse waits (bounded)
  for a decision reply and prints it to stdout.
* `ClaudeHookInstaller.swift` — registers script in `~/.claude/settings.json`
  for 9 events; idempotent install/uninstall.
* `ClaudeHookSocketServer.swift` — AF_UNIX server, handler returns `Data?`
  (nil = fire-and-forget, bytes = reply written on same fd).
* `ClaudeCodeManager.swift` — maps events → SessionStatus (thinking /
  runningTool / compacting / waitingForInput), drives live activity +
  permission prompt. Event model already has a `provider` field ("claude").
* Timeout chain invariant: UI 4.0s < server semaphore 4.5s < script recv 5s
  < host hook timeout. Spec: `.trellis/spec/backend/claude-hook-socket-protocol.md`.

Cursor hooks facts (see `research/cursor-hooks-reference.md`):

* Config: `~/.cursor/hooks.json` (user) or `<project>/.cursor/hooks.json`
  (project). Hot-reloaded. User hooks run with cwd `~/.cursor/`.
* Command hooks: JSON stdin → JSON stdout, exit 0; exit 2 = deny. Fail-open by
  default; per-entry `timeout` (seconds) configurable in hooks.json.
* Event mapping exists for everything Atoll displays today: `sessionStart`,
  `sessionEnd`, `beforeSubmitPrompt`, `preToolUse`, `postToolUse`,
  `preCompact`, `stop`, `subagentStop` (+ new: `postToolUseFailure`,
  `afterFileEdit`, `subagentStart`...).
* Permission control: `beforeShellExecution` / `beforeMCPExecution` return
  `{permission: allow|deny|ask, user_message, agent_message}` — flat schema,
  NOT Claude's `hookSpecificOutput` nesting.
* **No AskUserQuestion answering path** — Cursor has no hook that lets us
  pre-answer the AskQuestion tool. That Claude feature does NOT port.
* ID field is `conversation_id` (stable per conversation), not `session_id`.

## Assumptions (temporary)

* Target is the local Cursor IDE (agent chat), not cloud agents.
* User-level install (`~/.cursor/hooks.json`) to mirror the Claude approach
  (works across all projects, no repo pollution).
* Reuse the existing socket-server infra; add provider="cursor" rather than
  duplicating the pipeline.

## Decisions (ADR-lite)

* **Scope = display + permission control** (2026-07-03, user confirmed):
  Cursor integration reaches parity with Claude — live activity plus
  allow/deny prompts for `beforeShellExecution` / `beforeMCPExecution`.
  AskUserQuestion answering excluded (no Cursor hook path).
* **Architecture = generic provider model** (2026-07-03, user confirmed):
  one shared Unix socket + one normalized event model with a `provider`
  discriminator; a generic session manager / live activity; per-provider
  adapters (hook script + installer + event→status mapping + reply encoder).
  Not a parallel copy-paste pipeline.
* **Normalization lives in Swift, not in scripts** (2026-07-03, user
  confirmed): hook scripts stay thin and forward the provider's RAW event
  (wrapped in a small envelope `{provider, event, payload}`); each provider
  gets a Swift adapter that maps raw events → normalized `AgentEvent` and
  encodes decisions back into the provider's reply schema. Raw events remain
  visible for debugging.
* **Refactor depth = full generalization** (2026-07-03, user confirmed):
  rename Claude* core types to generic Agent* (`AgentHookEvent`,
  `AgentSessionManager`, `AgentHookSocketServer`, generic live activity);
  Claude becomes just one provider adapter. Claude-specific bits
  (AskUserQuestion, `hookSpecificOutput` encoding, settings.json installer)
  stay in the Claude adapter namespace.

## Open Questions

(none — converged)

## Requirements

* **Generic core**:
  * Wire envelope `{provider, event, payload}` over the shared Unix socket;
    scripts forward the provider's raw hook JSON as `payload` untouched.
  * `AgentProvider` abstraction: id/name/accent color/icon, raw event →
    normalized `AgentEvent` mapping, decision → provider reply encoding,
    installer (install/uninstall/isInstalled).
  * Normalized `AgentEvent` vocabulary covering: sessionStart, sessionEnd,
    promptSubmit, toolWillRun, toolDidRun, compacting, stopped/awaitingInput,
    permissionRequest(tool, inputSummary), question (Claude-only).
  * `AgentSessionManager` (generalized ClaudeCodeManager): sessions keyed by
    (provider, sessionId), status mapping, prompt slot + timeout chain,
    sneak peek; live activity shows provider badge + accent color.
  * Generic decision model (allow / deny / ask + reason) encoded
    per-provider.
* **Claude provider** (refactor, no behavior change): settings.json
  installer, script v4 (adds envelope), `hookSpecificOutput` encoding,
  AskUserQuestion answering kept Claude-only.
* **Cursor provider** (new):
  * Idempotent install/uninstall of hook script + `~/.cursor/hooks.json`
    (JSON merge preserves user's own entries; explicit `timeout` set on
    entries that wait for replies).
  * Display events: sessionStart, sessionEnd, beforeSubmitPrompt, preToolUse,
    postToolUse, preCompact, stop, subagentStop.
  * Permission control: beforeShellExecution / beforeMCPExecution → notch
    allow/deny → flat `{permission, user_message, agent_message}` reply;
    no reply within budget = no stdout = fail-open to Cursor's own flow.
* Per-provider Defaults toggles (Cursor gets its own enable/permission
  toggles mirroring the Claude ones).

## Acceptance Criteria

* [x] Starting a Cursor agent chat shows a notch live activity within ~1s.
* [x] Status transitions (prompt submitted → tool running → stop) mirror
      Claude behavior; provider badge distinguishes Cursor vs Claude sessions.
* [x] A shell command in Cursor triggers a notch Allow/Deny prompt; the
      decision is honored; ignoring the prompt falls through to Cursor's own
      permission flow (never blocks).
* [x] Uninstall removes only Atoll-managed entries from `~/.cursor/hooks.json`.
* [x] Claude integration works unchanged after the refactor (live activity,
      permission prompt, AskUserQuestion answering).
* [x] Concurrent Claude + Cursor sessions coexist in the sessions list.

## Definition of Done (team quality bar)

* Xcode build green; lint/typecheck pass.
* Gated behind a Defaults toggle like the Claude integration; safe when off.
* Spec updated (socket protocol doc) if the channel contract changes.

## Out of Scope (explicit)

* AskUserQuestion-style answering (Cursor has no hook path for it).
* Tab hooks (`beforeTabFileRead` / `afterTabFileEdit`), `workspaceOpen`,
  enterprise/team distribution.
* Cloud agent support.

## Technical Approach

Target layout (generalizing `DynamicIsland/services/ClaudeCode/`):

```
services/AgentHooks/
  AgentHookEnvelope.swift      // {provider, event, payload:JSONValue}
  AgentEvent.swift             // normalized event + AgentDecision
  AgentHookSocketServer.swift  // renamed ClaudeHookSocketServer, decodes envelope
  AgentProvider.swift          // protocol: mapEvent, encodeDecision, installer
  Claude/                      // script v4, installer, hookSpecificOutput codec,
                               // AskUserQuestion (Claude-only)
  Cursor/                      // hooks.json installer, script, flat permission codec
managers/AgentSessionManager.swift   // renamed ClaudeCodeManager
components/AgentHooks/...            // generalized live activity
```

Key mechanics:

* Socket stays `/tmp/atoll-claude.sock`? → NO: rename to
  `/tmp/atoll-agent.sock`; Claude script v4 bump rewrites installed script
  (installer already rewrites on content change).
* Envelope keeps old Claude script (v3) working during transition only if we
  accept both shapes — simpler: bump script + decode envelope-only, since
  installer auto-reinstalls on app update.
* Cursor script: same bash+python pattern; waits for reply ONLY on
  beforeShellExecution / beforeMCPExecution; hooks.json entries for those two
  get explicit `timeout` (e.g. 10s) so the chain invariant
  (UI 4.0 < server 4.5 < script recv 5 < hook timeout 10) holds.
* Cursor session identity: `conversation_id`; cwd from `workspace_roots[0]`.
* Timeout chain + fail-open (`exit 0`, no stdout) copied verbatim from the
  Claude design; every path ends in exit 0.

## Implementation Plan (small PRs)

* PR1: generic core refactor (envelope, AgentEvent, AgentProvider, renames,
  Claude adapter extraction, script v4). Claude behavior identical.
* PR2: Cursor provider — installer + script + display events mapping +
  Defaults toggle + settings UI row.
* PR3: Cursor permission control (beforeShellExecution/beforeMCPExecution →
  prompt → flat reply) + provider badge polish.

## Technical Notes

* Cursor hook env: `CURSOR_PROJECT_DIR`, etc. `workspace_roots[0]` serves as
  the session cwd for display.
* Cursor `preToolUse` output schema tolerates `ask` but does not enforce it —
  permission prompts must use beforeShellExecution/beforeMCPExecution.
* Spec to update at finish: `.trellis/spec/backend/claude-hook-socket-protocol.md`
  → generalize into the agent-hook protocol doc (envelope + per-provider reply
  schemas).

## Research References

* [`research/cursor-hooks-reference.md`](research/cursor-hooks-reference.md) —
  Cursor hooks execution model, event mapping table vs Claude, permission
  schema differences.
