# Quality Guidelines (UI Layer)

> No lint config and no test target exist. Quality bar: builds clean in Xcode,
> follows the conventions below, and UI changes come with screenshots/recordings in
> the PR (per `CONTRIBUTING.md`).

---

## Standards

- Follow Swift API Design Guidelines (project-wide rule from `CONTRIBUTING.md`).
- Keep the GPL header comment block on every new file.
- Feature UI must respect its feature toggle and the minimalistic-UI setting where
  applicable (`Defaults[.enableMinimalisticUI]`).
- Views read sizes from `DynamicIslandViewModel` / `sizing/matters.swift`, never
  hardcoded notch dimensions.
- Accessibility: match macOS Human Interface Guidelines for new surfaces; keep hover/
  click targets consistent with existing components (`components/HoverButton.swift`).

---

## File Size

The codebase tolerates giant files (`SettingsView.swift` 8588 lines,
`ContentView.swift` ~3000, `NotchHomeView.swift` ~1400). **Do not make this worse**:

- New views: aim under ~500 lines; split subviews into their own files in the feature folder.
- When adding to `SettingsView.swift` or `ContentView.swift`, add a small extracted view
  struct rather than inlining another few hundred lines.

---

## Forbidden Patterns

- Business logic in views (timers, sockets, file I/O) — belongs in managers.
- New `@AppStorage` / bare `UserDefaults` in views — use `@Default`.
- New force unwraps.
- New `print` statements in view code — use `Logger.log` (see backend logging spec).
- Duplicating existing modifiers/extensions — search `extensions/` first.
- Creating parallel "fixed" copies of views instead of editing in place.

---

## Review Checklist

- [ ] Builds without new warnings.
- [ ] Live Activity (if any) registered in `ContentView`'s priority chain.
- [ ] Feature fully disappears when its Defaults toggle is off.
- [ ] Animations use `.smooth` unless there's a reason not to.
- [ ] No business logic in the view; state comes from a manager.
- [ ] Screenshots/recording attached to the PR for visual changes.
