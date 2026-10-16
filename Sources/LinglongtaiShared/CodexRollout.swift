import Foundation
import Darwin

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
    private let root: URL

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

    private mutating func rollout(for session: String, now: Date) -> URL? {
        if let url = files[session] { return url }
        // A new session's file appears with its first turn; rescan sparingly.
        guard now.timeIntervalSince(lastScan) > 10 else { return nil }
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
        return files[session]
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
