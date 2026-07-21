# PRD: Agent 权限 auto-allow（Atoll 自建规则 + 读取 Cursor allowlist）

## 背景

Atoll 的 notch 权限提示（Claude `PermissionRequest`、Cursor `beforeShellExecution`/`beforeMCPExecution`）目前每次都要用户手点 Allow/Deny 或等超时回落。希望：

1. 用户在 notch 上可以"始终允许"某类命令，之后 Atoll 自动秒回 allow；
2. Cursor 侧顺带尊重用户已有的 Cursor allowlist（`permissions.json` / `state.vscdb`），命中直接放行。

前置事实与挂点见 `research/cursor-allowlist-sources.md`（必读）。

## 需求

### A. Atoll 自建 auto-allow 规则（Claude / Cursor 通用）

1. **数据模型**：新增 Defaults key（如 `agentAutoAllowRules`），元素为 Codable 结构：规则文本（词前缀）、provider 归属（`claude` / `cursor` / 通用，MVP 可先只做通用）、创建时间。持久化走 Defaults（遵循 `.trellis/spec/backend/persistence-guidelines.md`）。
2. **匹配语义**：命令归一化（trim + 压缩空白）后按词前缀匹配（规则的每个词与命令前 N 个词逐一相等）。只匹配 shell 命令（Claude Bash / Cursor Shell）；MCP 提示不参与。
   - **复合命令**：先按顶层（不在引号内的）连接符 `&&`、`||`、`;`、`|`、换行 拆分为多段，**每一段都命中某条规则**才整体 allow；任何一段未命中即不抢答（走正常提示）。防止 `git pull && rm -rf ~` 因规则 `git` 被整条放行。
   - **保守拒答**：命令包含命令替换（`$(`、反引号）或进程替换（`<(`、`>(`）时一律不 auto-allow；段内的重定向（`>`、`>>`、`<`）不影响该段匹配（按词分割后重定向词及其后内容不参与前缀比较也可，简单起见：段首词前缀匹配语义不变即可，重定向出现在后部词序列中天然不影响首词前缀规则）。
   - 引号处理：拆分连接符时须忽略单/双引号内部的内容（如 `echo "a && b"` 是一段）；实现一个轻量扫描器即可，无需完整 shell 语法。
3. **规则生成粒度（"智能前缀"）**：点"始终允许"时：
   - 默认取命令**首词**（如 `xcodebuild`）；
   - 若首词属于多子命令工具集合（至少含 `git npm pnpm yarn npx python3 python pip pip3 cargo brew docker kubectl gh make swift xcrun bundle rake`），取**前两词**（如 `git push`）。
   - 集合定义为常量并加注释，便于后续扩展。
4. **决策接入**：`AgentSessionManager.process(envelope:)` 中拿到 `.permission` 请求后、`present` 之前：取完整命令（`AgentPermissionRequest` 新增 `rawCommand: String?` 字段，Claude 从 `tool_input.command`、Cursor 从 `command` 载荷填充），命中规则 → 直接返回 `request.encodeDecision(.allow(reason: "Auto-allowed by Atoll rule"))`，不进 pendingPrompts、不弹 UI。会话状态显示照常（mapEvent 不受影响）。
5. **notch UI**：`NotchAgentsView.swift` 的权限提示区加"始终允许"入口（样式与现有 Allow/Deny 按钮协调，可以是第三个按钮或 Allow 的长按/次级菜单——按现有 UI 风格自行判断，优先简单直接的第三按钮）。点击 → `AgentSessionManager` 新方法：按智能前缀生成规则存入 Defaults + 以 allow 解决当前 prompt。
6. **设置页**：Live Activities 设置区（上个任务加的 "Agent Prompt Timeout" 附近）新增规则管理：
   - 总开关（如 `agentAutoAllowEnabled`，默认开；关掉后规则保留但不生效）；
   - 规则列表（规则文本 + 删除按钮），可全部清空；
   - 文案中英本地化（`Localizable.xcstrings` 只追加，不重排）。

### B. 读取 Cursor allowlist 自动放行（仅 Cursor provider）

1. 新增服务（`services/AgentHooks/Cursor/` 下，如 `CursorAllowlistReader`）聚合三个来源的 `terminalAllowlist` / `yoloCommandAllowlist`：
   - `~/.cursor/permissions.json` 的 `terminalAllowlist`；
   - `<workspace>/.cursor/permissions.json`（workspace 取 hook 载荷 `workspace_roots[0]`，随请求传入）；
   - `state.vscdb` 的 `$.composerState.yoloCommandAllowlist`（SQLite **只读**打开，用系统 `SQLite3` C API；读失败静默返回空）。
2. 语义：来源合并去重；条目按与 A 相同的词前缀匹配。**只做 allow 抢答，不复刻 denylist**（不回复时回落 Cursor 原生流程，deny 由 Cursor 自己执行）。
3. 缓存：按文件 mtime 缓存解析结果，避免每条命令都读 SQLite/JSON；mtime 变化即重读。
4. 开关：设置项（如 `cursorAllowlistAutoAllowEnabled`，默认开，跟随 Cursor 区块展示）。
5. 决策优先级：Atoll 自建规则命中 或 Cursor allowlist 命中 → allow；两者都未命中 → 走现有 notch 提示流程。

## 非目标

- 不做 deny 规则、不复刻 Cursor denylist；
- 不处理 Cursor 的 MCP allowlist（`mcpAllowedTools`）与 web 域名 allowlist；
- 不向 Cursor 的存储写入任何内容（只读）；
- Claude 的 `settings.json permissions.allow` 不读取（PermissionRequest 只在 Claude 要问时触发，allowlist 命令根本不会到达 Atoll，无需求）。

## 验收标准

1. notch 权限提示点"始终允许"后：规则出现在设置页列表；同类命令（同前缀）再次触发时不弹提示、hook 收到 allow 决策；删除规则后恢复弹提示。
2. 在 `~/.cursor/permissions.json` 写入 `{"terminalAllowlist": ["echo hello"]}` 后，Cursor 会话中 `echo hello ...` 命令不弹 notch 提示且被自动放行；文件删除后恢复。
3. `state.vscdb` 不存在 / 被锁 / JSON 结构变化时静默降级为无 allowlist，不崩溃、不刷错误日志（用 `Logger.log` debug 级别记录一次即可）。
4. 总开关关闭后一切恢复现有行为。
5. xcodebuild Debug 编译通过。
