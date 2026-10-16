import Foundation
import Darwin

/// Follows the Codex desktop app's own log for the moment the user answers an
/// approval card there. Codex sends no hook for that answer, so without it the
/// island would keep showing a prompt that is already gone.
///
/// Lines used (`~/Library/Logs/com.openai.codex/YYYY/MM/DD/*.log`):
/// - `[desktop-notifications] received approval conversationId=<id> … requestId=<n>`
/// - `Sending server response id=<n> method=item/<kind>/requestApproval … response={"decision":"<d>"}`
/// Only timestamps, the conversation's digest, request numbers and the decision
/// word are kept; never commands or any other log text.
public struct CodexAppLog {
    public struct Answer: Equatable, Sendable {
        public var at: Date
        /// Session digest (see CodexRollout.sessionDigest), when Codex logged the card.
        public var session: String?
        public var accepted: Bool
    }

    public private(set) var answers: [Answer] = []
    private var requestSessions: [String: String] = [:]
    private var offsets: [String: off_t] = [:]
    private let root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/com.openai.codex")) {
        self.root = root
    }

    private static let received = try! NSRegularExpression(pattern:
        #"\[desktop-notifications\] received approval conversationId=([0-9a-fA-F-]{36}) .*?requestId=(\d{1,9})"#)
    private static let response = try! NSRegularExpression(pattern:
        #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z) \w+ \[electron-message-handler\] Sending server response id=(\d{1,9}) method=item/[A-Za-z]{1,40}/requestApproval .*?response=\{"decision":"([a-zA-Z]{1,24})""#)

    /// Reads lines appended since the last call; drops answers older than `keep`.
    public mutating func poll(now: Date = Date(), keep: TimeInterval = 120) {
        answers.removeAll { now.timeIntervalSince($0.at) > keep }
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return }
        let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, day))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for name in names where name.hasSuffix(".log") {
            for line in readNewLines(folder.appendingPathComponent(name)) where line.contains("pproval") {
                let range = NSRange(line.startIndex..., in: line)
                func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
                    Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
                }
                if let match = Self.received.firstMatch(in: line, range: range) {
                    requestSessions[group(match, 2)] = CodexRollout.sessionDigest(rawSessionID: group(match, 1).lowercased())
                } else if let match = Self.response.firstMatch(in: line, range: range),
                          let at = formatter.date(from: group(match, 1)) {
                    let decision = group(match, 3)
                    answers.append(Answer(at: at, session: requestSessions[group(match, 2)],
                                          accepted: ["accept", "acceptForSession", "approved", "allow"].contains(decision)))
                }
            }
        }
        if requestSessions.count > 64 { requestSessions.removeAll() }
    }

    private mutating func readNewLines(_ url: URL) -> [String] {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return [] }
        // First look: the recent tail only, enough for a card still open now.
        var offset = offsets[url.path] ?? max(0, info.st_size - 262_144)
        if info.st_size < offset { offset = 0 }
        guard info.st_size > offset else { offsets[url.path] = offset; return [] }
        let length = Int(min(info.st_size - offset, 4_194_304))
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, offset) }
        guard read > 0 else { return [] }
        let chunk = data.prefix(read)
        // Keep a trailing partial line for the next read.
        guard let end = chunk.lastIndex(of: 0x0A) else { return [] }
        offsets[url.path] = offset + off_t(end + 1)
        return String(decoding: chunk[chunk.startIndex..<end], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
