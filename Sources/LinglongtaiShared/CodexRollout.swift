import Foundation
import Darwin
import SQLite3

public enum ActivityEvidence: Equatable {
    case completed
    case cancelled
    case failed
    case observed
    case unavailable
    case missingSession
}

/// Backup signal for an approval answered in the Codex app (CodexAppLog is primary).
/// Codex sends no hook when the user approves in its own card; the turn just
/// carries on. Its local rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`)
/// shows that: a new tool call or tool result after the request. Only each
/// line's timestamp and entry type are read, never commands, output or text.
///
/// Rollout file names carry the raw session ID; the island only keeps its
/// digest, so files are matched by recomputing that digest (HookEventMapper).
public struct CodexRollout {
    private var files: [String: URL] = [:] // session digest -> rollout
    private var lastScan = Date.distantPast
    private var indexedSessions: (ids: Set<String>, paths: [String: URL])?
    private var lastIndexScan = Date.distantPast
    private var activityCache: [String: (url: URL, size: off_t, modified: timespec, evidence: ActivityEvidence)] = [:]
    private let root: URL

    private struct RolloutEntry: Decodable {
        let type: String
        let payload: Payload

        struct Payload: Decodable {
            let type: String?
            let id: String?
            let turnID: String?
            let hasError: Bool

