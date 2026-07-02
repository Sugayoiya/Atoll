# Component Guidelines

> How SwiftUI views are shaped in this codebase, including the Live Activity pattern
> that defines the closed-notch UI.

---

## Standard View Shape

The canonical view struct (see `components/Notch/NotchTimerView.swift`,
`components/Timer/TimerLiveActivity.swift`):

```swift
struct NotchTimerView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel      // window-level state
    @ObservedObject var timerManager = TimerManager.shared // feature manager singleton
    @Default(.enableTimerFeature) var enableTimerFeature   // user settings
    @State private var customHours: Int = 0                // local UI state

    // private computed properties for layout, often using
    // vm.effectiveClosedNotchHeight / vm.closedNotchSize

    var body: some View { ... }
}
```

Dependency access rules:

- **Window-level state**: `@EnvironmentObject var vm: DynamicIslandViewModel` (injected in
  `DynamicIslandApp.swift`; `WebcamManager` is the only other environment object).
- **Feature state**: `@ObservedObject var x = XManager.shared` — direct singleton reference
  is the norm here (`ContentView.swift` holds 15+ of them). There is no DI container.
- **Settings**: `@Default(.key)` for bindings; `Defaults[.key]` for one-shot reads.
- **`@StateObject`**: only when the view owns the object's lifecycle
  (`components/Shelf/Views/ShelfView.swift`, `components/LockScreen/LockScreenLiveActivity.swift`).
- **`@Observable` types** (currently only `DownloadManager`): hold with
  `@State private var m = DownloadManager.shared` (`ContentView.swift`).

Local `private struct` / `private final class` helpers embedded in the view file are
common and fine (`NotchHomeView.swift`'s artwork loop controller).

---

## Live Activities (closed-notch UI)

A Live Activity is a three-zone HStack: left wing – black center notch spacer – right
wing, sized off `vm.effectiveClosedNotchHeight` and shown only when
`vm.notchState == .closed`.

- **Minimal example to copy**: `components/Recording/RecordingLiveActivity.swift` (~100
  lines: expand/collapse + a `PulsingModifier`).
- **Full-featured example**: `components/Timer/TimerLiveActivity.swift` (progress ring,
  `@Default` configuration).
- **Registration**: add your activity to the priority `if/else if` chain in
  `ContentView.swift` (~line 925+: sneak-peek HUD > caps lock > music > timer > reminder >
  Claude Code > recording > download > LocalSend > Do Not Disturb > lock screen > privacy >
  extensions > shelf). An activity that isn't in the chain never shows, and each branch
  gates on `vm.notchState == .closed`, the feature's Defaults toggle, and `!vm.hideOnClosed`.
- `LiveActivityModifier.swift` (`.liveActivity(for:left:right:)`) is a legacy abstraction;
  most activities build their HStack directly. Prefer the direct pattern.

---

## Animations

- Default: `withAnimation(.smooth)` / `.smooth(duration:)` — used throughout
  (`models/DynamicIslandViewModel.swift`, `RecordingLiveActivity.swift`).
- Springs and `.easeInOut` appear for specific interactions
  (`extensions/Button+Bouncing.swift` uses `.interactiveSpring(dampingFraction: 1.2)`).
- Name reusable animation constants when a feature has several
  (`LockScreenAnimationTimings` in `LockScreenLiveActivity.swift`).
- Looping effects: `.repeatForever(autoreverses: true)` inside a ViewModifier
  (`PulsingModifier` in `RecordingLiveActivity.swift`).

---

## Other Conventions

- Every file starts with the GPL header comment block — keep it on new files.
- Platform guards `#if canImport(AppKit)` appear where code is shared with previews
  (`TimerLiveActivity.swift`).
- Feature views must respect their feature toggle (`@Default(.enableTimerFeature)`) and
  render nothing when disabled.

---

## Common Mistakes

- Putting business logic (timers, socket handling, system observation) in the view —
  it belongs in a manager; the view only renders `@Published` state.
- Building a Live Activity without wiring it into `ContentView`'s priority chain.
- Hardcoding notch dimensions instead of reading `vm.closedNotchSize` /
  `vm.effectiveClosedNotchHeight` / `sizing/matters.swift`.
