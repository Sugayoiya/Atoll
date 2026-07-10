# Improve agent live activity status readability for injected/system prompts

## Goal

Claude Code 会通过 `UserPromptSubmit` 注入机器消息（后台任务通知、命令回显、system-reminder 等），目前刘海实时活动把原始 XML 标签当作 prompt 预览展示。本任务把这些注入消息识别并语义化，让用户直观感受到 agent 正在做什么，而不是看到 `<task-notification> <task-id>…` 这类标签串。

## Requirements

* 识别已知的机器注入前缀族：`<task-notification>`、`<command-name>`、`<bash-input>`、`<local-command-stdout>`、`<system-reminder>`（可扩展的枚举/映射表）。
* 语义化展示（Decision: 方案 A）：
  * `<task-notification>`：解析 `status` 与 `<summary>`，显示如「后台任务完成 · Background command "sleep 30" completed (exit 0)」；解析失败时回退为「后台任务通知」。
  * 其他前缀给对应语义标签（如「执行本地命令」「命令输出」「系统提醒」），有可读正文则附摘要。
  * 无法归类但以 `<` 开头且形似标签的 prompt：剥离标签取可读文本；仍为空则回退 `Thinking…`（不设置 promptPreview）。
* 人类输入的 prompt 行为完全不变。
* 闭合刘海右翼与展开 Agents 面板使用同一份语义化结果（单处解析，两处消费）。
* 解析逻辑为纯函数并配单元测试（容错：该 XML 无官方 schema，字段缺失/顺序变化不得 crash）。

## Acceptance Criteria

* [ ] 后台任务完成触发 task-notification 时，刘海显示语义化状态（含 summary/exit code），无原始 XML 标签。
* [ ] 前缀族内其他注入消息均显示语义标签而非标签串。
* [ ] 普通用户 prompt 预览行为与现状一致。
* [ ] 解析单测覆盖：完整消息、缺 summary、缺 status、非法/截断 XML、普通 prompt 不受影响。
* [ ] Build / lint green。

## Definition of Done

* 单元测试通过；xcodebuild 构建绿色
* 若形成新约定（注入消息解析规范），更新 `.trellis/spec/`

## Decision (ADR-lite)

**Context**: 注入消息如何展示——直接过滤太武断，用户希望更好地感知 agent 行为。
**Decision**: 语义化展示（方案 A），覆盖整个已知前缀族；解析失败逐级回退（语义标签 → 剥标签文本 → Thinking…）。
**Consequences**: 需要维护前缀映射表；XML 格式无官方保证，解析必须容错，格式变化时最坏回退到 Thinking… 不会展示垃圾文本。

## Out of Scope

* Cursor provider 的注入消息（未观察到类似行为，留待出现时扩展）。
* 展开面板的更多信息层级（如点开看完整通知内容）。
* 对 elapsed 计时器 / 其他状态展示的改动。

## Technical Notes

* 解析入口：`DynamicIsland/services/AgentHooks/Claude/ClaudeProvider.swift` `mapEvent` 的 `UserPromptSubmit` 分支（当前直接 `prefix(200)`）。
* 展示消费方：`AgentSessionManager.Session.promptPreview` → `AgentLiveActivity.statusText` / `NotchAgentsView`。
* 建议新增纯函数 helper（如 `ClaudeInjectedPrompt.classify(_:)`），与 `ClaudeToolSummary` 同层。
* 注入消息样例与字段语义见 research。

## Research References

* [`research/claude-injected-prompts.md`](research/claude-injected-prompts.md) — task-notification 完整结构（task-id / tool-use-id / status / 人类可读 summary）；hook 载荷无机器/人类标志，只能前缀识别；社区工具同样用前缀嗅探且需容错。
