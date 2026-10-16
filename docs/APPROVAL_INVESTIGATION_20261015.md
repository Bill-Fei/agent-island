# Claude 岛内批准未闭环：2026-10-15 排查

## 结论

网站错包与岛内批准未闭环是两个问题。网站修复不构成审批修复；目前不能声称 0.3.4 的真实 Claude Desktop 批准往返已经验收。

## 已确认

- Bill 报告两次在岛上选择同意后，Claude Code 页面仍显示原确认卡，需要再次操作。22:03:57 截图显示岛上“已提交决定 · 等待回执”，原应用确认卡仍在。
- 本地 `dist/Agent 灵动岛.app`：0.3.4，build `20261014153426`，revision `bd690be`。`dist/Release/Agent 灵动岛.app`：0.3.1，build `20261011213522`。不能用目录名 Release 推断最新版。
- `/Applications/Agent 灵动岛.app` 是 macOS Alias，不是独立 App 目录；其书签指向本仓库 `dist/Agent 灵动岛.app`。系统应用解析也发现两个相同 bundle ID。搜索截图的三个图标尚未逐一对应，不应直接称为三个安装包。
- 当前安装的 `bin/linglongtaictl` 与本地 0.3.4 bundle 内 helper SHA256 一致：`5d9ad9159545a435bfb6d860e394e5c3d2ddebc0d401e77ea32adc36b6563ba4`。
- 当前 Claude PermissionRequest hook 有 `--approval-relay`，timeout=50；Notification hook 是观察模式，timeout=2。不是简单的未启用审批配置。
- 使用 0.3.4 bundle 内 helper 运行 `python3 -u script/check_approval_relay.py 'dist/Agent 灵动岛.app/Contents/Helpers/linglongtaictl'`：61 项通过，包括真实 45 秒超时。全为隔离 fixture，不经过 Claude Desktop。
- 只读线上检查：首页版本和下载路径均为 0.3.4；0.3.4 安装包及 echarts 请求返回 200。完整安装包读取超时，只收到部分字节，**没有获得可信的线上完整包 SHA256**。不可使用截断数据的散列作为校验结果。
- 网站部署修复由并行 Claude 会话完成，本轮没有修改其源码或重新部署。

## 对应真实事件（北京时间，来自元数据日志）

| 时间 | 事件 |
| --- | --- |
| 21:59:46.247 | PermissionRequest，生成审批 request ID |
| 21:59:52.259 | Notification，无新的审批 request ID |
| 22:00:11.913 | PostToolUse |
| 22:03:44.932 | PermissionRequest，生成审批 request ID |
| 22:03:50.952 | Notification，无新的审批 request ID |
| 22:04:00.405 | PostToolUse |

这些事件证明请求发布和工具最终返回，不证明岛上的决定被原应用接受，也不能从六秒间隔推断 hook 超时。事件未保存决定提交/消费时间或 provider 接收回执。

## 源码行为与缺口

- `TaskStore.respondToApproval` 成功写本地 reply 后即显示“已提交决定”，并没有 provider 接收确认。
- `ApprovalRelay.wait` 消费 reply 后返回给 CLI；CLI 在 stdout 输出 PermissionRequest 的单次决定。当前没有独立的、绑定 request 的输出交付记录。
- `approvalRequest(for:)` 只允许未过期、活跃、尚无 reply 的请求出现按钮；Notification 本身没有审批权限。因此按钮消失不能只靠添加一个无回传通道的按钮修复。
- 本地 reply 被写入后，`pending` 返回 nil。后续 Notification 会清除已结束 relay 的关联。不能仅根据 request 文件消失来区分消费成功、超时或清理。
- 既有 `CLAUDE_APPROVAL_FIX_20261008.md` 和 `APPROVAL_SHORTCUTS_20261011.md` 已将真实批准往返列为未验证；隔离测试通过不能解除此限制。

## 未验证与下一步

1. 一条由 Bill 明确授权、无副作用的真实请求，记录同一 request 从发布、用户决定、本地消费、CLI 输出到原应用下一事件的元数据时间线。不得记录参数、对话、凭据或完整 stdout。
2. 由 Bill 在岛上批准；本轮不替用户批准原会话中的实际操作，不模拟点击原确认卡掩盖回传失败。
3. 只有确认根因后才改协议或状态机；L3 按 AGENTS.md 执行完整隔离检查、独立源审及真实事件验证。
4. 验收标准：同一请求在岛上批准一次后原应用恢复，不要求第二次确认；若原应用未接受，岛上明确提示未确认送达并给出回原应用入口，不伪造恢复或批准成功。

当前没有实施审批代码修复，没有安装、替换、删除应用或发布新包。

## 2026-10-16 补充：根因与修复（L3）

**根因（真实事件）**：Bill 在 Claude Desktop 中复现两类现象：① 岛上批准后原应用确认卡不消失；② 原应用没有弹卡（工具被 Desktop 自动放行，如 `read_terminal`），岛上却弹出批准。Desktop 以 SDK 托管 Claude Code，hook 进程环境为 `CLAUDE_CODE_ENTRYPOINT=claude-desktop-3p`；它对每次权限检查都会触发 PermissionRequest hook，但审批由宿主自己的界面决定，hook 的回答不被采纳。所以岛上的按钮在 Desktop 下既会误弹，也无效。

另一个问题：22:12 起 HUD 进程退出，心跳停止，导致 relay 不再发布，也就没有快速操作按钮。重启后恢复。

