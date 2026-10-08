# Codex 状态回调恢复（2026-10-08，UTC+08:00）

## 原因与恢复范围

- 17:38 的只读检查确认 Codex 的 `~/.codex/hooks.json` 中 `hooks` 为空；文件修改时间为 2026-10-07 22:00:40。不能据此确认修改者。
- 最新真实 Codex 回调仍为 2026-10-08 00:10:03 的 `PostToolUse`，当前运行会话没有进入事件流。
- 用户明确确认恢复后，仅恢复备份中的 8 类观察回调：SessionStart、UserPromptSubmit、PreToolUse、PermissionRequest、PostToolUse、Stop、SessionEnd、Interrupt。
- 修改前备份为 `~/.codex/hooks.json.linglongtai-recovery-backup-20261008-175831`。
- 继续使用原有不可变桥接程序 `linglongtaictl-7442dfd243d5c596`，哈希核对一致；没有替换共享桥接程序、修改产品源码或修改个人任务。

## 验证

- 恢复后的 hooks 与 `hooks.json.linglongtai-backup-2F410965-C536-4059-BAB3-84C4CC8C813F` 中的 hooks 结构完全相同；非 hooks 设置不变，配置权限 0600。
- WorkBuddy、Claude 配置以及 Codex `config.toml` 的 SHA-256 前后相同；未修改审批或信任策略。
- 配置中的实际 shell 命令在独立临时数据目录执行完整生命周期，包含两次 UserPromptSubmit，共 9 次调用全部通过；8 类事件均覆盖，stdout/stderr 均为空。
- 隔离测试没有向真实 HUD 注入模拟任务或补写开始/结束事件。

## 尚未验证的边界

- 恢复后的真实事件检查仍停在 00:10:03；当前会话是否加载新配置、真实两个任务是否显示及完成后收起，尚未验证。不能把配置恢复或隔离测试当作真实接入成功。
- 没有重启 Codex 或灵动岛，没有给另一个会话发送消息，没有触发新的模型任务。
- 下一步：用户在原会话完成后再发一次真实请求；必要时在官方 `/hooks` 页面审阅配置加载/信任。仍无回调时，等当前任务结束后重启 Codex 再验证，不中断进行中的任务。
- 此次仅恢复接入；`85b91ac` 的 120 秒新鲜度收起仍可能隐藏没有工具回调的长推理，未在本次配置恢复中更改，也未宣称该场景已解决。
