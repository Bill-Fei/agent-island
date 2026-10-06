# Agent 灵动岛 / Agent Dynamic Island

你的 Agent 管家。运行在 macOS 刘海区域的本地动态状态层：空闲时归入物理刘海，事件到达时保持刘海高度并横向展开，连续悬停 0.2 秒查看详情。状态来自真实事件，不推测进度。支持选择性安装单次批准桥接；不支持的请求回原应用处理。

内置四个一级 Agent 身份：

- `Codex`：终端 / 代码执行
- `Claude`：长上下文分析与代码协作
- `豆包`：中文内容与多模态任务
- `Work Buddy`：工作上下文、提醒与跨任务接续

图标从本机安装的应用读取，不另行仿制厂商 Logo；未安装时明确使用通用占位。视觉、交互与功能有独立验收 Agent，不作为 HUD 内第五个身份。

## 运行

```bash
cd linglongtai-hud
./script/build_and_run.sh
```

开发验收预览（不读取或覆盖个人任务数据）：

```bash
./script/build_and_run.sh --qa-empty
./script/build_and_run.sh --qa-demo
```

独立状态回归检查：

```bash
swift build --build-system swiftbuild --product linglongtai-acceptance
.build/out/Products/Debug/linglongtai-acceptance
```

如果本机 Command Line Tools 与 Swift 编译器版本不一致，SwiftPM 会在编译阶段停止；此时需要在 Xcode / Command Line Tools 中选择同一套版本后重新运行上面的命令。启动后可从菜单栏灵动岛图标打开「灵动岛设置…」。

应用会构建到 `dist/LinglongtaiHUD.app`，启动后显示顶部灵动岛，并在菜单栏保留一个灵动岛入口。首次启动默认不注入演示任务；可以从菜单栏打开「灵动岛设置…」，在「本地任务数据」中载入演示任务。

## 本地 Agent 接入

现已提供 Codex、Claude Code、WorkBuddy 的真实生命周期 Hook。豆包暂时仅显示应用运行状态。接入只记录开始、等待、执行、结束和失败等元数据，不保存输入内容、工具内容、聊天文件路径或凭据，不推测百分比。

```bash
swift build --build-system swiftbuild --product linglongtaictl
python3 script/install_hooks.py --binary .build/out/Products/Debug/linglongtaictl
python3 script/install_hooks.py --binary .build/out/Products/Debug/linglongtaictl --apply
```

安装器保留已有设置并备份，合并到 `~/.codex/hooks.json`、`~/.claude/settings.json`、`~/.workbuddy/settings.json`。稳定桥接程序位于应用支持目录的 `bin/linglongtaictl`。不会修改 Codex 的信任策略；需要时在官方 `/hooks` 页面审阅。卸载仅移除本项目命令：安装命令追加 `--uninstall`。

2026-10-04 实机结果：Codex 当前桌面会话已有真实工具/审批/结束回调；WorkBuddy 桌面内置引擎最小请求正常完成；Claude Code 收到开始和失败回调，但当前账户/接口返回 401，尚未验证正常完成。Claude Code 接入不覆盖普通 Claude Chat。

以下 CLI 为自定义事件接入工具，手工调用不等于对应厂商已经接入：

构建 CLI：

```bash
swift build --build-system swiftbuild --product linglongtaictl
CTL="$(swift build --build-system swiftbuild --show-bin-path)/linglongtaictl"
```

创建任务并拿到 UUID：

```bash
TASK_ID="$($CTL start --agent Claude --title "整理本周素材" --model "Claude Code")"
```

四个 Agent 都可以这样启动：

```bash
$CTL start --agent codex --title "检查构建"
$CTL start --agent claude --title "整理研究材料"
$CTL start --agent doubao --title "生成中文摘要"
$CTL start --agent work-buddy --title "同步今日工作上下文"
```

更新状态：

```bash
$CTL update --id "$TASK_ID" --progress 0.55 --detail "正在整理第 3 个目录"
$CTL wait --id "$TASK_ID" --detail "需要用户确认后继续"
$CTL finish --id "$TASK_ID"
```

事件写入：

`~/Library/Application Support/LinglongtaiHUD/events.jsonl`

HUD 提供“打开应用”，不在本地假装停止、重试或任务完成。`commands.jsonl` 是旧命令请求协议，不代表厂商执行成功，也不由当前界面调用。

## 岛内单次批准（实验性）

Codex、Claude Code、WorkBuddy 的 PermissionRequest 可选择桥接到岛。中态显示「批准…」，小态显示可点击的橙色手掌；点击后在岛旁核对原始工具名、工作目录、完整参数，再选择「仅允许这一次」或「拒绝本次」，无需先 Hover 打开详情或切换应用。

```bash
python3 script/install_hooks.py --binary .build/out/Products/Debug/linglongtaictl --approval-relay --apply
```

