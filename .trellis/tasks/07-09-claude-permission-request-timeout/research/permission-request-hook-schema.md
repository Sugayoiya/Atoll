# Claude Code `PermissionRequest` hook — 决策回复格式

来源：https://code.claude.com/docs/en/hooks （2026-07 验证）

## 触发时机
- `PermissionRequest` 只在 Claude Code **即将弹出权限对话框**时触发（即命令没有被 allowlist / permission mode 自动放行）。
- 这与 `PreToolUse` 不同：`PreToolUse` 在**每次**工具调用前触发（含 allowlist 自动放行的调用），且先于权限判定。
- Matcher 语义同 `PreToolUse`（按 `tool_name` 匹配）。
- 输入 stdin JSON 包含：`session_id`, `cwd`, `hook_event_name`, `tool_name`, `tool_input`, `permission_suggestions`。

## 输出（stdout JSON）
与 PreToolUse 的 `permissionDecision` 不同，PermissionRequest 用 `decision.behavior`：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
```

deny 带说明：

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Denied from Atoll notch"
    }
  }
}
```

- `behavior` 只有 `allow` / `deny` 两个值（没有 `ask` —— 不回复即等价于让对话框正常弹出）。
- 可选字段：`updatedInput`（改写工具入参）、`updatedPermissions`（会话内持久化规则，如 `[{"type":"setMode",...}]`）、`message`（deny 原因，回传给 Claude）、`interrupt`。
- 不输出任何内容 / 退出码 0 = 无决策，Claude 正常弹对话框。exit 2 在此事件**不生效**，必须用 JSON。

## 对本任务的意义
- 把 notch 权限提示从 `PreToolUse` 挪到 `PermissionRequest` 后，allowlist 里已放行的命令不再经过 notch 提示（事件根本不触发），彻底消除"本来自动放行却要等提示/超时"的问题。
- `PreToolUse` 仍需保留等待回复的能力：AskUserQuestion 预回答流程依赖 PreToolUse 的 `permissionDecision: allow + updatedInput`（PoC 已验证），不要迁移它。

# 现有超时链（代码事实，2026-07-09）

```
UI 60s < server 65s < script recv 70s < host hook timeout 80s
```

| 环节 | 位置 | 当前值 |
|---|---|---|
| UI 预算 | `AgentSessionManager.promptTimeout` | 60（`private static let`，Task.sleep 后 resolve nil） |
| 服务端 | `AgentHookSocketServer.responseTimeout` | 65（semaphore.wait 上限，超时关连接不回复） |
| 脚本 recv | `ClaudeHookScript.contents` / `CursorHookScript.contents` 内嵌 `sock.settimeout(70)` | 70（写死在生成的脚本文本里） |
| host hook timeout | `ClaudeHookInstaller.hookTimeoutSeconds` / `CursorHookInstaller.permissionEventTimeoutSeconds` | 80（写入 settings.json / hooks.json 的 timeout 字段） |

- 脚本安装是内容比对（`existing != scriptData` 才重写），所以把 recv 超时改成参数化后，改设置 → 重新跑 `installIfNeeded()` 即可自动重写脚本与配置。
- `AgentSessionManager` 已有 Defaults.publisher 监听 enable 开关并调 `installEnabledProviders()`，可在同一处追加对超时 key 的监听。
- Claude 脚本 v5 只在 `PreToolUse` 等待回复；迁移后需同时在 `PermissionRequest` 等待（版本注释 bump 到 v6）。
- Cursor 侧无 PermissionRequest 等价事件，`beforeShellExecution` 行为保持不变。
