# App English localization — plan

Status: inventory done 2026-10-16, code not started (waiting for the approval-relay work in
`TaskStore.swift`, `ApprovalRelay.swift`, `CliEntry.swift` to land first).

## Why

About 60% of site visits come from the US and the site now has an English page, but the app is
Chinese only. The first thing a new user does is approve a change to an agent's config file;
someone who cannot read that dialog will not approve it. The app never goes online, so this
drop-off can never show up in the website analytics.

## Approach: Chinese stays the source, English is added at display time

- The app follows the macOS system language. No in-app switch. Chinese users see no change.
- Development region stays `zh-Hans`. Every existing Chinese string keeps working as-is and
  becomes the lookup key; `en.lproj/Localizable.strings` maps it to English.
- **Translate only where text reaches the screen.** Code keeps comparing and storing Chinese.
  This matters because several Chinese strings drive logic (see "Never translate" below).
- Stored text (`task.detail`, `step.label`, default titles) was written in Chinese and is read
  back from history. Display looks the stored string up in the table: known system text turns
  into English, unknown text (task titles, the agent's own wording) passes through unchanged.
  No data migration, and old and new records render the same way.
- Interpolated strings (`"\(n)项进行中"`) become format strings with English plural rules.

Packaging: `script/build_and_run.sh` copies resources into the .app by hand. It needs to copy
`zh-Hans.lproj` and `en.lproj`, write `CFBundleDevelopmentRegion = zh-Hans` and
`CFBundleLocalizations = [zh-Hans, en]` into Info.plist, and add the strings files to the
source hash on line 53 (`IslandSourceSHA256`).

## Never translate

| Where | What | Why |
|---|---|---|
| `TaskVisualState.swift:25,36` | `"历史记录 · 不再跟踪"`, `"等待回执"` | compared with `displayedStatus` to pick a visual state |
| `HUDView.swift:515,533` | `"结果未知"` | compared with `displayedStatus` to show the remove button |
| `TaskStore.swift:541-549` | `displayedStatus` return values | the values the comparisons above test against |
| `ClaudeChatObserver.swift:186-187` | `"停止"`, `"停止回复"`, `"停止生成"`, `"发送"` | read from Claude Chat's own UI to detect generation |
| `ClaudeChatObserver.swift:18-26` | enum raw values | identity of the observer state; translate the display only |
| `Models.swift:62` | `"豆包"` | alias used to recognise the Doubao agent from input |
| `DoubaoTrajectory.swift` | everything | parses Doubao's local records |
| `TaskStore.swift:1323-1488` | demo task titles | demo data; translate later if the demo is shown to English users |
| `Sources/LinglongtaiAcceptance/*`, `*Acceptance.swift` | everything | tests assert on the Chinese strings |
| `Sources/LinglongtaiCtl/*` | CLI output | terminal tool, not part of the app UI |

## Scope

Phase 1 — what a new user sees in the first ten minutes (~210 strings):

| Area | Files |
|---|---|
| Menu bar menu | `HUDController.swift` |
| First-run guide | `AlphaOnboardingView.swift` |
| Connect & Verify | `AlphaIntegrationSetup.swift` |
| Island (small / alert) and task overview | `HUDView.swift`, `TaskVisualState.swift`, `TaskStore.swift` (display text only), `TodayUsageBar.swift`, `AIWorkDurationRow.swift`, `AIWorkDuration.swift` |
| Status and step names | `Models.swift`, `ToolStep.swift`, `HookEventMapper.swift` (display lookup, see above) |
| Open-app messages | `AgentPresence.swift` |
| One-time approval | `ApprovalReviewView.swift`, `ApprovalRisk.swift` |

Phase 2: `SettingsView.swift`, `ClaudeChatObserver.swift` status text, remaining error notices.

## Glossary

Matches the English website so the two read as one product.

| 中文 | English |
|---|---|
| Agent 灵动岛 | Agent Island |
| 你的 Agent 管家 | All your agents, at a glance |
| 灵动岛（指界面本身） | the island |
| 接入 / 接入与验证… | connect / Connect & Verify… |
| 观察器 | integration |
| 回调 | event |
| 轮 / 轮次 | turn |
| 会话 | session |
| 会话线索 / 复制会话线索 | Thread ID / Copy thread ID |
| 原应用 | the agent's app |
| 进行中 | Running |
| 已结束 | Done |
| 待你确认 / 待确认 | Needs you |
| 排队中 | Queued |
| 本轮结束 | Turn done |
| 响应失败 | Failed |
| 已停止 | Stopped |
| 核对权限 | Checking permission |
| 等待回执 | Waiting for agent |
| 结果未知 | Result unknown |
| 不再跟踪 | No longer tracked |
| 批准… / 仅允许这一次 / 拒绝本次 | Approve… / Allow once / Deny |
| 打开应用 | Open app |
| 从岛上移除 | Remove from island |
| 今日活跃 · N 轮 | Today · N turns |
| AI 工作 | AI working time |
| 最近 24 小时 / 进行中优先 | Last 24 hours / Running first |
| 读取文件 · 执行命令 · 编辑文件 · 检索文件 · 搜索资料 · 读取网页 · 工具调用 | Read file · Ran command · Edited file · Searched files · Web search · Read web page · Tool call |
| 递归删除 · 管理员权限 · 强制推送 · 丢弃本地改动 · 下载后直接执行 · 放开权限 · 磁盘级操作 · 删除数据库表 | Recursive delete · Admin privileges · Force push · Discard local changes · Download and run · Loosened permissions · Disk-level operation · Drop database table |

## Risks to check before release

- English is longer. The alert-state island width is computed (`IslandContentWidth.swift`,
  `IslandWingLayout.swift`); long English titles must truncate cleanly, not overflow the notch.
- Plurals: "1 task running" / "3 tasks running".
- Verify on an English system: launch with `-AppleLanguages '(en)'` and walk through first run,
  Connect & Verify, one real task per agent, and one-time approval.
- After release, update the site: drop "The app's interface is in Chinese for now", and change
  step 3's `"接入与验证…" (Connect & Verify)` to `Connect & Verify…`.
