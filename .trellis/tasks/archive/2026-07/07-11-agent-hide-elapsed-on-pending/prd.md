# Suppress 0:00 elapsed flash before Claude allow prompt

## Goal

Claude 需要 Allow 时，闭合刘海 Agent Live Activity 右侧总会先闪出 `0:00`（远看像 “0”），随后才出现盾牌/Waiting。消除这个误导性闪烁。

## Root Cause (confirmed by hook traffic log)

`/tmp/atoll-agent-hooks.log` 实测时序（2026-07-11 02:54:52）：

1. `PreToolUse` → `runningTool(Bash)`，`primaryBusy=true` → elapsed 计时器立即渲染，起始 `0:00`（`statusChangedAt` 刚重置）。
2. 同秒（或 1-2 秒后）`PermissionRequest` → `waitingForInput`，`primaryBusy=false` → 计时器消失，橙色盾牌 + Waiting 出现。

等待 Allow 期间本身没有计时器；用户看到的 “0” 是第 1→2 步之间那一闪的 `0:00`。凡是需要 allow 的命令都必先经过 PreToolUse，所以每次都能看到。

## Requirements

* elapsed 计时器不再在状态刚切换时立刻显示：当前状态持续 ≥ 一个阈值（建议 2s）后才出现，之后按现有 `m:ss` 格式继续。
* 阈值逻辑同时应用于闭合刘海（`AgentLiveActivity`）与展开 Agents 面板（`NotchAgentsView`），单处实现两处复用。
* 有 pending prompt（permission / question）时不显示 elapsed（当前 permission 已因 `waitingForInput` 天然隐藏；question 挂在 PreToolUse 上仍是 busy，需要显式隐藏）。
* 右翼宽度测量（`fixedRightWingWidth`）与显示条件保持一致，避免文字被裁。

## Follow-up (confirmed via live repro screenshot 2026-07-11 11:27)

用户看到的 “0” 实为忙碌状态下 elapsed 计数器的 `0:xx` 前导零（暗色 10pt，远看只剩 “0”）。追加需求：

* `AgentElapsedIndicator.elapsedText` 改格式：< 60s 显示 `Ns`（如 `4s`、`12s`），≥ 60s 恢复 `m:ss`（如 `1:02`）。
* 宽度预留（`fixedRightWingWidth` 的 `"00:00"` 样本）保持不变即可——`59s` 比 `00:00` 窄。

## Acceptance Criteria

* [ ] Claude Bash 需要 Allow 时，PreToolUse→PermissionRequest 之间不再闪 `0:00`。
* [ ] AskUserQuestion 等待回答期间不显示 elapsed。
* [ ] 长时间忙碌（thinking / 跑工具 / compacting ≥ 阈值且无 pending）时 elapsed 照常显示并走秒。
* [ ] Build green。

## Definition of Done

* xcodebuild 构建绿色
* 若形成新约定，更新 `.trellis/spec/`

## Out of Scope

* 会话数徽标（如 “5”）的清理策略
* hook 诊断日志（本任务顺带引入，保留）
* Cursor provider 独立 UX 改版（同源逻辑自然覆盖）

## Technical Notes

* `AgentLiveActivity.statusSection`：`if session.status.isBusy { elapsedIndicator }`；`elapsedText(since: session.statusChangedAt)`
* `NotchAgentsView.AgentSessionRow.elapsedIndicator`：同样逻辑
* 显示条件建议：`status.isBusy && pendingPrompt == nil && now - statusChangedAt >= 2s`（TimelineView 内每秒重估即可）
* `fixedRightWingWidth(for:)` 中 elapsed 预留宽度需与新显示条件同步
* 诊断日志：`AgentSessionManager.logHookTraffic` → `/tmp/atoll-agent-hooks.log`
