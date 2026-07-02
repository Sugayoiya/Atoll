# Reusable Logic (View Modifiers & Extensions)

> This is a SwiftUI app, so the reusable-logic unit is the ViewModifier / `View`
> extension, not a React-style hook. There are no project-made property wrappers —
> the only one in use is `@Default` from the Defaults library.

---

## Where Reusable Logic Lives

| Scope | Location | Examples |
|-------|----------|----------|
| App-wide view behavior | `DynamicIsland/extensions/` | `ConditionalModifier.swift` (`.conditionalModifier(_:transform:)`), `View+Parallax3D.swift`, `Button+Bouncing.swift` (`.bouncingStyle(vm:)`), `ActionBar.swift` |
| Feature-scoped modifiers | Inside the feature folder | `PulsingModifier` in `components/Recording/RecordingLiveActivity.swift` (reused by `PrivacyLiveActivity`), `SettingsHighlightModifier` in `components/Settings/SettingsView.swift` |
| Feature-scoped AppKit helpers | Feature folder as `Ext+Type.swift` | `components/Shelf/Ext+NSImage.swift`, `components/Shelf/Ext+NSAlert.swift` |
| View-presenting services | Feature `Services/` exposing a modifier | `components/Shelf/Services/QuickLookService.swift` → `.quickLookPresenter(using:)` |
| Non-SwiftUI helpers used by views | `DynamicIsland/helpers/` | `helpers/LiquidGlassBackground.swift`, `helpers/AccessibilityPermissionStore.swift` |

---

## Conventions

- Extension files are named `Type+Feature.swift` (`NSImage+Extensions.swift`,
  `View+Parallax3D.swift`).
- A modifier used by 2+ features graduates from the feature folder to `extensions/`.
- Expose modifiers through a `View` extension method (`.bouncingStyle(vm:)`), not by
  making callers write `.modifier(...)`.
- Gestures live in `extensions/` too (`PanGesture.swift`); keyboard shortcuts go through
  `extensions/KeyboardShortcutsHelper.swift` (KeyboardShortcuts library).

---

## Common Mistakes

- Writing a new custom property wrapper for settings — use `@Default`.
- Duplicating an effect that already exists in `extensions/` (search for the modifier
  name first — e.g. parallax, bouncing, conditional application are all covered).
- Putting AppKit conveniences in `extensions/` when they're only used by one feature —
  keep them feature-local like Shelf's `Ext+*.swift` files.
