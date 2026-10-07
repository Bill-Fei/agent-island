import Foundation
import LinglongtaiShared
import SQLite3

/// Title-only fixtures: no personal databases, Hook writes or provider calls.
func runWorkBuddyTitleRevisionChecks(check: (String, Bool) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("island-wb-titles-" + UUID().uuidString)
    do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    catch { check("WB title fixture directory opens", false); return }
    defer { try? FileManager.default.removeItem(at: root) }
    let database = root.appendingPathComponent("workbuddy.db")
    var connection: OpaquePointer?
    guard sqlite3_open(database.path, &connection) == SQLITE_OK else {
        if let connection { sqlite3_close(connection) }
        check("WB title fixture database opens", false)
        return
    }
    defer { sqlite3_close(connection) }
    func sql(_ command: String) -> Bool { sqlite3_exec(connection, command, nil, nil, nil) == SQLITE_OK }
    check("WB title fixture schema creates", sql("CREATE TABLE sessions(id TEXT PRIMARY KEY, custom_title TEXT, title TEXT, deleted_at INTEGER, updated_at INTEGER, prompt TEXT);"))
    check("WB title fixture rows insert", sql("""
        INSERT INTO sessions VALUES('renamed','我的真实名称','自动名称',NULL,10,'PRIVATE_PROMPT_SENTINEL');
        INSERT INTO sessions VALUES('automatic',NULL,'自动会话名称',NULL,9,'PRIVATE_PROMPT_SENTINEL');
        INSERT INTO sessions VALUES('blank','  ','空重命名的回退标题',NULL,8,'PRIVATE_PROMPT_SENTINEL');
        INSERT INTO sessions VALUES('invalid','两行' || char(10) || '文本','有效标题',NULL,7,'PRIVATE_PROMPT_SENTINEL');
        INSERT INTO sessions VALUES('untitled',NULL,NULL,NULL,6,'不得当作标题');
        INSERT INTO sessions VALUES('deleted','已删除',NULL,1,5,'PRIVATE_PROMPT_SENTINEL');
        INSERT INTO sessions VALUES('invalid-id' || char(10),NULL,'无效标识',NULL,4,'PRIVATE_PROMPT_SENTINEL');
        """))
    func key(_ id: String) -> String { ConversationTitles.sessionKey(provider: .workBuddy, rawID: id) }
    let titles = ConversationTitles.workBuddySnapshot(database: database)
    check("WB custom title takes precedence over automatic title", titles?[key("renamed")] == "我的真实名称")
    check("WB automatic title is used without a custom name", titles?[key("automatic")] == "自动会话名称")
    check("WB blank custom name falls back to title metadata", titles?[key("blank")] == "空重命名的回退标题")
    check("WB multiline custom name never leaks into display", titles?[key("invalid")] == "有效标题")
    check("WB untitled session never falls back to the prompt", titles?[key("untitled")] == nil)
    check("WB deleted sessions are excluded", titles?[key("deleted")] == nil)
    check("WB invalid session identities are rejected", titles?.count == 4)
    check("WB raw IDs and prompt contents are absent from title snapshots", titles?.keys.contains("renamed") == false && titles?.values.contains("PRIVATE_PROMPT_SENTINEL") == false)
    let mapped = HookEventMapper.map(provider: .workBuddy, payload: Data("{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"renamed\"}".utf8))
    check("WB database identity exactly matches its Hook identity", mapped?.sessionID == key("renamed"))
    let task = AgentTask(agent: "WorkBuddy", title: "WorkBuddy 会话", status: .running,
                         detail: "fixture", model: "fixture", sessionID: key("renamed"))
    check("WB existing generic history resolves the exact session name", ConversationTitles.display(task: task, titles: titles ?? [:]) == "我的真实名称")
    check("WB another session never borrows a title", ConversationTitles.display(task: task, titles: [key("other"): "错误会话"]).hasPrefix("未提供会话标题"))
    check("WB same raw ID cannot collide with Codex", key("renamed") != ConversationTitles.sessionKey(provider: .codex, rawID: "renamed"))
    check("WB does not consume a Codex title with the same raw ID", ConversationTitles.display(task: task, titles: [ConversationTitles.sessionKey(provider: .codex, rawID: "renamed"): "Codex名称"]).hasPrefix("未提供会话标题"))
    var explicit = task
    explicit.title = "调用方明确指定的任务名"
    check("WB explicit task names remain unchanged", ConversationTitles.display(task: explicit, titles: titles ?? [:]) == explicit.title)
    check("WB title read is actually read-only", (try? Data(contentsOf: database)).map { before in
        _ = ConversationTitles.workBuddySnapshot(database: database)
        return (try? Data(contentsOf: database)) == before
    } == true)
    check("WB rename fixture updates", sql("UPDATE sessions SET custom_title='改名后的标题', updated_at=11 WHERE id='renamed';"))
    check("WB refresh reflects user renaming", ConversationTitles.workBuddySnapshot(database: database)?[key("renamed")] == "改名后的标题")
    check("WB cleared rename falls back to the app title", sql("UPDATE sessions SET custom_title=NULL WHERE id='renamed';") && ConversationTitles.workBuddySnapshot(database: database)?[key("renamed")] == "自动名称")
    check("WB removed titles yield a successful empty snapshot", sql("DELETE FROM sessions;") && ConversationTitles.workBuddySnapshot(database: database) == [:])
    let missing = root.appendingPathComponent("missing.db")
    check("WB unavailable DB returns nil, not a successful empty snapshot", ConversationTitles.workBuddySnapshot(database: missing) == nil)
    check("WB read-only open never creates a missing DB", !FileManager.default.fileExists(atPath: missing.path))
    check("WB unsupported schema fails closed", sql("DROP TABLE sessions;") && ConversationTitles.workBuddySnapshot(database: database) == nil)
}
