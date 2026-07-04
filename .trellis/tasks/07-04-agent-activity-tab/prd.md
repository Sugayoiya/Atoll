# Agent live activity 交互 tab 页与多 session 分离

## Goal

Agent live activity 目前只在闭合 notch 的左右 wing 上展示交互（permission Allow/Deny、question 选项 chips）。用户鼠标移向按钮时，hover 会触发 notch 展开，导致按钮消失、点选困难。目标：新增一个类似终端/系统统计的 Agent tab 页，把交互选项放进展开态的 notch 中供用户操作；同时将多 agent / 多 session 在 UI 上分离展示（当前只显示 primarySession）。

## What I already know

* Agent 数据流：hook 脚本 → Unix socket（/tmp/atoll-agent.sock）→ `AgentHookSocketServer` → `AgentSessionManager` → Provider（Claude/Cursor）归一化为 `AgentEvent`
* 闭合态 UI：`AgentLiveActivity.swift`，仅 `notchState == .closed` 时渲染；三种模式：session 状态 / permission / question
* Hover 展开：`openNotchOnHover` 开启时 hover 即展开 notch，permission 可见时只阻止点击展开、不阻止 hover 展开 → 按钮消失（pending 仍在 manager 中）
* Tab 机制：`NotchViews` 枚举 + `TabSelectionView.tabs`（功能开关驱动的硬编码列表）+ `DynamicIslandViewCoordinator.currentView` + `ContentView` switch 渲染
* 数据模型已支持多 session：`AgentSessionManager.Session`，key = `(provider, sessionId)`；但 UI 只展示 `primarySession`，pending prompt 为全局单槽
* Prompt 超时 4 秒，超时后 agent 回退终端原生流程
* Cursor 暂无 question 支持，只有 permission

## Assumptions (temporary)

* 新 tab 命名类似 "Agents"，跟随功能开关

## Open Questions

（无）

## Requirements (已确认)

* 新增 Agent tab 页（展开态 notch），展示 agent 活动与可交互选项
* 闭合态 wing 只显示状态，不再放 Allow/Deny 按钮和 question chips —— 所有交互移入 tab 页
* 多 session 以列表视图呈现：每行显示 provider、项目、状态；pending 请求内联展开可直接操作
* pending prompt 从全局单槽改为 per-session：多个 session 可同时等待，用户分别响应
* 有 pending 时超时延长（约 60 秒），给用户时间打开 tab 操作；超时仍回退终端原生流程
* Agent tab 仅在存在活跃 session 时出现在 tab 栏（无 agent 时不占空间）
* 存在 pending 请求时，notch 展开（hover 或点击）自动切换到 Agent tab

## Acceptance Criteria

* [ ] 有活跃 agent session 时 tab 栏出现 Agent tab；session 全部结束后消失
* [ ] hover 展开 notch 且有 pending 时自动落在 Agent tab，可直接完成 Allow/Deny 与 question 选项选择
* [ ] 闭合态 wing 只显示状态（图标 + 状态文字 + session 数 badge），无交互按钮
* [ ] 多个 session 同时有 pending 时，tab 列表中可分别响应，互不覆盖
* [ ] pending 超时（约 60 秒）后回退终端原生流程，与现有行为一致
* [ ] Claude 与 Cursor 两个 provider 均正常工作（Cursor 仅 permission）

## Definition of Done

* build / lint 通过
* 相关设置项与 Localizable.xcstrings 本地化字符串更新

## Out of Scope (explicit)

* Cursor 的 question 支持（上游 hook 暂无此能力）
* session 历史记录 / 已结束 session 的回看
* 扩展 tab（extension experience）机制的改造

## Technical Notes

* 关键文件：`DynamicIsland/components/AgentHooks/AgentLiveActivity.swift`、`DynamicIsland/managers/AgentSessionManager.swift`、`DynamicIsland/components/Tabs/TabSelectionView.swift`、`DynamicIsland/DynamicIslandViewCoordinator.swift`、`DynamicIsland/ContentView.swift`、`DynamicIsland/enums/generic.swift`
* 协议文档：`.trellis/spec/backend/claude-hook-socket-protocol.md`
