# System Layer Guidelines (managers / services / helpers)

> Atoll is a macOS SwiftUI app (Dynamic Island for the MacBook notch). There is no
> web backend. In this project, "backend" means the **system layer**: singleton
> managers, cross-process services, private-framework bridges, and persistence.
> Main source tree: `DynamicIsland/`.

---

## Pre-Development Checklist

Before writing system-layer code, read:

1. [Directory Structure](./directory-structure.md) — where managers, services, helpers, and utils go
2. [Persistence Guidelines](./persistence-guidelines.md) — Defaults keys, JSON files, no database
3. [Error Handling](./error-handling.md) — typed errors at boundaries, graceful degradation inside
4. [Logging Guidelines](./logging-guidelines.md) — use `Logger.log`, not bare `print`/`NSLog`
5. [Quality Guidelines](./quality-guidelines.md) — concurrency rules, forbidden patterns

---

## Guidelines Index

| Guide | Description |
|-------|-------------|
| [Directory Structure](./directory-structure.md) | managers vs services vs helpers vs utils, real examples |
| [Persistence Guidelines](./persistence-guidelines.md) | Defaults library, Application Support JSON, no ORM |
| [Error Handling](./error-handling.md) | Error types per layer, catch-and-log conventions |
| [Logging Guidelines](./logging-guidelines.md) | `utils/Logger.swift`, log levels, categories |
| [Quality Guidelines](./quality-guidelines.md) | Concurrency, singletons, known tech debt |

---

## Quick Facts

- **Language/stack**: Swift 5.9+, AppKit + SwiftUI, Xcode project `DynamicIsland.xcodeproj` (no SPM package manifest at root).
- **No database**: persistence is the [Defaults](https://github.com/sindresorhus/Defaults) library + JSON files in Application Support.
- **No test target, no SwiftLint**: quality relies on review; build must compile without errors.
- **App entry**: `DynamicIsland/DynamicIslandApp.swift` (`@main DynamicNotchApp` + `AppDelegate`); most managers boot from `applicationDidFinishLaunching`.

**Language**: All documentation should be written in **English**.
