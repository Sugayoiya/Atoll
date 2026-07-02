# UI Layer Guidelines (SwiftUI)

> Atoll's UI is SwiftUI hosted in AppKit windows (the notch panel, lock screen panels,
> settings window). There is no web frontend. "Frontend" here means everything under
> `DynamicIsland/components/`, `models/`, `enums/`, and `extensions/`.

---

## Pre-Development Checklist

Before writing UI code, read:

1. [Directory Structure](./directory-structure.md) — feature folders, naming (`*View`, `*LiveActivity`)
2. [Component Guidelines](./component-guidelines.md) — view shape, dependency access, Live Activity pattern
3. [State Management](./state-management.md) — singleton managers, Defaults, Combine
4. [Reusable Logic](./reusable-logic.md) — view modifiers and extensions (the "hooks" of this codebase)
5. [Type Safety](./type-safety.md) — enums, Codable, optionals, access control
6. [Quality Guidelines](./quality-guidelines.md) — file size limits, forbidden patterns

---

## Guidelines Index

| Guide | Description |
|-------|-------------|
| [Directory Structure](./directory-structure.md) | Where views, models, enums, extensions go |
| [Component Guidelines](./component-guidelines.md) | View struct shape, Live Activities, animations |
| [State Management](./state-management.md) | ObservableObject singletons, `@Default`, Combine |
| [Reusable Logic](./reusable-logic.md) | View modifiers, `View` extensions, shared helpers |
| [Type Safety](./type-safety.md) | Enum conventions, Codable models, optional handling |
| [Quality Guidelines](./quality-guidelines.md) | Standards, anti-patterns, review checklist |

---

## Quick Facts

- Window-level state comes from `@EnvironmentObject var vm: DynamicIslandViewModel`
  (injected in `DynamicIslandApp.swift`); feature state from `@ObservedObject var m = XManager.shared`.
- User settings bind via `@Default(.key)` from the Defaults library; keys live in
  `models/Constants.swift`.
- Closed-notch UI is a "Live Activity": a three-zone HStack orchestrated by the priority
  chain in `ContentView.swift`.
- Preferred animation: `withAnimation(.smooth)`.

**Language**: All documentation should be written in **English**.
