# Claude Code真实名称（L2，2026-10-07）

## 范围

- 读取本机~/.claude/projects/<project>/<session>.jsonl独立custom-title行的type/customTitle/sessionId。与实际Hook使用完全一致的provider命名空间哈希，历史通用任务即时解析；明确任务名保留。
- 不把prompt、assistant、summary、last-prompt或工具内容当标题。没有命名元数据时保留“未提供会话标题”；不生成/猜测名称。
- 元数据存于混合JSONL：为定位标题必须流式经过文件字节，但只对custom-title头部的完整行做JSON解码，消息行不解析、不存储。64KiB流式块、8KiB行上限；后台首次扫描约6.7秒，后续只读取追加区，真机不变刷新约0.11秒。
- 缓存inode/size/mtime/已提交行边界；改名、清空、截断、原子替换、半行恢复、删除均处理。项目不可读返回nil保留最后有效快照。UI/动画帧不读文件，仍10秒后台刷新。
- 此接入仅Claude Code。Claude桌面Chat/Cowork普通对话不使用该session命名空间；不把Code名称套到Chat窗口身份。另一会话的ClaudeChatObserver不在本轮修改范围。

## 验证

- 27项Claude专项隔离检查，涵盖真实名称映射、Hook身份、跨provider、改名/清除/删除、partial、UTF8中文头截断、1MiB正文不作标题、nested/symlink排除与只读。
- 共享507、TaskStore182、后台3、Hook514、观察式权限20项通过；另独立源码复核通过。标准check_sandbox的并发Store编译缺依赖，已用显式补ClaudeChatObserver的同等命令验证，未修改他人脚本。
- 真实本机只读探针：16个有效名称；8条保留Claude任务有6条精确匹配，ConversationTitleStore后台解析也6条一致；未打印名称正文、原始会话标识或聊天内容。两条无匹配仍占位。
- SwiftPM构建和package-only打包成功，当前运行应用在该步骤没有退出。应用启动验证单独记录；不把数据层/启动成功当原生列表截图验收。
- 原生Hover列表和详情视觉、Claude普通Chat真实名称仍未验证。
