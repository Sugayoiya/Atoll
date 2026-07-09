# Cursor allowlist 的可读来源（2026-07-09 本机验证）

## 事实

1. Cursor 会话内点一次 Run/同意 **不持久化**，无法读取。只有显式 "Add to allowlist" 的条目才落盘。
2. 持久化来源（按 Cursor 官方优先级，permissions.json 定义了某 key 时完全**取代** UI allowlist，两文件数组**拼接**）：
   - `~/.cursor/permissions.json` —— 全局，key `terminalAllowlist`（字符串数组）。本机当前不存在该文件。
   - `<workspace>/.cursor/permissions.json` —— 按仓库，同上。hook 载荷 `workspace_roots[0]` 可定位 workspace。
   - `state.vscdb`（SQLite）：`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`，表 `ItemTable`，key `src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser`，JSON path `$.composerState.yoloCommandAllowlist`（字符串数组）。同 blob 中还有 `yoloCommandDenylist`、`webFetchDomainAllowlist` 等。本机当前 `yoloCommandAllowlist = []`。
3. 本机验证命令：

```bash
sqlite3 "$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb" \
  "SELECT json_extract(value, '\$.composerState.yoloCommandAllowlist') FROM ItemTable
   WHERE key = 'src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser';"
# 输出: []
```

4. Cursor allowlist 条目语义：命令**前缀**匹配（如条目 `git` 匹配 `git push origin`；条目可以是多词前缀）。复刻时用"按词的前缀匹配"即可（条目按空白分词，命令前 N 个词逐一相等），不要做子串匹配。
5. `state.vscdb` 是 Cursor 进程持有的 SQLite（WAL 模式），**只读打开**（`sqlite3` `SQLITE_OPEN_READONLY` / `mode=ro`）避免锁冲突；读失败要静默降级（视为无 allowlist）。
6. 沙箱注意：Atoll 是 GUI app 无沙箱限制，可直接读上述路径；但要处理文件不存在 / JSON 解析失败。

## 匹配语义建议（Atoll 复刻版）

- 归一化：trim、压缩连续空白后按空格分词。
- 规则 `tokens(rule)` 是命令 `tokens(cmd)` 的前缀（逐词相等）即命中。
- 只做 allow，不复刻 denylist（Cursor 自己的 deny 流程仍然生效——Atoll 不回复时回落原生流程；Atoll 只在"确定放行"时抢答）。

## Swift 侧 SQLite 读取

项目无第三方 SQLite 依赖；用系统 `SQLite3` C 模块（`import SQLite3`，链接 libsqlite3.tbd 通常自动）或直接 `Process` 调 `/usr/bin/sqlite3` 均可。倾向 `SQLite3` C API 只读打开（`sqlite3_open_v2` + `SQLITE_OPEN_READONLY`），单条 query，避免起子进程。

# Atoll 自建规则的现有挂点

- 决策入口：`AgentSessionManager.process(envelope:)` → `provider.promptRequest(for:)` 返回 `.permission(AgentPermissionRequest)` 后才 `present(prompt:)`。自动放行的正确位置：拿到 `AgentPermissionRequest` 后、present 之前 —— 命中规则直接 `request.encodeDecision(.allow(reason:))` 返回，不进 pendingPrompts。
- `AgentPermissionRequest` 已带 `provider` / `toolName` / `inputSummary`，但 `inputSummary` 是截断过的显示文本（120 字符）；匹配需要**完整命令**，需在请求上新增字段（如 `rawCommand: String?`）：
  - Claude：`PermissionRequest` 载荷 `tool_input.command`（Bash）。
  - Cursor：`beforeShellExecution` 载荷 `command`。MCP 事件无 shell 命令，`rawCommand` 为 nil，不参与规则匹配。
- notch 权限 UI（Allow/Deny 按钮）在 `DynamicIsland/components/AgentHooks/NotchAgentsView.swift`；"始终允许"入口加在这里，回调走 `AgentSessionManager`（记规则 + 以 allow 解决当前 prompt）。
- 用户回答入口：`AgentSessionManager.answerPendingPermission(sessionKey:allow:)`，可加平行方法 `alwaysAllowPendingPermission(sessionKey:)`。
- 持久化惯例：Defaults 库；结构化数组用 `Codable` + `Defaults.Serializable`（项目已有先例，见 Constants.swift 中的自定义类型 key）。
