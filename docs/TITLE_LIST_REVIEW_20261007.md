# 2026-10-07 会话标题与展开回顶（L2）

- 列表与详情按 hook 的 provider/session-v2 哈希精确匹配 Codex 桌面名称，只读 SQLite 的 id/name 元数据，不读原始 prompt/title 或聊天正文。
- 标题由独立后台缓存每 10 秒刷新；读取失败保留最后成功结果。其他来源没有可靠标题时显示未提供标题及短标识，不借用另一会话名称。
- ScrollViewReader 使用非 lazy 顶部锚点。presentation 进入 heavy 或首次以 heavy 挂载时，无动画 scrollTo 顶部。任务更新、标题刷新和展开期间手动滚动不触发复位。
- 验证：SwiftPM LinglongtaiHUD 构建成功；独立只读源审确认精确标题键、缓存失败处理、滚动触发边界；git diff --check 通过。
- 未验证：真机首次 hover 与反复滚动/收起/展开的实际位置、长标题视觉、动画帧率。本轮未重启运行包。
- 当前同仓库存在其他会话的全 provider observer-only 改动。协议隔离检查仍与旧成功批准 fixture 冲突，不能将其计为通过；不覆盖或替别人提交该变更。
