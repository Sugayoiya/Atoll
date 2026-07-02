# Directory Structure (System Layer)

> Where non-UI code lives in `DynamicIsland/` and what each folder means.

---

## Folder Map

| Directory | Role | Examples |
|-----------|------|----------|
| `DynamicIsland/managers/` | App-level singletons: coordinators, system observers, window managers, feature state machines (~64 files) | `managers/TimerManager.swift`, `managers/SystemHUDManager.swift`, `managers/ClaudeCodeManager.swift` |
| `DynamicIsland/managers/Extensions/` | Managers for the third-party extension system | `managers/Extensions/ExtensionLiveActivityManager.swift` |
| `DynamicIsland/services/` | Cross-process / network infrastructure (sockets, XPC, WebSocket RPC) | `services/ClaudeCode/ClaudeHookSocketServer.swift`, `services/Extensions/ExtensionXPCServiceHost.swift`, `services/Extensions/ExtensionRPCServer.swift` |
| `DynamicIsland/helpers/` | Low-level building blocks without UI: private-API bridges, permission stores, script runners | `helpers/DisplayServicesDynamic.swift`, `helpers/CoreBrightnessDisplayClient.swift`, `helpers/AppleScriptRunner.swift` |
| `DynamicIsland/utils/` | Hardware/system metrics and the shared logger | `utils/SMC.swift`, `utils/IOReportBridging.swift`, `utils/Logger.swift` |
| `DynamicIsland/MediaControllers/` | Adapter layer implementing `MediaControllerProtocol`, selected by `MusicManager` | `MediaControllers/AppleMusicController.swift`, `MediaControllers/NowPlayingController.swift` |
| `DynamicIsland/observers/` | Passive system detectors | `observers/FullscreenMediaDetection.swift` |
| `DynamicIsland/audio/` | C++/ObjC++ audio processing plus Swift capture | `audio/AudioTap.swift`, `audio/AudioBridge.mm`, `audio/AudioProcessor.cpp` |
| `DynamicIsland/Providers/` | Protocol + implementation pairs (Calendar) | `Providers/` |
| `DynamicIsland/components/<Feature>/Services/` | Feature-scoped stateless I/O helpers serving one UI feature only | `components/Shelf/Services/ShelfPersistenceService.swift`, `components/Shelf/Services/LocalSendService.swift` |

---

## Manager vs Service vs Helper — Decision Rules

**Create a Manager** (`managers/<Feature>Manager.swift`) when the code:
- Holds `@Published` state consumed by SwiftUI views or drives a Live Activity.
- Runs for the app's lifetime and subscribes to `Defaults.publisher` / `NotificationCenter`.
- Pattern: `static let shared` + `private init()`; start/stop driven by a Defaults toggle
  (`managers/ClaudeCodeManager.swift` watches `.enableClaudeCodeLiveActivity`).
- When it needs the coordinator or view model, add an explicit `configure(...)` method instead
  of init injection (`SystemHUDManager.setup(coordinator:)`, `LockScreenManager.configure(viewModel:)`).

**Create a Service** (`services/<Domain>/...`) when the code sits at a process or network
boundary: it listens on a socket/XPC/WebSocket and encodes/decodes messages. Services do not
hold SwiftUI state; they call back into a manager which updates the UI
(`ClaudeHookSocketServer` → callback → `ClaudeCodeManager`).

If the service exists only to support one UI feature, keep it inside that feature's folder
instead: `components/Shelf/Services/`.

**Create a Helper/Util** when the code is a small building block used by managers/services:
- Private-framework `dlopen`/`dlsym` wrappers → `helpers/` (`DisplayServicesDynamic.swift`).
- Hardware/IO metrics → `utils/` (`SMC.swift`, `CPUSensorCollector.swift`).

---

## Startup Wiring

All long-lived managers are booted from `AppDelegate.applicationDidFinishLaunching` in
`DynamicIsland/DynamicIslandApp.swift`: XPC/RPC services start, Defaults migrations run,
HUD subsystem is set up, and conditional managers (`ScreenRecordingManager`,
`PrivacyIndicatorManager`, `AudioTap`) start based on Defaults toggles. When adding a new
manager that must run at launch, wire it there — do not add ad-hoc bootstrapping in views.

Some managers self-start lazily instead: they subscribe to their feature toggle in `init`
and call `start()/stop()` on change (`ClaudeCodeManager`, `SystemHUDManager`). Prefer this
pattern for optional features so disabled features cost nothing.

---

## Private API Isolation

Private frameworks are never called from managers directly. The local pattern:

- Wrap `dlopen`/`dlsym`/`CFBundleGetFunctionPointerForName` in a dedicated helper that
  returns optionals and degrades gracefully (`helpers/DisplayServicesDynamic.swift`,
  `utils/IOReportBridging.swift`, `MediaControllers/NowPlayingController.swift`).
- C++ code is bridged through an ObjC++ shim (`audio/AudioBridge.mm` wraps
  `audio/AudioProcessor.cpp`; Swift only touches `AudioBridge`).
- Managers consume the wrapper's optional results and fall back to defaults + a log line.

---

## Anti-Patterns (present in the codebase — do not add more)

- `managers/ImageService.swift` — a URLSession layer named "Service" living in `managers/`.
  New network code should follow the naming/location rules above.
- `managers/ColorPickerManager_Fixed.swift` — a leftover file (now just the license header)
  from a `_Fixed` copy of `ColorPickerManager.swift`. Never create `_Fixed` / `_New`
  copies; edit in place.
- Giant manager files (`managers/MusicManager.swift` ~1800 lines). Split responsibilities
  before a manager reaches this size.