- 只返回原生本次 `allow` / `deny`，不写长期授权。提交后等待真实回调，不改任务为“已成功”。Codex 官方信任确认仍由用户操作；新 Hook 可能需要重启原会话。
- 请求绑定唯一 UUID 与任务。45 秒无决定回原流程；HUD 未运行立即回退，失去心跳不超过约 4 秒回退。不完整、过大或疑似包含凭据的参数不转移到岛。
- 确认上下文暂存在本机私有目录 `pending-approvals`（目录0700、文件0600），不进入事件日志/任务快照。正常完成或超时清理；异常退出后，下次岛启动或新请求时清理。不是系统保证的定时物理擦除。
- 同一轮并行批准当前仅展示最新入口，较早请求超时后仍回原应用，不会被自动批准。
- 已通过隔离进程和 Store 回归，且核对了本机消费协议。**三家真实会话中从岛点击直到工具恢复的端到端验收仍未完成**；普通 Claude Chat 和豆包不在本次批准范围内。

协议依据：[Claude Code 官方 Hooks 文档](https://code.claude.com/docs/en/hooks#permissionrequest-decision-control)；本机 Codex `permission-request.command.output` 内置 Schema；本机 WorkBuddy 2.115.0 `executePermissionRequestHooks` / `executeToolWithHooks` 代码。兼容性不能泛化所有历史版本。

## 当前边界

- `20261006.6`：补上处理中小态右侧动态指示。真实 running 时显示三段错峰呼吸条，不代表百分比；等待、批准、过期、完成、失败与减少动态效果时保持静态 SF Symbol。固定在右侧小翼内，不改变刘海宽度或相机避让区。
- 最新 `20261006.2` 已构建并恢复正常数据模式：中态两侧可见边距12pt，精致小态图标与状态胶囊，收起时轮廓/圆角/文字同步，两翼过渡不缩小相机避让区。1029项隔离检查通过，独立阻断修复源审通过。真实Hover/逐帧效果/批准弹层验收因Mac锁屏未完成。WorkBuddy本轮真实无工具请求成功；Claude本轮真实请求仍返回401，认证未更改。详情见 `docs/ACCEPTANCE.md`。
- 2026-10-06 修复版 `20261006.1` 已启动：悬停改为0.2秒；权限检查与需要用户确认分开显示。自动检查不再提示“待确认”，已提交/过期请求不再计待确认，真正后续通知可重新提示。最新947项隔离检查通过，详情见验收记录。
- 当前版本是本地 HUD 原型：默认没有任务，避免启动后无故打扰；需要演示时可从设置页载入四个 Agent 的内存预览，预览不会写入真实任务文件。
- macOS 没有公开的“直接修改灵动岛”接口；实现方式是置顶窗口，按当前主屏幕中心与顶部边缘对齐，视觉上形成黑色刘海主体。
- 展示分为四态：空闲时融回物理刘海；新任务、待确认或结束时显示中态 10 秒；未结束任务随后持续保留小态；悬停或点击进入完整详情，离开恢复对应状态。普通工具回调不会反复重置 10 秒提示。
- 验收口径与运行记录见 `docs/ACCEPTANCE.md`。
- 设置页分别提供活动提示宽度、活动状态高度、刘海基准宽度校准；拖动立即预览 6 秒，可预览小态/中态或恢复自动尺寸。空闲物理刘海不受校准影响。
- 没收到厂商回调时明确显示“未收到回调”；收到连接不等于任务正在执行。Stop 表示本轮响应结束，不能证明用户的整个目标已完成。
- 列表只显示未结束的事件任务：待确认优先，同组按最近真实活动排序；完成/失败/取消仅保留历史，不占默认列表。120 秒无事件显示等待更新，24 小时无活动隐藏（不标完成），新事件可重新出现。
- 详情拆为当前步骤与已返回步骤；有唯一步骤标识才去重计数，缺少标识明确称返回记录。不会从 Prompt 拼造步骤，不读取聊天上下文。
- 豆包设置区区分应用运行状态与会话进度。目前未确认官方桌面会话事件/审批接口；[豆包官网](https://www.doubao.com/)与[火山方舟模型平台](https://www.volcengine.com/product/ark)是不同接入层，不索取 API Key，不以模型 API 冒充桌面会话接入。
- 前一版本 `20261005.2` 已通过正式 SwiftPM 构建并启动；包含隐藏/关闭主动提示时不接管审批、提交失败与过期可见反馈等修复。当时936项隔离检查通过；当前日志 `.build/contained-validation/latest-checks.log` 已更新为本次947项结果。
- 原生设置窗口、三项尺寸数值调整及预览入口、自动弹出关闭/开启对应的审批接管心跳已检查，用户设置已还原。当前 App 面板可读取真实 Codex 活动；截图不代表物理屏幕合缝或逐帧动画验收。真实 Hover、批准弹层布局和三家真实批准恢复执行仍未全部验证，不能宣称公开发布验收通过。最后隔离 GUI 验收启动的自动权限审核两次超时，正式运行版本保持不变。
- 2026-10-05 已安装本轮 Codex / Claude Code / WorkBuddy 单次批准 Hook；安装的桥接程序与验收二进制哈希一致，每家只启用一个 PermissionRequest 批准桥，原有其他设置经与备份比较保持一致。备份后缀为 `.linglongtai-backup-20261005-234122-554061`。新 Hook 是否加载以各应用实际行为为准，可能需要新建会话或重启；Codex 原生信任审阅仍由用户完成。
- 不启动界面的 Store 验收：`bash script/check_store.sh`。仅打包、不退出运行应用：`./script/build_and_run.sh --package-only`。
