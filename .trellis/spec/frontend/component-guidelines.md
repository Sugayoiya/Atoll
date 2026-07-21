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

> **Warning — wing width must be clamped to the hosting window.** The closed-notch
> window is sized to `openNotchSize.width` (or `minimalisticOpenNotchSize(...)` in
> minimalistic mode), and the outer `NotchShape` keeps a horizontal padding equal to
> `cornerRadiusInsets.closed.bottom` (14pt) per side. If unbounded content (e.g. a
> long status string) widens the wings past
> `windowWidth − 2 × cornerRadiusInsets.closed.bottom`, the shape gets clipped and its
> left/right rounded corners visually disappear. Clamp the wing width against that
> budget and apply the SAME derived max to both the measured width (`NSAttributedString`
> measurement) and the rendered `Text.frame(maxWidth:)` so they can't drift.
> See `components/AgentHooks/AgentLiveActivity.swift` for the reference implementation.

- **Agent elapsed counter**: use shared `AgentElapsedIndicator` (closed notch +
  Agents panel). Show only when `status.isBusy && pendingPrompt == nil` and the
  status has persisted ≥ `revealDelay` (2s) — this prevents the clipped lone
  `"0"` flash between PreToolUse and a permission/question prompt. Format:
  `"Ns"` under 60s, `"m:ss"` after (never `"0s"` / `"0:ss"`). Reserve wing
  width via `couldShow` + `AgentElapsedIndicator.reservedWidth` (measured
  `"00:00"`), not via the delayed `isVisible`. During the delay, reserve with
  a clear frame of that width — never a digit `Text` (even `.hidden()` /
  opacity-0), because NotchShape clipping can still leak a lone leading `"0"`
  at the wing edge. **Manager contract**: `present(prompt:)` must set the
  session to `.waitingForInput` (clear busy) for the whole Allow / question
  wait — Cursor's `beforeShellExecution` otherwise stays `runningTool` for
  seconds and the wing can keep a clipped elapsed digit even when the UI
  pending gate fails to refresh.

- **Agent status text**: pending-aware label logic lives only in
  `AgentSessionManager.displayStatusText(for:pending:)` — views (Live Activity,
  Agents panel) pass the pending prompt they already hold instead of re-querying
  the manager or duplicating the switch. Don't reintroduce per-view copies.

- **Brand/provider icons**: prefer bundled monochrome template imagesets over
  approximate SF Symbols (`Assets.xcassets/AgentLogoClaude.imageset`, `AgentLogoCursor.imageset`,
  `Github.imageset`). SVG assets require explicit `width`/`height` attributes on the
  root element (Xcode's asset catalog SVG parser rejects viewBox-only files), plus
  `"template-rendering-intent": "template"` and `"preserves-vector-representation": true`
  in `Contents.json` so `foregroundStyle` tinting works.

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

- **Hand-written `==` on a growing enum** (`SneakContentType` bug, 07-11): a manual
  `static func ==` with a case list + `default: return false` silently breaks when a
  new case is added — `.claudeCode == .claudeCode` returned `false`, so every
  `sneakPeek.type != .claudeCode` exclusion in `ContentView` passed and the generic
  HUD progress branch rendered a bare `"  0"` (`PercentageLabel`, `%3d` of value 0)
  during Claude Code sneak peeks, while the real `== .claudeCode` branch never
  rendered. **Rule**: declare `: Equatable` and rely on compiler synthesis (works
  with associated values); never hand-write `==` for simple enums. If a custom `==`
  is truly needed, it must not have a `default` arm — enumerate all cases so the
  compiler flags new ones.
- **Copy-pasting a Live Activity gating condition** to suppress a related view
  (e.g. sneak peek): extract the condition into one computed property
  (`ContentView.isAgentLiveActivityVisible`) and reference it from the render
  branch and every suppression/size check — two hand-mirrored boolean
  expressions will drift.
- Putting business logic (timers, socket handling, system observation) in the view —
  it belongs in a manager; the view only renders `@Published` state.
- Building a Live Activity without wiring it into `ContentView`'s priority chain.
- Hardcoding notch dimensions instead of reading `vm.closedNotchSize` /
  `vm.effectiveClosedNotchHeight` / `sizing/matters.swift`.
