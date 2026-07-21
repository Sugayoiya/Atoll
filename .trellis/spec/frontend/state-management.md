# State Management

> State lives in singleton `ObservableObject` managers, user settings live in the
> Defaults library, and cross-cutting recomputation is wired with Combine.

---

## The Three Stores

1. **Feature managers** — `class XManager: ObservableObject { static let shared }` with
   `@Published` properties (`managers/TimerManager.swift`, `managers/MusicManager.swift`).
   Views observe them with `@ObservedObject var x = XManager.shared`.
2. **Window/view model** — `models/DynamicIslandViewModel.swift`: notch open/closed state,
   popover flags, dynamic notch size. Injected once as an `@EnvironmentObject` from
   `DynamicIslandApp.swift`. It subscribes (Combine) to manager publishers and Defaults
   keys to recompute notch size and calls back into `AppDelegate` for window resizing.
3. **User settings** — Defaults library. Keys in `models/Constants.swift`
   (`extension Defaults.Keys`); views bind with `@Default(.key)`; managers react with
   `Defaults.publisher(.key).sink`.

---

## ObservableObject vs @Observable

`ObservableObject` + `@Published` is the standard (60+ classes). The Observation
framework (`@Observable`) is used in exactly one place, `managers/DownloadManager.swift`,
held via `@State` in `ContentView`. Don't migrate types ad hoc; follow the existing
`ObservableObject` pattern for new managers unless a broader migration is decided.

---

## Combine Wiring

- `DynamicIslandViewModel.init` combines `Defaults.publisher(...)` and
  `Manager.shared.$property` streams to drive notch-size recalculation.
- `DynamicIslandViewCoordinator.init` merges Defaults publishers to refresh tab visibility.
- Store cancellables on the owning object; don't create ad-hoc global subscriptions.

---

## NotificationCenter

Used sparingly in the UI layer, mostly bridged by `AppDelegate` / the coordinator:
screen changes (`DynamicIslandViewCoordinator.swift` `selectedScreenChanged`), popover
shortcut toggles (`DynamicIslandApp.swift` `"ToggleClipboardPopover"`), and
`DistributedNotificationCenter` for cross-process events. Prefer `@Published` state over
new notification names when the producer and consumer are both in-app.

---

## Rules

- New user-facing setting → new key in `Constants.swift` + `@Default` binding. **No new
  `@AppStorage`** (legacy ones exist in `DynamicIslandViewCoordinator.swift`; don't add more).
- Transient UI state (text fields, hover flags) → `@State private` in the view.
- State shared across views of one feature → the feature's manager, not a chain of
  `@Binding`s.
- Mutations that must animate → wrap in `withAnimation(.smooth)` at the mutation site
  (`DynamicIslandViewModel.open()/close()`).
