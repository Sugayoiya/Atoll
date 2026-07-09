# Agent live activity: cap panel width + fix provider icons

## Goal

修复 closed-notch Agent live activity 的两个显示问题：

1. 状态文本过长时面板（左右 wing）被撑得太宽，导致 notch 背景形状的左右圆角消失。
2. Provider 图标不对：Cursor 用的 SF Symbol `cursorarrow.rays` 不是 Cursor 官方 logo；Claude 用的 `asterisk` 与官方星芒 logo 接近但非官方图形。

## What I already know

- `DynamicIsland/components/AgentHooks/AgentLiveActivity.swift`：
  - `maxStatusTextWidth = 160` 只限制 Text 本身；右翼宽度 = 文本 + pending 图标(19) + 多会话徽章 + elapsed 计时(约35) + padding(34)，可达 ~250pt。
  - `wingWidths` 会把左右翼取 max 对称加宽（保证黑色中段对准物理 notch），所以总宽 ≈ notch 宽 + 2×右翼宽，长文本时超出窗口可用宽度 → 外层 NotchShape 被裁切，圆角消失。
- 图标定义：
  - `services/AgentHooks/Cursor/CursorProvider.swift` → `iconName = "cursorarrow.rays"`
  - `services/AgentHooks/Claude/ClaudeProvider.swift` → `iconName = "asterisk"`
  - `AgentProvider.iconName` 协议注释写明是 SF Symbol，`AgentLiveActivity` 用 `Image(systemName:)` 渲染。
  - `ContentView.swift` 约 L1053 的 claudeCode sneak peek 也硬编码 `Image(systemName: "asterisk")`。
- `Assets.xcassets` 已有品牌类 imageset 先例（`Github.imageset`、`LinkedIn.imageset`、`LocalSend.imageset`、`chrome.imageset`），可按同样方式加 `CursorLogo` / `ClaudeLogo` template 图。

## Requirements (evolving)

- R1: 限制 AgentLiveActivity 总宽度，保证在任何状态文本长度下 notch 背景左右圆角完整（按可用窗口宽度/更小的文本上限收紧，超出部分继续尾部截断）。
- R2: Cursor live activity 使用 Cursor 官方 logo（template 渲染，跟随 accent 着色）。
- R3: Claude live activity 使用 Claude 官方星芒 logo（template 渲染）；同时替换 sneak peek 中硬编码的 `asterisk`。
- R4: `AgentProvider` 图标机制需支持 asset image（不再只支持 SF Symbol）。

## Acceptance Criteria

- [ ] 超长 tool summary / prompt preview 下，面板圆角不消失。
- [ ] closed notch 上 Cursor 会话显示 Cursor 官方 logo，Claude 会话显示 Claude 官方 logo。
- [ ] 图标随 provider accent 颜色着色，busy 脉冲动画行为不变。
- [ ] 编译通过（xcodebuild），无新增告警。

## Decision (ADR-lite)

- **图标**：内置官方 logo 资源（Cursor + Claude 单色 template imageset，随 accent 着色），与 `Github.imageset` 等既有品牌图标先例一致。`AgentProvider` 增加 asset image 支持。SVG 来源 simple-icons（`claude`、`cursor`），Xcode 12+ 资源目录原生支持 SVG（勾选 Preserve Vector Data / template rendering）。
- **宽度**：右翼宽度按 notch 窗口可用宽度动态钳制（总宽 = 左右翼 + notch 宽不得超过窗口可容纳的最大宽度，保留圆角所需边距），文本尾部截断；`maxStatusTextWidth` 变为动态上限的组成部分而不是唯一约束。

## Out of Scope

- 展开态 Agents tab 的 UI 改动。
- 多会话切换逻辑。

## Technical Notes

- 已检查文件：`AgentLiveActivity.swift`、`CursorProvider.swift`、`ClaudeProvider.swift`、`AgentProvider.swift`、`ContentView.swift`（closed live activity 分支 + sneak peek 分支）。
- 品牌 SVG 可取自 simple-icons（Claude、Cursor 均有收录），转成单色 template PDF/PNG 放入 Assets.xcassets。
