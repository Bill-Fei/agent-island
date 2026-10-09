# 详情页打开应用按钮 · 2026-10-09（L2）

## 修改范围

本节记录第一次点击区域修正；随后根据 Bill 的截图补做窗口恢复，见下文。

- 只修改 `HUDView.swift` 中详情页“打开应用”的标签结构。
- 字号、颜色、留白、胶囊背景放入 Button label；用 `contentShape(Capsule())` 将可交互区域明确匹配整枚胶囊，而非仅文字。外观不变。
- 未修改 `AgentPresence`、任务状态、Hook、Claude 配置或会话定位协议。
- 排查时尝试的“运行中仅 activate 后提前返回”分支已撤回，未提交；保留原有 workspace reopen + unhide + activate 路径，避免进程运行但窗口关闭时跳过 reopen。

Apple 对 contentShape 的定义是设置 hit-testing 形状：<https://developer.apple.com/documentation/swiftui/view/contentshape(_:eofill:)>

## 验证证据

- `./script/build_and_run.sh --verify` exit 0：当前源码编译、打包、签名及正常模式启动通过。不是隔离视觉 fixture，不发送 provider 请求。
- 真机详情页选择可见的真实 Claude 已结束任务，视觉检查按钮外观与布局未变。
- 前台对照：设置页“打开 Codex”后，系统标签显示 Codex 在前台、Claude 运行中；回到 Claude 详情页点击“打开应用”，再次读取系统标签显示 Codex 运行中、Claude 在前台。验证的是 OS 应用激活，不是聊天消息或完成事件。
- 详情页 AX 按钮点击链路通过。操作期间未发送消息、未批准工具请求、未清空个人记录。

## 未验证与结论边界

- 胶囊留白边缘的物理鼠标点击：自动化返回 `windowNotFoundAtPosition`，NOT VERIFIED。不能将 AX 点击等同于边缘命中验收。
- Claude 窗口画面读取超时；窗口可见性、其他 Space、窗口关闭后恢复仍 NOT VERIFIED。
- 没有确证用户截图当时无效的唯一原因。点击区域结构存在隐患，已最小修正；原有应用映射正确，不能宣称是 bundle ID 错误。
- 按钮仅打开 Claude 桌面应用，不承诺回到原聊天。截图“验收预览”是隔离 fixture，本身没有真实会话跳转目标，但这不能解释或合理化“连应用也打不开”。
- 此轮是局部 L2 点击区域修正，未重复运行 L3 状态机/批准全套；不宣称整 App 总体验收或发布达标。

## 后续窗口恢复修正（L2）

Bill 的 `截屏2026-10-09 05.47.46.png` 显示菜单栏属于 Claude，但画面仍为 Codex。前次仅验证前台应用不足以判定用户操作成功。

- `AgentPresence` 对运行中的应用明确设置 `kAEReopenApplication`，保留未运行应用的默认启动事件。Apple 将此事件描述为运行中点击程序坞图标时的重新打开事件：<https://developer.apple.com/documentation/coreservices/1556377-kaeqdnotor/kaereopenapplication>
- 激活后检查对应 PID 的正常层窗口是否在屏幕上。只使用 PID、层级、透明度、尺寸，不读窗口名称或聊天内容；屏幕窗口存在也不等同于原会话已定位或窗口完全未被遮挡。
- 无可见窗口时，在已获辅助功能权限的前提下尝试恢复一个标准窗口：取消最小化、Raise、设为 main。后台执行，AX 单次超时 0.1 秒，候选最多 4 个；不扫描窗口内容，不强制退出应用，不重新定位窗口或修改桌面设置。
- 窗口创建最多等待 3 秒；未恢复时区分缺少辅助功能权限与窗口仍不可见。提示保留在详情页和设置页，允许重试，不把仅激活进程当成窗口恢复完成。
- 不弹出或自动修改系统授权，不发送聊天消息，不修改 Hook 和 provider 配置。

### 验证与阻塞

- 最后一次 `./script/build_and_run.sh --verify` exit 0，编译、签名、正常模式启动通过，已运行的是修正版。
- `script/AgentOpenAcceptanceMain.swift` 的 18 项纯 fixture 检查通过：reopen/冷启动配置、窗口过滤与权限反馈。无真实窗口恢复动作，不引用全套 L3 结果。
- 系统只读几何快照：Claude PID 37528，运行且未隐藏；主窗口在快照中 `on-screen=false`。这确认窗口不在当前可见屏幕，不能进一步确证最小化、其他 Space、窗口应用内部状态中的哪一种。
- 真机设置页点击“打开 Claude”后先显示 opening 禁用态，随后出现“灵动岛尚无辅助功能权限，无法恢复最小化窗口”提示。当前签名版本 `AXIsProcessTrusted()` 为 false；此结果是阻塞证据，不是窗口恢复成功。
- 修正版使用临时 ad-hoc 签名，更新可能令旧授权失效。需要 Bill 在系统设置中重新授权当前 `dist/Agent 灵动岛.app`，再验证真实详情按钮恢复窗口；不得将此前其他版本的授权当作本版已授权。
- 有效授权后的恢复、冷启动、窗口关闭、最小化与其他桌面的真实端到端仍 NOT VERIFIED。尚不能宣称按钮问题完全解决。
