# 详情页打开应用按钮 · 2026-10-09（L2）

## 修改范围

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
