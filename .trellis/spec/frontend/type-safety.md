# Type Safety (Swift Conventions)

> Enum-driven modes, Codable models with `Defaults.Serializable`, and guard-based
> optional handling.

---

## Enums

- Small settings/mode enums are centralized in `enums/generic.swift` (`NotchViews`,
  `NotchState`, `LockScreenGlassStyle`, `DownloadIndicatorStyle`, …). Most conform to
  `Defaults.Serializable + CaseIterable + Identifiable` so they can be persisted and
  listed in Settings pickers.
- Enums with logic or many members get their own file (`enums/TimerDisplayMode.swift`,
  `String` raw value + `Defaults.Serializable`).
- Associated-value enums are used for UI routing (`SneakContentType` in
  `DynamicIslandViewCoordinator.swift`).

New settings-backed enum → make it `Defaults.Serializable` from the start, or it can't
be stored via `@Default`.

---

## Models

- Persisted models: `Codable + Hashable + Defaults.Serializable`
  (`models/TimerPreset.swift`).
- API-sourced models don't force Codable (`models/EventModel.swift` from EventKit is
  `Equatable + Identifiable`).
- **`models/Constants.swift` is a known grab-bag** (1386 lines: models + Defaults keys +
  global constants). New Defaults keys must go there, but consider a dedicated model file
  for substantial new types.

---

## Optionals

- Managers: `guard let` / early return.
- Views: computed properties guard and return a neutral default
  (`TimerLiveActivity.swift`: `guard showsInfoSection else { return 0 }`).
- **No new force unwraps.** Existing ones (`SettingsView.swift`
  `selectedListVisualizer!`, `DownloadView.swift` `downloadFiles.first!`) are tolerated
  debt; don't extend the pattern.

---

## Access Control

- Default `internal`; views are never `public`.
- Mark helpers embedded in a view file `private`.
- ViewModels that must be main-thread: `@MainActor final class`
  (`components/Shelf/ViewModels/ShelfStateViewModel.swift`).
