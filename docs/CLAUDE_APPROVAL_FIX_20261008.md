# Claude 快捷审批与打开应用 · 2026-10-08

本轮仅恢复 Claude Code 的显式单次审批中继，以及修复应用启动/前台激活。不是 Claude Chat 的自动批准，也不启用 Codex、WorkBuddy 或豆包回写。

## 已落地

- CLI 必须带 `--approval-relay`，且只接受 Claude Code `PermissionRequest`；Notification、模糊轮次、子智能体和不完整/敏感/过大参数回退原应用。
- 请求协议 v2，准确绑定 task/request/provider；原始参数只在本机 0700/0600 临时文件中展示，不进入事件日志。按钮先展示完整参数，再选仅允许这一次或拒绝本次；不返回 updatedPermissions。
- 提交后不伪造任务恢复，等待真实 provider 回调；重复决定、过期请求不再批准。45 秒无操作、HUD 不可用时回退。
- 安装器以 exact argv 去重旧哈希路径，使用不可变内容指纹桥接；写前回读原配置，冲突即拒绝覆盖。Claude 配置有本地备份，非 Hook 设置保持不变。
- 打开应用优先使用真实运行 bundle，显式 reopen/activate/unhide；失败时显示原因、可重试。不保证定位到原会话，终端任务仍需原终端。

## 本轮证据与边界

- 项目原构建脚本 `./script/build_and_run.sh --verify` exit 0，实际打包、签名并启动。
- 最后一次配置识别改动后，再次 `./script/build_and_run.sh --verify` exit 0；8 项独立临时配置探针通过，覆盖 Claude 单次请求 timeout=50、其他事件/provider 拒绝 relay，以及原生重装仍恢复观察模式。探针：`/private/tmp/island-relay-config.BpMwQG/main.swift`。未重复运行 45 秒审批全套，审批协议自前次检查后未变。
- `bash script/check_sandbox.sh` exit 0：TaskStore 225 项（包含审阅、提交、过期、重复、重载等 10 项新增检查），Hook 514 项，审批 61 项（真实 45 秒 timeout），后台 3 项，Shared/Alpha 检查通过。全部是隔离 fixture，不是厂商真实端到端。
- Store 报告：`/private/tmp/island-contained-store.u7CkTv/acceptance.txt`，225 PASS，0 FAIL。不引用旧 `.build/contained-validation/latest-checks.log`。
- 独立源审：原安装器并发覆盖 P2 已修复并复审，无新增阻断项；不宣称整个 App 已发布可用。
- 实机设置页点击“打开 Claude”后，状态由“应用运行中”变为“应用在前台”。Claude 窗口树读取超时，窗口内容可见性仍 NOT VERIFIED。详情页按钮使用同一入口，但尚未完成其点击实测。
- 最后构建后已同步 Claude Hook；每类事件只有 1 条岛观察器，只有 PermissionRequest timeout=50 且启用中继，非 Hook 设置不变。当前安装与 dist helper SHA256 一致：`6d0077ca51d6985eacbbd7289471d6228825cdfa3eddaf05f80966495f62cad7`。
- 最新配置备份：`~/.claude/settings.json.linglongtai-backup-20261008-221139-322427`。安装前原始配置备份：`~/.claude/settings.json.linglongtai-backup-20261008-204747-342869`。去重修复备份保留：`~/.claude/settings.json.linglongtai-backup-20261008-210519-415511`。
- 新 Hook 是否被原会话加载、真实请求 → 岛点击批准 → 工具恢复仍 NOT VERIFIED。未发送真实任务、未批准用户未知操作。
- 原生“安装接入”目前是观察模式，重新安装 Claude 后需重新显式启用单次审批；识别已启用 relay 不应显示为未安装。此轮不扩展原生授权设置。
- 并行协作说明：`IntegrationConfiguration.swift` 属于其他会话的未跟踪新文件；本轮只调整其中的已安装识别，未将整份文件代为提交。`TaskStore` 的长任务跟踪改动也保留在原工作树，本轮不混入审批提交。

## 下一步验收

Bill 下一次真实 Claude Code 工具请求出现时，应在岛上看到“批准…”入口，进入参数审阅后由 Bill 明确选择，随后核对真实 PostToolUse 回调。普通通知、敏感请求或已过期请求只回原应用。

## 已确认但未在本轮实施的 UI 方向

用户补充（2026-10-08）：采用“进行中突出、已完成退后、未知态单独表达”，不只靠文字颜色区分。

- 进行中：独立状态标记/轻动态、标题层级突出。
- 已完成：静态勾、退后层级但仍可读，不与选中态混淆。
- 未知态：独立“待更新/尚未收到结束”表达，不当作运行或完成。
- 结合分组/排序与标记区分；不加 icon 外框、不整卡强染色。以独立 L2 展示改动实施，不改真实状态源。
