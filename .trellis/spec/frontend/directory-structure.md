# Directory Structure (UI Layer)

> How UI code is organized in `DynamicIsland/`.

---

## Folder Map

| Directory | Role | Examples |
|-----------|------|----------|
| `DynamicIsland/ContentView.swift` | Root notch view; Live Activity priority chain | — |
| `DynamicIsland/DynamicIslandViewCoordinator.swift` | Tab navigation, sneak peek, screen selection | — |
| `DynamicIsland/models/` | Data models, `DynamicIslandViewModel`, and **all Defaults keys** (`Constants.swift`) | `models/TimerPreset.swift`, `models/DynamicIslandViewModel.swift` |
| `DynamicIsland/components/<Feature>/` | Feature UI, one folder per feature | `components/Notch/`, `components/Timer/`, `components/Stats/` |
| `DynamicIsland/components/*.swift` (root) | Small shared components | `components/HoverButton.swift` |
| `DynamicIsland/enums/` | UI/behavior enums | `enums/generic.swift`, `enums/TimerDisplayMode.swift` |
| `DynamicIsland/extensions/` | `View`/`Button`/AppKit-type extensions, gestures, modifiers | `extensions/View+Parallax3D.swift`, `extensions/ConditionalModifier.swift` |
| `DynamicIsland/helpers/` | Non-SwiftUI utilities consumed by UI (permissions, glass background) | `helpers/LiquidGlassBackground.swift` |
| `DynamicIsland/sizing/matters.swift` | Notch size constants/calculations | — |

---

## Feature Folder Conventions

**Default: flat feature folder.** Views and their local helpers sit side by side, no
subdirectories — this is how `Notch/` (14 files), `Settings/`, `Timer/`, `Stats/`,
`LockScreen/`, and `OSD/` are organized.

**Layered structure for complex features.** Only `Shelf/` uses full layering, and it's
the reference if your feature has real persistence/services of its own:

```
components/Shelf/
├── Models/       ShelfItem.swift, Bookmark.swift
├── ViewModels/   ShelfStateViewModel.swift, ShelfSelectionModel.swift
├── Services/     ShelfPersistenceService.swift, QuickLookService.swift
└── Views/        ShelfView.swift, ShelfInlineLiveActivity.swift
```

Don't add Views/ViewModels/Services scaffolding to a two-file feature.

---

## Naming Conventions

| Pattern | Meaning | Examples |
|---------|---------|----------|
| `<Feature>View` | SwiftUI view | `WebcamView.swift`, `NotchStatsView.swift` |
| `Notch<Feature>View` | Tab content inside the open notch | `NotchHomeView.swift`, `NotchTimerView.swift` |
| `<Feature>LiveActivity` | Closed-notch inline activity | `TimerLiveActivity.swift`, `RecordingLiveActivity.swift` |
| `<Feature>ViewModel` | UI state object (Shelf or root level) | `ShelfStateViewModel.swift` |
| `Type+Feature.swift` | Extension file | `Button+Bouncing.swift`, `NSImage+Extensions.swift` |
| `DynamicIsland*` | Notch shell / system-level UI | `DynamicIslandHeader.swift` |

Business logic does **not** live in `components/` — it goes in
`managers/<Feature>Manager.swift` (see the backend spec's directory structure).

---

## Where New Things Go

- New feature UI → `components/<Feature>/` with `<Feature>View.swift` and, if it shows in
  the closed notch, `<Feature>LiveActivity.swift`.
- New enum → `enums/generic.swift` if it's a small settings/mode enum, or its own file if
  it has logic (`TimerDisplayMode.swift`).
- New reusable view behavior → `extensions/` as a `View` extension or ViewModifier.
- New Defaults key → `models/Constants.swift`, always.
