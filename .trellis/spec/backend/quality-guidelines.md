# Quality Guidelines (System Layer)

> No test target and no SwiftLint config exist today. Quality is enforced by review
> and these conventions. The bar: the project must build in Xcode without errors or
> new warnings.

---

## Concurrency Rules

The codebase mixes GCD, Combine, and async/await. Follow the local division of labor:

- **UI-facing state**: mark the manager `@MainActor` when practical
  (`managers/AgentSessionManager.swift`, `services/Extensions/ExtensionXPCServiceHost.swift`,
  `components/Shelf/Services/LocalSendService.swift`). From a background callback, hop with
  `Task { @MainActor in ... }` — not `DispatchQueue.main.async` in new code.
- **Blocking I/O** (sockets, audio): dedicated `DispatchQueue` with a descriptive label
  plus `DispatchSource` for non-blocking accept
  (`services/AgentHooks/AgentHookSocketServer.swift`).
- **Settings reactions**: Combine `Defaults.publisher(...).sink`, cancellables stored on
  the manager (`managers/SystemHUDManager.swift`).
- **New network / scripting code**: prefer `async/await`
  (`components/Shelf/Services/LocalSendService.swift`, `managers/AppleNotesSyncManager.swift`).
- `@unchecked Sendable` is acceptable only for classes that genuinely confine state to a
  private queue, as `AgentHookSocketServer` does — document why in a comment.

---

## Singleton Discipline

- `static let shared` + `private init()` is the standard manager shape. Keep `init` cheap;
  heavy setup goes in `start()` / `configure(...)` so disabled features cost nothing.
- Feature managers must be toggleable: subscribe to their Defaults key and start/stop on
  change (`AgentSessionManager`). Never assume a feature is always on.

---

## Forbidden Patterns

- New `print` / `NSLog` calls (see [Logging Guidelines](./logging-guidelines.md)).
- New `@AppStorage` or bare `UserDefaults.standard` keys (see
  [Persistence Guidelines](./persistence-guidelines.md)).
- `_Fixed` / `_New` / `_Old` file copies — edit in place, use git for history
  (`managers/ColorPickerManager_Fixed.swift` is a leftover, not a pattern).
- Calling private frameworks directly from a manager — go through a `helpers/`/`utils/`
  wrapper that returns optionals.
- Force unwraps in system-layer code. Existing ones (e.g.
  `Bundle.main.bundleIdentifier!` in `models/Constants.swift`) are tolerated debt, not license.

---

## Known Tech Debt (documented so you don't "fix" it in passing)

- Three logging APIs coexist; the global `print`/`NSLog` override in `utils/Logger.swift`
  papers over it.
- Very large managers: `MusicManager.swift` (~1800 lines), `StatsManager.swift`,
  `DoNotDisturbManager.swift`. Don't grow them; split when you touch them substantially.
- No formal DI — singletons plus `configure(...)`. Match it; don't introduce a DI
  framework in a feature PR.
- No tests. If you add a critical parsing/protocol path (e.g. RPC decoding), adding a
  test target is welcome but is its own task.

---

## Review Checklist

- [ ] Builds without new warnings in Xcode.
- [ ] New settings keys are in `models/Constants.swift` `Defaults.Keys`.
- [ ] Logging via `Logger.log` with a category.
- [ ] Background work is queue- or actor-confined; UI updates on the main actor.
- [ ] Feature can be fully disabled via its Defaults toggle.
