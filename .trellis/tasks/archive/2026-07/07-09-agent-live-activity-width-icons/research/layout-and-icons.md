# Agent live activity: width overflow analysis + brand icon sourcing

## 1. Why the rounded corners disappear

`DynamicIsland/components/AgentHooks/AgentLiveActivity.swift`:

- Total view width = `wings.left + vm.closedNotchSize.width + wings.right` (line ~73).
- `wingWidths(for:)` balances both wings to `max(leftWingWidth, rightWingWidth)` so the
  black center stays aligned with the physical notch. A long status text therefore
  widens BOTH wings.
- `rightWingWidth(for:)` = `wingPadding(16) + min(textWidth, 160) + pending icon(19)
  + elapsed "00:00"(~35) + badge + 18`, floor 76 → can reach ~250pt per wing.
- The hosting notch window is sized elsewhere (see `DynamicIslandApp.swift` window
  frame; closed hover width is roughly `closedNotchSize.width + some slack`). When the
  live activity's total width exceeds the width the outer `NotchShape` background is
  drawn at, the shape's left/right bottom-corner curves get pushed out of the window /
  covered by content → "corners disappear".

### Fix direction (decided)

Dynamically clamp the right-wing width so that
`2 * wing + closedNotchSize.width <= available window content width - corner slack`.

Relevant facts:

- The closed-notch hosting window width: check `DynamicIslandApp.swift` around
  `window.setFrame` (~L392, L562) and how ContentView frames the closed notch
  (`vm.closedNotchSize`, `openNotchSize` from `sizing/matters.swift`).
- Corner radii come from `cornerRadiusInsets.closed = (top: 6, bottom: 14)`
  (`sizing/matters.swift` L159). Leave at least `bottom` radius worth of slack per side.
- Simplest robust approach: compute `maxWingWidth = max(76, (maxTotalWidth - closedNotchSize.width) / 2)`
  where `maxTotalWidth` derives from the actual window/screen constraint (e.g.
  `openNotchSize.width` or the hosting window width), then clamp both the measured
  wing width AND the `Text.frame(maxWidth:)` (text max = wing - fixed elements) so
  measurement and rendering agree. Keep tail truncation.
- Note `MusicLiveActivity` / other live activities for precedent on sizing against
  `vm.closedNotchSize`.

## 2. Brand icons

Current state:

- `AgentProvider.iconName` is documented as an SF Symbol; rendered with
  `Image(systemName:)` in `AgentLiveActivity.iconSection` (15pt bold, tinted with
  provider accent, pulsing opacity when busy).
- `CursorProvider.iconName = "cursorarrow.rays"` (wrong brand mark),
  `ClaudeProvider.iconName = "asterisk"` (approximation).
- `ContentView.swift` ~L1053: sneak peek branch hardcodes `Image(systemName: "asterisk")`.

Decision: bundle official monochrome logos as template imagesets, following the
existing precedent (`Assets.xcassets/Github.imageset`, `LinkedIn.imageset`,
`LocalSend.imageset`, `chrome.imageset` — check one of their Contents.json for the
template-rendering setup).

SVG sources (simple-icons, CDN allowed via jsdelivr/GitHub):

- Claude: https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/claude.svg
- Cursor: https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/anthropic.svg ← WRONG, use:
  https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/cursor.svg
  (verify slug exists; fallback: https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/cursor.svg)

Asset catalog notes:

- Xcode supports SVG in imagesets: `Contents.json` with `"properties": {"preserves-vector-representation": true, "template-rendering-intent": "template"}`.
- Name suggestions: `AgentLogoCursor`, `AgentLogoClaude`.

API change:

- Replace `iconName: String` (SF Symbol) with something like
  `enum AgentProviderIcon { case system(String); case asset(String) }` or add an
  optional `iconAssetName: String?` that wins over `iconName`. Update
  `AgentLiveActivity.providerIconName` usage and the sneak peek hardcoded asterisk
  (route it through the provider too, or use the Claude asset directly since the
  sneak peek type is `.claudeCode`).
- Check for other render sites of `iconName`: `NotchAgentsView` (expanded Agents tab)
  may also render provider icons — grep `provider(for:` / `iconName` before changing.
