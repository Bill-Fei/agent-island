import Foundation
import SQLite3

/// Reads title metadata only. Never reads prompts, rollouts or tool arguments.
public enum ConversationTitles {
    public static func sessionKey(provider: AgentKind, rawID: String) -> String {
        "s_" + IdentityDigest.digest(namespace: "session-v2", components: [provider.rawValue, rawID])
    }

    public static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 4096,
              !title.contains("\n"), !title.contains("\r") else { return nil }
        return title
    }

    public static func codex(database: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite")) -> [String: String] {
        codexSnapshot(database: database) ?? [:]
    }

    public static func codexSnapshot(database: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite")) -> [String: String]? {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            return nil
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 100)
        var query: OpaquePointer?
        // name is the desktop display title; title can instead hold a raw prompt.
        guard sqlite3_prepare_v2(connection, "SELECT id, name FROM threads ORDER BY updated_at DESC LIMIT 4096", -1, &query, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(query) }
        var titles: [String: String] = [:]
        var step = sqlite3_step(query)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(query) }
            guard let id = sqlite3_column_text(query, 0), let name = sqlite3_column_text(query, 1),
                  let title = clean(String(cString: name)) else { continue }
            titles[sessionKey(provider: .codex, rawID: String(cString: id))] = title
        }
        return step == SQLITE_DONE ? titles : nil
    }

    /// WorkBuddy stores its display title separately from conversation content.
    /// Use the same raw session ID as its Hook, scoped to the provider. A nil
    /// snapshot means unavailable; an empty snapshot is a successful refresh.
    public static func workBuddySnapshot(database: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".workbuddy/workbuddy.db")) -> [String: String]? {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            return nil
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 100)
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(connection,
            "SELECT id, custom_title, title FROM sessions WHERE deleted_at IS NULL ORDER BY updated_at DESC LIMIT 4096",
            -1, &query, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(query) }
        var titles: [String: String] = [:]
        var step = sqlite3_step(query)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(query) }
            guard let rawID = sqlite3_column_text(query, 0) else { continue }
            let id = String(cString: rawID)
            guard clean(id) != nil, id.utf8.count <= 256,
                  !id.contains("\n"), !id.contains("\r") else { continue }
            let customTitle = sqlite3_column_text(query, 1).map { String(cString: $0) }
            let title = sqlite3_column_text(query, 2).map { String(cString: $0) }
            guard let displayTitle = clean(customTitle) ?? clean(title) else { continue }
            titles[sessionKey(provider: .workBuddy, rawID: id)] = displayTitle
        }
        return step == SQLITE_DONE ? titles : nil
    }

    public static func display(task: AgentTask, titles: [String: String]) -> String {
        let generic = ["Codex 会话", "Claude Code 会话", "Claude 会话", "WorkBuddy 会话", "豆包 Agent 会话", "豆包 会话"]
        if task.profile.kind == .codex || ([AgentKind.workBuddy, .claude].contains(task.profile.kind) && generic.contains(task.title)),
           let session = task.sessionID, let title = titles[session] { return title }
        if generic.contains(task.title) {
            let identity = task.sessionID.map { String($0.suffix(6)) } ?? String(task.id.uuidString.prefix(6))
            return "未提供会话标题 · " + identity
        }
        return task.title
    }
}
