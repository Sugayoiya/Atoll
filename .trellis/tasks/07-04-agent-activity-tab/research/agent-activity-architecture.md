# Agent Live Activity / Tab 机制 / 多 Session 现状调研

## 数据流

hook 脚本（Claude Code / Cursor）→ Unix socket `/tmp/atoll-agent.sock` → `AgentHookSocketServer` → `AgentSessionManager.process()` → Provider `mapEvent()` 归一化为 `AgentEvent`；需要用户决策时 `promptRequest()` 阻塞等待 notch 回复。

## 关键文件

### Agent 链路
- UI（闭合态）：`DynamicIsland/components/AgentHooks/AgentLiveActivity.swift`
- 会话管理：`DynamicIsland/managers/AgentSessionManager.swift`
- 事件模型：`DynamicIsland/services/AgentHooks/AgentEvent.swift`
- Socket 服务：`DynamicIsland/services/AgentHooks/AgentHookSocketServer.swift`
- 信封协议：`DynamicIsland/services/AgentHooks/AgentHookEnvelope.swift`
- Provider 协议：`DynamicIsland/services/AgentHooks/AgentProvider.swift`
- Claude：`.../AgentHooks/Claude/`（Provider、HookInstaller、HookScript、HookResponse、AskUserQuestion、ToolSummary）
- Cursor：`.../AgentHooks/Cursor/`（Provider、HookInstaller、HookScript）
- 挂载点/优先级：`DynamicIsland/ContentView.swift`（约 940 行，Music/Timer/Reminder 之后）
- 设置：`DynamicIsland/models/Constants.swift`（`enableClaudeCodeLiveActivity` 等）、`SettingsView.swift`
- 协议文档：`.trellis/spec/backend/claude-hook-socket-protocol.md`

### Tab 机制
- Tab 枚举：`DynamicIsland/enums/generic.swift`（`NotchViews`）
- Tab 注册/渲染：`DynamicIsland/components/Tabs/TabSelectionView.swift`（功能开关驱动的硬编码 `TabModel` 数组）
- 当前 tab 状态：`DynamicIsland/DynamicIslandViewCoordinator.swift`（`currentView`）
- Tab 栏容器：`DynamicIsland/components/Notch/DynamicIslandHeader.swift`
- 内容切换：`ContentView` 展开态 `switch coordinator.currentView`
- 参考视图：`NotchStatsView.swift`、`NotchTerminalView.swift`
- 宽度计算：`DynamicIsland/sizing/matters.swift`

## 现状要点

1. **闭合态三种 UI 模式**（优先级 question > permission > 状态）：状态图标+文字 / 盾牌+Allow/Deny 圆钮 / 问号+选项 chips。仅 `notchState == .closed` 时渲染。
2. **Hover 痛点根因**：`openNotchOnHover` 时 hover 展开 notch → `AgentLiveActivity` 消失，按钮无法点击；permission 可见时只阻止点击展开、不阻止 hover 展开。
3. **响应链路**：`answerPendingPermission(allow:)` / `answerPendingQuestion(optionLabel:)` → Provider 编码 JSON → socket 回写 → hook stdout。超时 4 秒，超时 `resolvePendingPrompt(with: nil)` 回退终端。
4. **多 session 数据模型已就绪**：`Session.id = "\(provider):\(sessionId)"`（Claude: session_id / Cursor: conversation_id），`sessions: [Session]` 支持并行；但 UI 只展示 `primarySession`（lastUpdated 最新），pending 为**全局单槽**，第二个并发请求直接 nil 放行。
5. **Stale 清理**：5 分钟轮询，1 小时未更新的 session 移除。
6. **Cursor 差异**：只有 permission（beforeShellExecution / beforeMCPExecution），无 question。
7. Sneak peek：busy→waiting 时可弹 3 秒 marquee 提示（`claudeCodeSneakPeekEnabled`）。

## 改造要点（针对本任务）

- 新 `NotchViews` case（如 `.agents`）+ `TabSelectionView` 条件插入（有活跃 session 时）+ `ContentView` switch 新分支
- `AgentSessionManager`：pending 从单槽改为 per-session 字典；prompt 超时参数化（有 pending 时约 60 秒）
- 闭合态 `AgentLiveActivity` 去掉按钮/chips，仅保留状态
- 展开自动切换：有 pending 时 `openNotch()` 后设置 `coordinator.currentView = .agents`
