import Foundation
import Darwin

/// Follows Claude Desktop's own main.log for the lifecycle of its permission
/// cards. Desktop writes one line when a card is actually shown and one when it
/// is answered or aborted; auto-approved checks write nothing. Only request IDs,
/// tool names, session IDs and timestamps are kept, never any other log text.
public struct ClaudePromptLog {
    public struct Prompt: Equatable, Sendable {
        public var id: String
        public var tool: String
        public var session: String
        public var shownAt: Date
    }

    public struct Resolution: Equatable, Sendable {
        public var decision: String // once, always, deny or aborted
        public var at: Date
    }

    public private(set) var open: [String: Prompt] = [:]
    public private(set) var resolved: [String: Resolution] = [:]
    private var followers: [Follower]

    /// Claude-3p is the gateway build; Claude is the standard build.
    public static var defaultURLs: [URL] {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return ["Claude-3p", "Claude"].map { logs.appendingPathComponent($0).appendingPathComponent("main.log") }
    }

    public init(urls: [URL] = ClaudePromptLog.defaultURLs) {
        followers = urls.map { Follower(url: $0) }
    }

    /// Reads appended lines; returns true when the open set or a resolution changed.
    public mutating func poll(now: Date = Date()) -> Bool {
        var changed = false
        for index in followers.indices {
            for line in followers[index].readNewLines() where ingest(line) { changed = true }
        }
        // Cards from a previous app run or a missed resolution must not linger.
        let stale = open.filter { now.timeIntervalSince($0.value.shownAt) > ApprovalRelay.hostPromptLifetime }
        for id in stale.keys { open.removeValue(forKey: id); changed = true }
        if resolved.count > 200 {
            for (id, _) in resolved.sorted(by: { $0.value.at < $1.value.at }).prefix(resolved.count - 100) {
                resolved.removeValue(forKey: id)
            }
        }
        return changed
    }

    public func openPrompts(in session: String) -> [Prompt] {
        open.values.filter { $0.session == session }
    }

    private static let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private static let shown = try! NSRegularExpression(pattern:
        "^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}) \\[info\\] Emitted tool permission request (\(uuid)) for ([A-Za-z0-9_.:-]{1,120}) in session (local_\(uuid))$")
    private static let answered = try! NSRegularExpression(pattern:
        "^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}) \\[info\\] Received permission response for (\(uuid)): ([a-z]{1,16}) \\(tool: ")
    private static let aborted = try! NSRegularExpression(pattern:
        "^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}) \\[info\\] Permission request (\(uuid)) for [A-Za-z0-9_.:-]{1,120} aborted$")
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    @discardableResult
    public mutating func ingest(_ line: String) -> Bool {
        guard line.contains("ermission") else { return false }
        let range = NSRange(line.startIndex..., in: line)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
        if let match = Self.shown.firstMatch(in: line, range: range),
           let date = Self.clock.date(from: group(match, 1)) {
            let id = group(match, 2)
            guard resolved[id] == nil else { return false }
            open[id] = Prompt(id: id, tool: group(match, 3), session: group(match, 4), shownAt: date)
            return true
        }
        for (pattern, decisionGroup) in [(Self.answered, 3), (Self.aborted, 0)] {
            guard let match = pattern.firstMatch(in: line, range: range),
                  let date = Self.clock.date(from: group(match, 1)) else { continue }
            let id = group(match, 2)
            resolved[id] = Resolution(decision: decisionGroup == 0 ? "aborted" : group(match, decisionGroup), at: date)
            open.removeValue(forKey: id)
            return true
        }
        return false
    }

    /// Tail-follows one file across rotation (Desktop renames main.log away).
    private struct Follower {
        let url: URL
        var offset: off_t = -1
        var inode: ino_t = 0
        var partial = Data()

        mutating func readNewLines() -> [String] {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { return [] }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return [] }
            if offset < 0 {
                // First look: recent history only, enough to recover cards open right now.
                offset = max(0, info.st_size - 524_288)
                inode = info.st_ino
            } else if info.st_ino != inode || info.st_size < offset {
                offset = 0
                inode = info.st_ino
                partial.removeAll()
            }
            guard info.st_size > offset else { return [] }
            let length = Int(min(info.st_size - offset, 4_194_304))
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, offset) }
            guard read > 0 else { return [] }
            offset += off_t(read)
            partial.append(data.prefix(read))
            guard let end = partial.lastIndex(of: 0x0A) else {
                if partial.count > 65_536 { partial.removeAll() }
                return []
            }
            let complete = partial[partial.startIndex..<end]
            partial = Data(partial[partial.index(after: end)...])
            return String(decoding: complete, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
    }
}
