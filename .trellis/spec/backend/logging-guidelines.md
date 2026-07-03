# Logging Guidelines

> One shared logger exists: `DynamicIsland/utils/Logger.swift`. New code must use it.
> The codebase still contains legacy `NSLog`/`print` calls; do not add more.

---

## The Shared Logger

`utils/Logger.swift`:

- Built on `OSLog` (`os_log`), subsystem `com.ebullioscopic.Atoll`, with emoji-tagged categories.
- Filtered at runtime by the user-facing `Defaults[.logLevel]` setting — **default is
  `.none`, so all logging is off unless the user enables it**. Never rely on logs being
  visible in production.
- Globally overrides free-function `print` and `NSLog` (bottom of `Logger.swift`) so
  legacy calls also respect the log level — this keeps old code quiet, but bare `print`
  gives you no category and hides the call site. New code must call `Logger.log` directly.
- In DEBUG builds every `Logger.log` entry is also echoed to stdout.

Usage — category is one of the fixed `LogCategory` cases; the log level is derived from
the category (`category.defaultLevel`), not passed by the caller:

```swift
Logger.log("Claude hook socket bind failed: \(errno)", category: .error)
```

(real call from `services/AgentHooks/AgentHookSocketServer.swift`)

Good adopters to copy from: `services/AgentHooks/AgentHookSocketServer.swift`,
`services/Extensions/ExtensionXPCServiceHost.swift`, `managers/AgentSessionManager.swift`.

---

## Categories and Their Levels

`LogCategory` (defined in `utils/Logger.swift`) and the level each maps to:

| Category | Level | Use for |
|----------|-------|---------|
| `.error` | error | Unrecoverable setup failures (socket bind failed, capture session broken) |
| `.warning` | warning | Integration unavailable / falling back, rejected external input, corrupt item skipped |
| `.lifecycle` | info | Service start/stop, connection accept/close, app lifecycle |
| `.ui`, `.network`, `.success`, `.memory`, `.performance`, `.extensions` | info | Domain-specific informational events |
| `.debug` | debug | Detailed protocol traffic, state-machine transitions |

If your subsystem doesn't fit, extend the `LogCategory` enum in `Logger.swift`
(add the case, its `osCategoryName`, and its `defaultLevel`) rather than misusing an
existing category.

---

## Rules

- **New code**: `Logger.log(..., category:)` with the category whose `defaultLevel`
  matches the severity — e.g. failures go to `.error`/`.warning`, not `.debug`.
- **Never** add new `print(...)` or `NSLog(...)` calls, even for temporary debugging that
  might get committed.
- Direct `os.Logger(subsystem:category:)` appears in a couple of files
  (`managers/ReminderLiveActivityManager.swift`) — acceptable, but prefer the shared
  `Logger` so output respects the user's log-level setting.
- Log at boundaries: service start/stop, connection accept/close, integration failures,
  state-machine transitions. Don't log per-frame or per-tick data (audio/stats loops).
