# PRD: Claude 权限提示改挂 PermissionRequest + 提示超时可配置

## 背景

当前 Atoll 的 Claude Code notch 权限提示挂在 `PreToolUse` 上（`ClaudeProvider.permissionPromptTools = ["Bash"]`）。`PreToolUse` 先于 Claude 自身的权限判定、对每条 Bash 命令都触发，导致 **allowlist 里本来自动放行的命令也会弹 notch 提示**，用户不响应时最坏被拖 ~60 秒才回落到正常流程。

同时，提示的 UI 等待时间（60s）是写死的常量，用户无法调整。

## 需求

### A. Claude 权限提示迁移到 `PermissionRequest` 事件

1. `ClaudeProvider.promptRequest` 中的 **permission prompt** 从 `PreToolUse` 事件迁移到 `PermissionRequest` 事件派生。
   - `PermissionRequest` 只在 Claude 确实要弹权限对话框时触发，allowlist 放行的命令不会经过 notch。
   - 保留 `permissionPromptTools`（Bash）过滤和 `claudeCodePermissionPromptEnabled` 开关语义不变。
   - `PermissionRequest` 的 stdin 输入包含 `tool_name` / `tool_input`，摘要生成沿用 `ClaudeToolSummary.permissionSummary`。
2. 决策回复改用 PermissionRequest 专属 schema（见 `research/permission-request-hook-schema.md`）：
   - allow → `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
   - deny → `decision.behavior: "deny"` + `message`
   - ask/超时/无决策 → 不回复（对话框正常弹出）。
   - `ClaudeHookResponse` 需要支持这个新形状（现有形状是 PreToolUse 的 `permissionDecision`，AskUserQuestion 流程仍在用，不能删）。
3. **AskUserQuestion 预回答流程保持在 `PreToolUse` 上不动**。
4. `ClaudeHookScript`：等待决策回复的事件从仅 `PreToolUse` 扩为 `PreToolUse` + `PermissionRequest`；脚本版本注释 bump（v5 → v6）。
5. `ClaudeProvider.mapEvent` 对 `PermissionRequest` 的显示映射（`.permissionRequested`）保持。

### B. 提示等待时间（UI 预算）在设置页可配置

1. 新增 Defaults key（`models/Constants.swift`），如 `agentPromptTimeoutSeconds`：`Double`，默认 60，供 Claude 与 Cursor 共用。
2. 超时链各环节由该值派生，保持链不变式 `UI < server(+5) < script recv(+10) < host hook timeout(+20)`：
   - `AgentSessionManager.promptTimeout` → 读 Defaults（在 schedule 时读取即可，不必缓存）。
   - `AgentHookSocketServer.responseTimeout` → UI + 5。
   - `ClaudeHookScript` / `CursorHookScript` 的 `sock.settimeout(...)` → UI + 10（脚本内容参数化生成）。
   - `ClaudeHookInstaller.hookTimeoutSeconds` / `CursorHookInstaller.permissionEventTimeoutSeconds` → UI + 20。
3. 设置值变化时自动重装 hook（脚本内容与配置里的 timeout 都要更新）：
   - `AgentSessionManager` 已有 `Defaults.publisher(keys: ...)` 监听 enable 开关并调 `installEnabledProviders()`；把新 key 加入监听（或等效机制）。
   - 安装器本身已做内容比对，重跑 `installIfNeeded()` 即幂等生效。
4. 设置 UI（`components/Settings/SettingsView.swift` 中现有 Claude Code / Cursor Live Activity 区域）：
   - 增加一个数值控件（slider 或 stepper + 数值显示），范围 10–300 秒，步进 5。
   - 因为该值 Claude/Cursor 共用，放在两个 provider 区块都能被理解的位置（实现时参考现有 UI 布局决定放一处还是两处引用同一 key）。
   - 文案需要中英文本地化（`Localizable.xcstrings`），风格与相邻设置项一致。

## 非目标

- 不改 Cursor 的 `beforeShellExecution` 提示时机（Cursor 无 PermissionRequest 等价事件）。
- 不扩大 Claude 提示的工具范围（仍仅 Bash）。
- 不做"Atoll 端本地 allowlist"。

## 验收标准

1. Claude：allowlist（如 `Bash(xcodegen *)`）里的命令执行时 notch 不再弹权限提示、无额外阻塞；非 allowlist 的 Bash 命令在 notch 弹 Allow/Deny，Allow/Deny/超时行为分别为放行/拒绝/回落原生对话框。
2. 设置页可调超时，改动后重跑安装（自动），`~/.claude/settings.json`、hook 脚本、Cursor `hooks.json` 中的超时随之更新且保持链不变式。
3. 项目能通过 xcodebuild 编译（无测试 target；lint 无 SwiftLint）。
