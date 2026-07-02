# Error Handling

> There is no single global error type. The convention depends on which layer the
> code sits in. The unifying rule: **fail loudly at process boundaries, degrade
> gracefully inside the app.**

---

## By Layer

### 1. RPC / XPC / external APIs — structured typed errors

Code that answers external callers must return a structured error response, never crash
or silently drop the request. Pattern (from
`services/Extensions/ExtensionRPCService.swift`):

```swift
do {
    let descriptor = try decoder.decode(...)
    try ExtensionDescriptorValidator.validate(descriptor)
} catch let error as ExtensionValidationError {
    return errorResponse(from: error, id: id)
} catch {
    return errorResponse(code: RPCErrorCode.internalError,
                         message: error.localizedDescription, id: id)
}
```

### 2. Managers with user-visible failures — `LocalizedError` + `@Published lastError`

When the user needs to see why something failed, define a small domain enum conforming
to `LocalizedError` and surface it through a published property
(`managers/AppleNotesSyncManager.swift`: `AppleNotesSyncError` +
`@Published private(set) var lastError: String?`).

### 3. Helpers / private-API bridges — return `nil`, don't throw

Private-framework wrappers return optionals and let callers fall back
(`helpers/DisplayServicesDynamic.swift` `getBrightness` returns `nil` when the symbol is
missing). Small helper-level error enums exist where a reason matters:
`helpers/AppleScriptError.swift`, `helpers/SensorError.swift`.

### 4. Async network / scripting — `async throws`

Newer I/O code uses plain `async throws` and lets the caller decide
(`components/Shelf/Services/LocalSendService.swift` `send(items:) async throws`,
`managers/ImageService.swift` `fetchImageData(from:) async throws`).

---

## Catch-and-Log

The dominant internal style is catch, log via `Logger.log` (see
[Logging Guidelines](./logging-guidelines.md)), and continue with a safe default —
the app must keep running even when one integration breaks
(`managers/WebcamManager.swift`, `managers/BetterDisplayManager.swift`).

`try?` is widespread for genuinely optional operations. That's acceptable **only when
failure is truly ignorable**; if a failure would confuse the user or corrupt state, log it
or surface it.

---

## Common Mistakes

- Throwing from a private-API bridge instead of returning `nil` — callers all over the
  codebase expect the optional-with-fallback contract.
- Using `assertionFailure` for runtime conditions that can happen in release builds
  (`MediaControllers/NowPlayingController.swift` does this for missing resources —
  don't copy it for recoverable states).
- Swallowing decode errors for user data wholesale — decode item-by-item and keep the
  valid entries (`ShelfPersistenceService.swift`).
