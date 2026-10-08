# WorkBuddy 状态回调恢复（2026-10-08）

## 已确认的原因

- WorkBuddy 与 LinglongtaiHUD 进程均存在，不是应用退出。
- `~/.workbuddy/settings.json` 在 2026-10-07 22:00:40（UTC+08:00）的文件修改后，`hooks` 为空对象。不能据此确认修改者。
- 修改前备份包含 8 类灵动岛回调；真实 WorkBuddy 回调最后停在 2026-10-07 21:30:14 的 `Stop`。

## 本次恢复

- 用户确认后，仅恢复 WorkBuddy 的 8 类生命周期观察回调，未改源码或状态机。
- 保留备份中原有的 `linglongtaictl-7442dfd243d5c596` 桥接程序；没有替换共享桥接程序。
- 先备份到 `~/.workbuddy/settings.json.linglongtai-recovery-backup-20261008-090846`，再仅修改 `hooks`。
- 不重启 WorkBuddy，不停止任何任务，不把历史任务改为进行中。

## 验证及边界

- 恢复后的 hooks 与已知备份结构完全一致，非 hooks 设置完全相同，配置权限为 0600。
- Codex、Claude 配置 SHA-256 前后相同。
- 使用配置中的实际 shell 命令，在独立临时数据目录依次调用 SessionStart、UserPromptSubmit、PreToolUse、PermissionRequest、Notification、PostToolUse、Stop、SessionEnd：8 类事件全部成功，stdout/stderr 为空，事件只属于 WorkBuddy。
- 初次探针按配置键顺序发事件，SessionEnd 早于 SessionStart，导致完整事件计数断言失败；改为真实生命周期顺序后通过。没有修改产品逻辑。
- 上述为隔离测试，没有向真实 HUD 注入模拟任务。PermissionRequest 不回复审批决策。
- 截至恢复后检查，尚未收到新的真实 WorkBuddy 回调；配置是否被当前进程重新加载、真实任务在岛上显示，仍待验证。
- 最短验证：在 WorkBuddy 发起一次真实任务；若无回调，等当前任务结束后重新启动 WorkBuddy 再试，不中断运行中的任务。