**修复**：
- `ApprovalRelay.hostHonorsHookDecision`：只有 entrypoint 为 `cli`（或未设置，即旧版终端 CLI）时才发布岛内审批。Desktop、VS Code、SDK 等宿主一律只观察；App 真正弹卡约 6 秒后会触发 Notification，岛上只提示回原应用处理。
- 等待期间对已发布请求的心跳停滞容忍从 4s 放宽到 12s；HUD 退出或隐藏仍立即放行。发布前仍按 4s 判定。
- 新增 `approval-trace.jsonl`，只记录元数据时间线：published / hud-actionable / hud-not-actionable / decision-written / reply-consumed / decision-output / released-*。不记录参数、对话或 stdout。
- `script/check_store.sh` 补编 `ClaudeApprovalAcceptance.swift`（此前无法编译）。

**检查**：relay 81 项、TaskStore 243 项、hook bridge、acceptance 558 项全部通过，均为隔离 fixture。终端 CLI 的真实批准往返、Desktop 不再误弹，目前都**未验证**，需在安装新包后用真实事件确认。

## 2026-10-16 修订：Desktop 恢复岛内快速审批

Bill 依赖岛内审批来跨多个对话处理请求，所以不再关闭 Desktop 的岛内审批。改为：SDK 宿主（entrypoint 不是 `cli`）发布的请求带 `waitsForProviderPrompt=true`，HUD 收到同一任务的 Notification（原应用真实弹卡约 6 秒后触发）后才显示按钮。自动放行的工具不会弹卡，也就不会误弹。Desktop 是否采纳 hook 的决定仍**未验证**，需要用 approval-trace 的 `decision-output` 时间与 PostToolUse 及原应用卡片状态对照确认。

## 2026-10-16 01:00 真实验收结论与 B 方案（待实现）

**已证实**：Desktop 不采纳 hook 决定。C91AD3B6：岛上批准 9.4s，`decision-output` 9.5s，PostToolUse 要到 59.2s（Bill 回 App 手点后）才出现。137741B5、9B40C467、F6DE8D08 同样如此。另外，Desktop 自动放行时**不会**结束 hook 进程，它会一直跑到 45s 过期。

**新信号**：`~/Library/Logs/Claude-3p/main.log` 只在真实弹卡时写一行
`Emitted tool permission request <rid> for <tool> in session local_<uuid>`，
卡片处理后写 `Received permission response for <rid>: once|...` 或 `Permission request <rid> ... aborted`。自动放行的工具不写（00:33 run_in_terminal 可作对照）。hook 环境里的 `CLAUDE_CODE_HOST_SESSION_ID` 就是这个 `local_<uuid>`。会话深链：`claude://claude.ai/epitaxy/local_<uuid>`。

**B 方案（Bill 已选定）**：
1. Request 增加 `hostSessionID`（取自环境变量，校验 `local_`+UUID 格式）和原始工具名。
2. Shared 新增 main.log 增量解析器，维护 open prompts，并处理日志轮转。TaskStore 中，Desktop 请求仅在同会话、同工具存在 open prompt 时可操作：卡片弹出约 0.3s 内亮按钮，卡片处理后收起。日志不可读时回退到 Notification。
3. 岛上决定时，由注入到 TaskStore 的 HUD 闭包执行：再次确认该会话只有一张 open prompt，记下前台 App，打开深链，约 0.6s 后用 `CGEventPostToPid` 向 Claude 发送 ⌘⏎（允许）或 Esc（拒绝）。随后 3s 内在 main.log 等待 `Received permission response for <rid>`：收到即判定成功，否则提示"未生效，请回 App"。最后恢复原前台 App。
4. 需要辅助功能权限（AXIsProcessTrustedWithOptions）。ad-hoc 签名每次重建都可能需要重新授权。
5. 风险：没有卡片时发 ⌘⏎ 可能把输入框草稿发送出去，所以发送前必须用日志确认卡片仍打开。

**当前已安装（ecf9843）的状态**：Desktop 卡片弹出约 6s 后岛上会亮按钮，但在 Desktop 下点击**无效**，仍需在 App 内确认。终端 CLI 不受影响。

## 2026-10-16 10:41 最终根因与验收（005ce94）

**更正**：前文"Desktop 不采纳 hook 决定"的结论有误，B 方案（AX 模拟点击）已删除。

**根因**：Claude Code 要等**所有** PermissionRequest hook 都返回才应用决定。飞书桥 `notify.mjs` 的审批 hook 会一直挂着等手机答复，最长 25 分钟。岛上的决定其实已经输出了，但 Claude 仍在等飞书 hook，直到用户在 App 里手点。前面 8 次岛上批准，每次都有飞书 hook 同时在等。2026-10-14 晚上飞书改成"审批一直等手机"之后，这个问题才出现。

**修复**：
- Desktop 请求重新走普通 hook relay。
- 按钮只在 main.log 出现 `Emitted tool permission request` 时才亮，所以 1 秒内出现，也不会因 Desktop 自行放行而误弹。
- 任一 hook 先拿到答复，就 touch `decided/<session_id>`，另一方看到后放手（契约见 `SiblingDecision.swift`）。

**真实事件验收**：
- 10:41:25 卡片出现。
- 10:41:26 岛上亮按钮。
- 10:41:33 岛上允许，同一秒 Desktop 记录 `aborted`（hook 应用）、飞书 hook 放手，工具继续执行。

已验证 1 次。按钮存在受 45 秒 relay 时限约束。
