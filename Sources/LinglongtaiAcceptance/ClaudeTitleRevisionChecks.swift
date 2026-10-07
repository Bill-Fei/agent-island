import Foundation
import LinglongtaiShared

func runClaudeTitleRevisionChecks(check: (String, Bool) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("island-claude-title-" + UUID().uuidString)
    do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    catch { check("Claude title fixture directory creates", false); return }
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let file = project.appendingPathComponent("real-session.jsonl")
    func row(_ title: String, id: String = "real-session") -> String {
        // The real Claude format always starts with its type header.
        let encodedTitle = String(data: try! JSONSerialization.data(withJSONObject: [title], options: [.fragmentsAllowed]), encoding: .utf8)!
        let encodedID = String(data: try! JSONSerialization.data(withJSONObject: [id], options: [.fragmentsAllowed]), encoding: .utf8)!
        return "{\"type\":\"custom-title\",\"customTitle\":\(encodedTitle.dropFirst().dropLast()),\"sessionId\":\(encodedID.dropFirst().dropLast())}\n"
    }
    func write(_ value: String, at url: URL = file) { try? value.write(to: url, atomically: true, encoding: .utf8) }
    func append(_ value: String) {
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(value.utf8))
    }
    let key = ConversationTitles.sessionKey(provider: .claude, rawID: "real-session")
    let body = "{\"type\":\"user\",\"message\":{\"content\":\"PRIVATE_PROMPT_SENTINEL\"},\"customTitle\":\"不得读取消息字段\"}\n"
    write(body + row("真实会话名称"))
    var reader = ClaudeConversationTitles()
    let snapshot = reader.snapshot(root: root)
    check("Claude explicit app name resolves by exact session", snapshot?[key] == "真实会话名称")
    check("Claude prompt data never enters title snapshot", snapshot?.values.contains("PRIVATE_PROMPT_SENTINEL") == false && snapshot?.values.contains("不得读取消息字段") == false)
    let hook = HookEventMapper.map(provider: .claude, payload: Data("{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"real-session\"}".utf8))
    check("Claude title identity matches actual Hook mapping", hook?.sessionID == key)
    check("Claude does not collide with other providers", key != ConversationTitles.sessionKey(provider: .codex, rawID: "real-session") && key != ConversationTitles.sessionKey(provider: .workBuddy, rawID: "real-session"))
    let task = AgentTask(agent: "Claude", title: "Claude Code 会话", status: .running, detail: "fixture", model: "Claude Code", sessionID: key)
    check("Claude generic historical task displays real name", ConversationTitles.display(task: task, titles: snapshot ?? [:]) == "真实会话名称")
    check("Claude unmatched task stays honest", ConversationTitles.display(task: task, titles: [:]).hasPrefix("未提供会话标题"))
    var explicit = task
    explicit.title = "显式任务名"
    check("Claude explicit task names are not overwritten", ConversationTitles.display(task: explicit, titles: snapshot ?? [:]) == explicit.title)
    let before = try? Data(contentsOf: file)
    check("Claude identical refresh is stable", reader.snapshot(root: root) == snapshot)
    check("Claude actual file remains read-only", (try? Data(contentsOf: file)) == before)
    append(row("后来改名"))
    check("Claude appended rename takes precedence", reader.snapshot(root: root)?[key] == "后来改名")
    append(row("别的会话", id: "wrong-session"))
    check("Claude mismatched row ID cannot rename current session", reader.snapshot(root: root)?[key] == "后来改名")
    append("{bad-json}\n" + body)
    check("Claude corrupt or message rows cannot erase valid name", reader.snapshot(root: root)?[key] == "后来改名")
    let partial = row("半行完成后的名称")
    append(String(partial.dropLast(2)))
    check("Claude partial rename keeps last valid title", reader.snapshot(root: root)?[key] == "后来改名")
    append(String(partial.suffix(2)))
    check("Claude next append completes the pending metadata row", reader.snapshot(root: root)?[key] == "半行完成后的名称")
    append(row("两行\n不可展示"))
    check("Claude multiline name never becomes prompt fallback", reader.snapshot(root: root)?[key] == nil)
    append(row(""))
    check("Claude cleared name removes stale title", reader.snapshot(root: root)?[key] == nil)
    append(row("恢复的标题"))
    check("Claude name recovers without source rewrites", reader.snapshot(root: root)?[key] == "恢复的标题")
    let multibyte = "a" + String(repeating: "中", count: 40)
    append(row(multibyte))
    check("Claude header slicing cannot drop a valid Chinese title", reader.snapshot(root: root)?[key] == multibyte)
    write(row("截断重写的新名称"))
    check("Claude truncation or atomic replacement resets old cache", reader.snapshot(root: root)?[key] == "截断重写的新名称")
    let unnamed = project.appendingPathComponent("unnamed.jsonl")
    write(body + "{\"type\":\"summary\",\"summary\":\"摘要不是桌面标题\"}\n", at: unnamed)
    check("Claude no explicit metadata never uses prompt or summary", reader.snapshot(root: root)?[ConversationTitles.sessionKey(provider: .claude, rawID: "unnamed")] == nil)
    let nested = project.appendingPathComponent("subagents")
    try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    write(row("子智能体标题", id: "child"), at: nested.appendingPathComponent("child.jsonl"))
    check("Claude nested subagents are not conversations", reader.snapshot(root: root)?.count == 1)
    let linked = project.appendingPathComponent("linked.jsonl")
    try? FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file)
    check("Claude symlink sources are excluded", reader.snapshot(root: root)?.count == 1)
    let large = String(repeating: "x", count: 1_000_000)
    write("{\"type\":\"user\",\"content\":\"\(large)\"}\n" + row("大消息后的真标题"))
    check("Claude huge body is skipped without losing following title", reader.snapshot(root: root)?[key] == "大消息后的真标题")
    var cold = ClaudeConversationTitles()
    check("Claude initial stream also resolves huge-file title", cold.snapshot(root: root)?[key] == "大消息后的真标题")
    try? FileManager.default.removeItem(at: file)
    check("Claude deleted metadata clears a successful snapshot", reader.snapshot(root: root) == [:])
    let missing = root.appendingPathComponent("missing")
    check("Claude missing source is unavailable not empty success", reader.snapshot(root: missing) == nil)
    check("Claude missing source is never created", !FileManager.default.fileExists(atPath: missing.path))
}
