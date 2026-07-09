# AskUserQuestion notch 限制可配置化 + multiSelect / 多问题支持

## Goal

Claude Code 的 `AskUserQuestion` 目前只有满足一组硬编码的 MVP 限制（单问题、非 multiSelect、2–4 个选项、单 label ≤16 字符、合计 ≤40 字符）才会进入 notch 的问答流程，否则 `ClaudeAskUserQuestion.parse` 返回 nil，回落到终端提问。这些限制当年是为"闭合 notch 两翼的物理宽度"设计的，但问答 UI 现已迁移到展开态 Agents tab（`NotchAgentsView`），物理约束基本不存在了。本任务：

1. 把长度/选项数限制做成可调设置项（Settings → Claude Code 区域）
2. 放宽默认值以适配展开态 UI
3. 支持 `multiSelect == true` 的问题
4. 支持一次 payload 携带多个问题

## What I already know

- 限制常量在 `DynamicIsland/services/AgentHooks/Claude/ClaudeAskUserQuestion.swift`：
  - `optionCountRange = 2...4`
  - `maxOptionLabelLength = 16`
  - `maxCombinedLabelLength = 40`
  - `questions.count == 1` 硬约束；`multiSelect == true` 直接拒绝
- parse 返回 nil ⇒ hook 不回复 ⇒ Claude 终端正常提问（安全回退，必须保留）
- 回答编码：PreToolUse 回复 `permissionDecision: allow` + `updatedInput`（原 `questions` 原样回显 + `answers: {questionText: label}`）
- UI 在 `DynamicIsland/components/AgentHooks/NotchAgentsView.swift` 的 `questionControls` + `FlowLayoutChips`（目前单行 HStack，点击 label 即答）
- 泛化模型 `AgentQuestionRequest`（`AgentEvent.swift`）目前是单问题、`encodeAnswer: (String) -> Data?`，需要扩展为多问题/多选答案
- 管线：`AgentSessionManager.process` → `present(prompt:)` → `answerPendingQuestion(sessionKey:optionLabel:)`
- 设置开关 `claudeCodeQuestionAnswerEnabled` 在 `models/Constants.swift` + `SettingsView.swift` ~4220 行
- multiSelect 答案格式：Claude 的 answers map 值为逗号连接的多个 label（原代码注释 "comma-joined multi answers deferred"）

## Requirements

- [ ] 新增 Defaults 设置项（`models/Constants.swift`）：
  - 最大选项数（默认放宽，如 6；最少 2）
  - 单 label 最大长度（默认放宽，如 30）
  - 合计 label 最大长度（默认放宽，如 120）
- [ ] Settings UI 暴露这些配置（`claudeCodeQuestionAnswerEnabled` 开关下的子设置，stepper/slider）
- [ ] `ClaudeAskUserQuestion.parse` 改为读取 Defaults 值做 fit-check
- [ ] 支持 multiSelect：UI 上 chip 可多选 + 确认按钮；answers 值为逗号连接 label
- [ ] 支持多问题：一次展示全部问题分组（每题一组 chips），全部作答后统一提交 answers map
- [ ] 超限 payload 仍回落终端（parse 返回 nil），行为不变
- [ ] `AgentQuestionRequest` 泛化为多问题结构，encodeAnswer 接受每题答案集合

## Acceptance Criteria

- [ ] 默认配置下，5 个选项 / 20 字符 label 的单选题可在 notch 作答（旧版会回落终端）
- [ ] 设置里把最大选项数调小后，超限问题回落终端
- [ ] multiSelect 问题可在 notch 勾选多项并提交，Claude 收到逗号连接的答案
- [ ] 多问题 payload 可在 notch 全部作答并一次性提交
- [ ] 项目编译通过（xcodebuild 无错误）

## Out of Scope

- Cursor 侧问答（AskQuestion 走 Cursor 自己的 UI，无 hook 介入点）
- ExitPlanMode 等其他工具的 notch 化
- 闭合 notch 两翼上直接答题（仍只在展开态 Agents tab 作答）

## Decision (ADR-lite)

**Context**: 限制源于旧的闭合 notch 两翼展示，UI 已迁移到展开态 tab。
**Decision**: 用户选择「全部可调 + 放开 multiSelect / 多问题」（AskQuestion 表单选项 all-plus）。
**Consequences**: `AgentQuestionRequest` 从单题单答泛化为多题多答，`answerPendingQuestion` 与 UI 需要引入本地选择状态和提交动作；回退路径（parse nil → 终端）保持不变以保证安全。

## Technical Notes

- 关键文件：
  - `DynamicIsland/services/AgentHooks/Claude/ClaudeAskUserQuestion.swift`（parse + updatedInput）
  - `DynamicIsland/services/AgentHooks/Claude/ClaudeProvider.swift`（promptRequest 组装）
  - `DynamicIsland/services/AgentHooks/AgentEvent.swift`（AgentQuestionRequest 泛化）
  - `DynamicIsland/managers/AgentSessionManager.swift`（answerPendingQuestion）
  - `DynamicIsland/components/AgentHooks/NotchAgentsView.swift`（questionControls / FlowLayoutChips）
  - `DynamicIsland/models/Constants.swift` + `components/Settings/SettingsView.swift`（设置项）
- spec 参考：`.trellis/spec/backend/claude-hook-socket-protocol.md`（回复 schema / 超时链）

## Confirmed Decisions

- 提交交互：multiSelect / 多问题使用显式"提交"按钮（单问题单选保持点击即答）；提交按钮在所有问题均已作答前禁用
- 新默认限制值：最大选项数 6、单 label ≤30 字符、合计 ≤120 字符（设置里可调）
