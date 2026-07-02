# Persistence Guidelines

> Atoll has **no database** — no Core Data, SQLite, GRDB, or Realm. Persistence is
> the Defaults library for settings and JSON files in Application Support for
> structured data. Do not introduce a database without a team decision.

---

## Settings: the Defaults library (primary)

- **All keys are defined in one place**: `extension Defaults.Keys` in
  `DynamicIsland/models/Constants.swift`. Add new keys there, never in a feature file.
- Custom stored types must conform to `Defaults.Serializable` (see the enums in
  `DynamicIsland/enums/generic.swift` and `models/TimerPreset.swift`).
- Read/write imperatively with `Defaults[.someKey]`.
- React to changes with Combine: `Defaults.publisher(.someKey, options: []).sink { ... }`
  (see `models/DynamicIslandViewModel.swift` and `AppDelegate` in `DynamicIslandApp.swift`).
- In SwiftUI, bind with `@Default(.someKey)`.
- Key migrations live next to the keys as static helpers and run from
  `applicationDidFinishLaunching` (e.g. `Defaults.Keys.migrateProgressBarStyle()`).

**Do not** add new `@AppStorage` properties or bare `UserDefaults.standard` keys.
Legacy ones exist (`DynamicIslandViewCoordinator.swift`, `managers/ColorPickerManager.swift`
`"ColorPickerHistory"`, `managers/TimerManager.swift` `"customTimerSoundPath"`) but new
settings must go through Defaults so they get publisher support and centralized keys.

Reading *another app's* preferences via `UserDefaults(suiteName:)` is fine — that's an
integration, not our persistence (`managers/LunarManager.swift`,
`managers/BluetoothAudioManager.swift`).

---

## Structured Data: JSON in Application Support

For lists/records too big for Defaults, write Codable JSON under
`~/Library/Application Support/DynamicIsland/<Feature>/`:

- Shelf items: `components/Shelf/Services/ShelfPersistenceService.swift`
  (`Shelf/items.json`, decodes item-by-item and drops corrupt entries instead of failing the whole file).
- Custom idle animations: `managers/IdleAnimationManager.swift`.
- Note images: `NoteItem` helpers in `models/Constants.swift`.
- Extension event snapshots: `services/Extensions/ExtensionEventBridge.swift`.

Caches go to the Caches directory instead (`managers/ImageService.swift` artwork cache).

For retaining access to user-picked files across launches, use security-scoped bookmarks
(`components/Shelf/Models/Bookmark.swift`).

---

## Other Persistence-Adjacent Paths

- Unix socket for Claude Code hooks: `/tmp/atoll-claude.sock`
  (`services/ClaudeCode/ClaudeHookSocketServer.swift`) — ephemeral, not persistence.

---

## Common Mistakes

- Defining a Defaults key inside a feature file — keys become undiscoverable; always
  extend `Defaults.Keys` in `models/Constants.swift`.
- Persisting large blobs in Defaults — use Application Support JSON or files.
- Failing an entire JSON load because one record is corrupt — follow
  `ShelfPersistenceService`'s per-item decode-and-skip pattern.
