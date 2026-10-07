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
- 首轮真实本机只读探针：17个有效名称；8条保留Claude任务有6条精确匹配，ConversationTitleStore后台解析也6条一致。继续验收时任务增至10条、8条精确匹配，后台8条一致；两条无可用元数据仍占位。首读约6.95秒，不变刷新0.122秒；快照稳定。不输出原始会话标识或聊天内容。
- SwiftPM构建和package-only打包成功；随后build_and_run.sh --verify返回0，构建/打包/启动确认成功。继续验收的原生设置窗口确认0.3.1、6ea2f6b-dirty（其他会话未提交改动）。
- 用户当前Claude桌面窗口是Code模式；原生AX头部按钮为“Greeting, rename session”。只读探针确认名称元数据、精确Hook任务关联、ConversationTitleStore后台结果均为Greeting，不将Code会话名称套给Chat窗口。
- 原生列表/详情最终视觉仍未验证：首轮锁屏，解锁后菜单AX元素ID持续失效，键盘选择无结果；同仓库其他会话期间更新过运行应用。桌面工具一次Claude窗口读取长时间阻塞，不能视为产品帧率证据。没有为通过验收虚构交互结果。
- Claude普通Chat真实名称仍未接入；现有ClaudeChatObserver及TaskStore又有其他会话的未提交修改，本轮未覆盖它们。其窗口身份不是持久聊天ID，不能直接关联Code标题。
