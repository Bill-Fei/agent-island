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
