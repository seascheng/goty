# codex app-server 协议覆盖审计

基线:codex-rs `app-server-protocol/schema/typescript`(ServerRequest.ts ×10,
ServerNotification.ts ×83)+ paseo `codex-app-server-agent.ts` handler 全集。
goty 实现:`CodexSession`(连接/生命周期/RPC)+ `CodexFrameMapper`(通知→事件)。
审计日期:2026-09-14。

## Server requests(10)

| 方法 | paseo | goty | 说明 |
|---|---|---|---|
| item/commandExecution/requestApproval | ✓ | ✓ allow/decline | 待补 acceptForSession 选项 |
| item/fileChange/requestApproval | ✓ | ✓(suffix 分支) | 同上 |
| item/tool/requestUserInput | ✓ | ✓(suffix 兜底) | question 形状未细化(低频) |
| mcpServer/elicitation/request | ✓ | 兜底 allow/decline | 够用 |
| item/permissions/requestApproval | ✗ | 兜底 | — |
| item/tool/call (DynamicToolCall) | ✗ | respond {} | 高级特性,不做 |
| account/chatgptAuthTokens/refresh | ✗ | respond {} | auth 托管,不做 |
| attestation/generate | ✗ | respond {} | 不做 |
| applyPatchApproval / execCommandApproval | ✗ | ✗ | legacy(0.15x 前残留) |

## Notifications(83)— 按 GUI 相关性

### 已覆盖
error / thread/started / thread/status/changed(waitingOnApproval 闪现) /
turn/started / turn/completed / item/started / item/completed /
item/agentMessage/delta / item/reasoning/summaryTextDelta /
item/reasoning/textDelta / item/commandExecution/outputDelta /
thread/tokenUsage/updated / serverRequest/resolved(收回权限卡) /
thread/name/updated(sessionTitle) / warning / guardianWarning / configWarning(notice) /
skills/changed(重拉 skills/list) / turn/plan/updated(plan 卡) /
turn/aborted(mapper→interrupted) / deprecationNotice / remoteControl/status/changed /
mcpServer/startupStatus/updated(忽略) / hook/started / hook/completed(忽略)

### 已知未覆盖(评估后搁置)
- item/reasoning/summaryPartAdded — part 边界,thoughtChunk 连续流不需要
- item/fileChange/outputDelta / patchUpdated — 编辑流(当前 fileChange 卡够用;大 diff 流待需要时补)
- item/plan/delta — EXPERIMENTAL(schema 自注:拼接不保证与 completed 一致)
- thread/compacted — deprecated(schema 注:用 ContextCompaction item,已覆盖)
- thread/goal/updated / thread/goal/cleared — goal 状态显示(计划中)
- thread/queue/changed — 队列 UI(计划中)
- account/rateLimits/updated / account/updated — 限额显示(低)
- item/autoApprovalReview/* / autoApprovalReview/strictReviewRequired — 低
- rawResponse* — 调试负载,不做
- thread/realtime/*(×11)— 语音,不做(产品范围外)
- mcpServer/event/stream、fuzzyFileSearch/*、externalAgentConfig/*、
  windows*、windowsSandbox/*、modelProvider/authRecovery*、model/*、
  process/*、fs/changed、project/*、thread/environment/*、
  thread/settings/updated、thread/archived|deleted|unarchived|closed|reverted
  — IDE/托管场景,会话列表轮询已覆盖可见性,不做
- turn/diff/updated — turn 级 diff 汇总(fileChange item 已逐个显示)
- turn/moderationMetadata / model/safetyBuffering/updated — 低
- app/list/updated、account/login/completed — 低

## 回归钉子

- agenttest:ring 重放 server request 不进 onRequest / live 进(agenttest.swift)
- agenttest:codex mapper 分支(echo id 抑制、reasoning delta 去重等)