            enum CodingKeys: String, CodingKey {
                case type, id, error
                case turnID = "turn_id"
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                type = try values.decodeIfPresent(String.self, forKey: .type)
                id = try values.decodeIfPresent(String.self, forKey: .id)
                turnID = try values.decodeIfPresent(String.self, forKey: .turnID)
                hasError = values.contains(.error) && ((try? values.decodeNil(forKey: .error)) == false)
            }
        }
    }

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")) {
        self.root = root
    }

    public static func sessionDigest(rawSessionID: String) -> String {
        "s_" + IdentityDigest.digest(namespace: "session-v2", components: [AgentKind.codex.rawValue, rawSessionID])
    }

    /// True when the session's rollout records a tool call or tool result
    /// later than `since` + 2 s (entries written while the card is being
    /// shown land within that margin).
    public mutating func progressed(session: String?, since: Date, now: Date = Date()) -> Bool {
        guard let session, let url = rollout(for: session, now: now) else { return false }
        return Self.progressed(in: url, since: since.addingTimeInterval(2))
    }

    /// Lifecycle evidence for exactly one hook turn. Missing or truncated evidence
    /// is unknown, never a completion signal.
    public mutating func activity(session: String, turn: String, now: Date) -> ActivityEvidence {
        guard session.hasPrefix("s_"), turn.hasPrefix("t_") else { return .unavailable }
        guard let url = rollout(for: session, now: now, includeIndex: true) else {
            guard let indexedSessions else { return .unavailable }
            return indexedSessions.ids.contains(session) ? .unavailable : .missingSession
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base) else { return .unavailable }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .unavailable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0 else { return .unavailable }
        let key = session + ":" + turn
        if let cached = activityCache[key], cached.url == url, cached.size == info.st_size,
           cached.modified.tv_sec == info.st_mtimespec.tv_sec,
           cached.modified.tv_nsec == info.st_mtimespec.tv_nsec {
            return cached.evidence
        }
        let evidence = Self.activity(in: fd, size: info.st_size, session: session, turn: turn, url: url)
        if activityCache.count >= 32 { activityCache.removeAll() }
        activityCache[key] = (url, info.st_size, info.st_mtimespec, evidence)
        return evidence
    }

    private mutating func rollout(for session: String, now: Date, includeIndex: Bool = false) -> URL? {
        if let url = files[session] { return url }
        // A new session's file appears with its first turn; rescan sparingly.
        if now.timeIntervalSince(lastScan) > 10 || now < lastScan {
            lastScan = now
            let calendar = Calendar(identifier: .gregorian)
            for offset in 0...1 {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                guard let year = parts.year, let month = parts.month, let date = parts.day else { continue }
                let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, date))
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                    let stem = name.dropLast(6)
                    guard stem.count >= 36, UUID(uuidString: String(stem.suffix(36))) != nil else { continue }
                    files[Self.sessionDigest(rawSessionID: String(stem.suffix(36)).lowercased())] = folder.appendingPathComponent(name)
                }
            }
        }
        if let url = files[session] { return url }
        guard includeIndex else { return nil }
        if indexedSessions == nil || now.timeIntervalSince(lastIndexScan) > 10 || now < lastIndexScan {
            lastIndexScan = now
            indexedSessions = Self.indexedRollouts(database: root.deletingLastPathComponent().appendingPathComponent("state_5.sqlite"))
        }
        return indexedSessions?.paths[session]
    }

    private static func indexedRollouts(database: URL) -> (ids: Set<String>, paths: [String: URL])? {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            return nil
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 100)
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "SELECT id, rollout_path FROM threads", -1, &query, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(query) }
        var ids: Set<String> = []
        var paths: [String: URL] = [:]
        let base = database.deletingLastPathComponent().appendingPathComponent("sessions").standardizedFileURL.path + "/"
        var count = 0
        var result = sqlite3_step(query)
        while result == SQLITE_ROW && count < 65_536 {
            count += 1
            if let id = sqlite3_column_text(query, 0) {
                let raw = String(cString: id).lowercased()
                if UUID(uuidString: raw) != nil {
                    let digest = sessionDigest(rawSessionID: raw)
                    ids.insert(digest)
                    if let path = sqlite3_column_text(query, 1) {
                        let url = URL(fileURLWithPath: String(cString: path)).standardizedFileURL
                        if url.path.hasPrefix(base), url.lastPathComponent.hasPrefix("rollout-"),
                           url.lastPathComponent.lowercased().hasSuffix(raw + ".jsonl") {
                            paths[digest] = url
                        }
                    }
                }
            }
            result = sqlite3_step(query)
        }
        return result == SQLITE_DONE ? (ids, paths) : nil
    }

    private static func activity(in fd: Int32, size: off_t, session: String, turn: String, url: URL) -> ActivityEvidence {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count >= 36 else { return .unavailable }
        let rawSession = String(stem.suffix(36)).lowercased()
        guard UUID(uuidString: rawSession) != nil, sessionDigest(rawSessionID: rawSession) == session else { return .unavailable }
        let headerLength = Int(min(size, 131_072))
        var header = Data(count: headerLength)
        guard header.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, headerLength, 0) }) == headerLength,
              header.split(separator: 0x0A).contains(where: { line in
                  guard line.count <= 131_072,
                        let entry = try? JSONDecoder().decode(RolloutEntry.self, from: Data(line)) else { return false }
                  return entry.type == "session_meta" && entry.payload.id?.lowercased() == rawSession
              }) else { return .unavailable }

        let length = Int(min(size, 8_388_608))
        var data = Data(count: length)
        guard data.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, length, size - off_t(length)) }) == length else { return .unavailable }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if size > off_t(length) { lines.removeFirst() }
        if data.last != 0x0A { lines.removeLast() }
        for line in lines.reversed() {
            let prefix = line.prefix(512)
            guard prefix.range(of: Data(#""type":"event_msg","payload":{"type":"# .utf8)) != nil,
                  let event = try? JSONDecoder().decode(RolloutEntry.self, from: Data(line)),
                  event.type == "event_msg", let rawTurn = event.payload.turnID,
                  UUID(uuidString: rawTurn) != nil,
                  let kind = event.payload.type,
                  "t_" + IdentityDigest.digest(namespace: "turn-v2", components: [session, rawTurn]) == turn else { continue }
            switch kind {
            case "task_complete": return event.payload.hasError ? .failed : .completed
            case "turn_aborted": return .cancelled
            case "task_started": return .observed
            default: continue
            }
        }
        return .unavailable
    }

    /// True when the session's latest turn lets Codex review approvals itself
    /// (the app's "帮我批准", `approvals_reviewer = auto_review`). Codex still
    /// runs PermissionRequest hooks then, but never asks the user, so the
    /// island must not ask either. Only that one setting is read.
    public static func reviewsApprovalsItself(hookInput payload: Data, root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"), now: Date = Date()) -> Bool {
        guard let input = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        if let path = input["transcript_path"] as? String {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            if url.path.hasPrefix(base), url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" {
                return reviewer(in: url) == "auto_review"
            }
        }
        guard let session = (input["session_id"] as? String)?.lowercased(), UUID(uuidString: session) != nil else { return false }
        let calendar = Calendar(identifier: .gregorian)
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let date = parts.day else { continue }
            let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, date))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if let name = names.first(where: { $0.hasPrefix("rollout-") && $0.lowercased().hasSuffix(session + ".jsonl") }) {
                return reviewer(in: folder.appendingPathComponent(name)) == "auto_review"
            }
        }
        return false
    }

    /// `approvals_reviewer` of the last `turn_context`, read backwards in 1 MB
    /// chunks (a long turn's output can push it many MB back; capped at 64 MB).
    /// Lines without the marker are never parsed.
    static func reviewer(in url: URL) -> String? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return nil }
        let marker = Data(#""type":"turn_context""#.utf8)
        let chunk: off_t = 1_048_576
        var end = info.st_size
        var tail = Data() // partial first line of the chunk read before
        while end > 0, info.st_size - end < 67_108_864 {
            let start = max(0, end - chunk)
            var data = Data(count: Int(end - start))
            let count = data.count
            guard data.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, count, start) }) == count else { return nil }
            data.append(tail)
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            // The first piece may continue in the previous chunk; keep it for the next round.
            tail = start > 0 ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() where line.range(of: marker) != nil {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["type"] as? String == "turn_context" else { continue }
                return (object["payload"] as? [String: Any])?["approvals_reviewer"] as? String
            }
            end = start
        }
        return nil
    }

    /// A new script only. While an approval blocks, Codex keeps polling the
    /// blocked cell (`function_call` "wait" and its outputs), so those prove nothing.
    private static let progressTypes: Set<String> = ["custom_tool_call"]

    /// Reads at most the last 256 KB; only `timestamp` / `type` / `payload.type`.
    static func progressed(in url: URL, since: Date) -> Bool {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return false }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        guard modified.addingTimeInterval(1) > since else { return false }
        let length = Int(min(info.st_size, 262_144))
        guard length > 0 else { return false }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, info.st_size - off_t(length)) }
        guard read == length else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let stamp = (object["timestamp"] as? String).flatMap(formatter.date(from:)) else { continue }
            if stamp <= since { return false }
            if object["type"] as? String == "response_item",
               let type = (object["payload"] as? [String: Any])?["type"] as? String, progressTypes.contains(type) {
                return true
            }
        }
        return false
    }
}
