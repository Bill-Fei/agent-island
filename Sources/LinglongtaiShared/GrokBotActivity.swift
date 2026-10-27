import Foundation

/// Read-only observer for the Grok Bot desktop app.
///
/// Why this exists: Grok Bot exposes no hook, no CLI event and no approval
/// channel. Its Electron client nevertheless keeps a local replica of each
/// conversation under `sand-client-persistence/`. This adapter reads that
/// replica instead of asking the app to report itself.
///
/// Hard limits, deliberately not worked around:
///   - Only entry `kind`, `role`, `message.type`, `timestampMs`, `isStreaming`
///     and the presence of reactions and widget/secret answers are read. Message text, rich
///     text, attachments, file names and automation names are never stored,
///     compared or logged.
///   - Nothing can be written back: the island can *show* Grok Bot but can
///     never reply, approve or cancel.
///   - There is no explicit end-of-turn marker. A turn is reported finished
///     only after the bot has replied and then stayed quiet; silence without
///     any reply is reported as unknown, never completed.
public enum GrokBotActivity {

    public static let defaultRoot: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grok Bot/sand-client-persistence", isDirectory: true)
    }()

    /// Same freshness rules as Doubao: never resurrect old chats on launch.
    public static let adoptAfter: TimeInterval = 600
    /// A turn with no reply for this long is no longer evidence of progress.
    public static let staleAfter: TimeInterval = 240
    public static let abandonAfter: TimeInterval = 1_200
    /// The bot often sends several messages in a row, 10–30 s apart. A reply
    /// only ends the turn once nothing new has arrived for this long.
    public static let settleAfter: TimeInterval = 45
    public static let trackedSessionLimit = 2
    /// Replicas are tens of KB; anything far larger is not what we expect.
    static let maxFileBytes = 8 * 1024 * 1024

    static let transcriptMarker = ".transcript.replicas."

    public struct Observation: Sendable, Equatable {
        public let sessionKey: String
        /// Entry id of the latest user message. Identifies a turn without
        /// reading the message itself.
        public let turnKey: String
        public let userAt: Date
        public let lastActivityAt: Date
        public let replied: Bool
        public let streaming: Bool
        /// The bot asked a question (widget / secret request) still unanswered.
        public let awaitingUser: Bool
        public var acknowledged: Bool = false
    }

    public enum Phase: Sendable, Equatable {
        case running(replying: Bool)
        case finished(awaitingUser: Bool)
        case unknown(quiet: TimeInterval)

        public var status: AgentTaskStatus {
            switch self {
            case .running, .unknown: return .running
            case .finished: return .completed
            }
        }

        public var detail: String {
            switch self {
            case .running(let replying):
                return replying ? "正在回复" : "已收到你的请求，正在处理"
            case .finished(let awaiting):
                return awaiting ? "等你在 Grok Bot 里回复" : "本轮响应已结束"
            case .unknown(let quiet):
                let minutes = max(1, Int(quiet / 60))
                return "已 \(minutes) 分钟无新记录，状态未知"
            }
        }

        public var sourceEvent: String {
            switch self {
            case .running: return "GrokBotTurn"
            case .finished: return "GrokBotStop"
            case .unknown: return "GrokBotSilent"
            }
        }
    }

    // MARK: - Discovery

    /// Persistence file names are base32 (RFC 4648, lowercase, unpadded) of a
    /// storage key such as `sand.client.slice.account.<id>.transcript.replicas.<agent>`.
    static func decodeKey(_ fileName: String) -> String? {
        guard fileName.hasSuffix(".blob") else { return nil }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var lookup: [Character: UInt32] = [:]
        for (index, character) in alphabet.enumerated() { lookup[character] = UInt32(index) }
        var buffer: UInt32 = 0
        var bits = 0
        var bytes: [UInt8] = []
        for character in fileName.dropLast(5) {
            guard let value = lookup[character] else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Conversation replicas, newest first. The session key is the agent id,
    /// which is a UUID and carries no user content.
    public static func transcriptFiles(root: URL = defaultRoot) -> [(key: String, url: URL)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var found: [(String, URL, Date)] = []
        for name in names {
            guard let key = decodeKey(name), let range = key.range(of: transcriptMarker) else { continue }
            let agent = String(key[range.upperBound...])
            guard UUID(uuidString: agent) != nil else { continue }
            let url = root.appendingPathComponent(name)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            found.append((agent, url, date))
        }
        return found.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }.map { ($0.0, $0.1) }
    }

    // MARK: - Parsing

    public static func observation(sessionKey: String, data: Data) -> Observation? {
        guard data.count <= maxFileBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["value"] as? [String: Any],
              let entries = value["entries"] as? [[String: Any]] else { return nil }
        guard let userIndex = entries.lastIndex(where: {
            $0["kind"] as? String == "message" && $0["role"] as? String == "user"
        }), let turnKey = entries[userIndex]["id"] as? String,
              let userMs = entries[userIndex]["timestampMs"] as? Double else { return nil }
        var lastMs = userMs
        var replied = false
        var streaming = false
        var awaiting = false
        // The bot often answers a short "OK" with only an emoji reaction on the
        // user's message. That is the end of the turn, not work in progress.
        let reactions = entries[userIndex]["reactions"]
        let reacted = (reactions as? [Any])?.isEmpty == false || (reactions as? [String: Any])?.isEmpty == false
        for entry in entries[userIndex...] {
            if let ms = entry["timestampMs"] as? Double { lastMs = max(lastMs, ms) }
            if entry["isStreaming"] as? Bool == true { streaming = true }
            guard entry["kind"] as? String == "send-message" else { continue }
            replied = true
            switch (entry["message"] as? [String: Any])?["type"] as? String {
            case "widget":
                if entry["respondedValue"] == nil && entry["widgetSkipped"] as? Bool != true { awaiting = true }
            case "secret-request":
                if entry["secretProvided"] as? Bool != true { awaiting = true }
            default:
                break
            }
        }
        // A reaction with no text after it is the bot's whole answer.
        let acknowledged = reacted && !replied
        return Observation(sessionKey: sessionKey, turnKey: turnKey,
                           userAt: Date(timeIntervalSince1970: userMs / 1000),
                           lastActivityAt: Date(timeIntervalSince1970: lastMs / 1000),
                           replied: replied || acknowledged, streaming: streaming, awaitingUser: awaiting,
                           acknowledged: acknowledged)
    }

    public static func phase(of observation: Observation, now: Date) -> Phase {
        let quiet = max(0, now.timeIntervalSince(observation.lastActivityAt))
        if observation.awaitingUser { return .finished(awaitingUser: true) }
        if observation.acknowledged { return .finished(awaitingUser: false) }
        if observation.streaming || !observation.replied {
            return quiet >= staleAfter ? .unknown(quiet: quiet) : .running(replying: observation.streaming)
        }
        return quiet >= settleAfter ? .finished(awaitingUser: false) : .running(replying: true)
    }

    // MARK: - Events

    public static func event(for observation: Observation, now: Date) -> AgentEvent {
        let phase = phase(of: observation, now: now)
        let sessionID = "s_" + IdentityDigest.digest(namespace: "grok-bot-session-v1", components: [observation.sessionKey])
        let turnID = "t_" + IdentityDigest.digest(namespace: "grok-bot-turn-v1", components: [sessionID, observation.turnKey])
        let kind = AgentKind.grokBot
        return AgentEvent(
            type: "upsert",
            id: IdentityDigest.uuid(namespace: "grok-bot-task-v1", components: [sessionID, turnID]),
            agent: kind.displayName,
            title: "Grok Bot 会话",
            status: phase.status,
            detail: phase.detail,
            model: kind.defaultModel,
            requiresApproval: false,
            colorHex: kind.colorHex,
            createdAt: observation.lastActivityAt,
            sourceEvent: phase.sourceEvent,
            sessionID: sessionID,
            turnID: turnID
        )
    }
}

/// Remembers what was already reported so a timer can poll without re-applying
/// identical state. Keeps only a coarse signature, never entry content.
public struct GrokBotTracker: Sendable {
    private var seen: [String: String] = [:]
    private struct Cached: Sendable {
        let size: Int
        let modifiedAt: Date
        let observation: GrokBotActivity.Observation?
    }
    private var files: [URL: Cached] = [:]

    public init() {}

    public mutating func poll(root: URL = GrokBotActivity.defaultRoot, now: Date = Date()) -> [AgentEvent] {
        var changed: [AgentEvent] = []
        var alive: Set<String> = []
        let tracked = Array(GrokBotActivity.transcriptFiles(root: root).prefix(GrokBotActivity.trackedSessionLimit))
        for (key, url) in tracked {
            guard let metadata = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = metadata.fileSize, let modifiedAt = metadata.contentModificationDate else { continue }
            if files[url]?.size != size || files[url]?.modifiedAt != modifiedAt {
                let value = size <= GrokBotActivity.maxFileBytes
                    ? (try? Data(contentsOf: url)).flatMap { GrokBotActivity.observation(sessionKey: key, data: $0) }
                    : nil
                files[url] = Cached(size: size, modifiedAt: modifiedAt, observation: value ?? files[url]?.observation)
            }
            guard let observation = files[url]?.observation else { continue }
            alive.insert(key)
            let phase = GrokBotActivity.phase(of: observation, now: now)
            let quiet = now.timeIntervalSince(observation.lastActivityAt)
            // Re-report silence each minute so "2 minutes quiet" can grow and
            // the settle window can turn a reply into a finished turn.
            let bucket: Int
            if case .unknown = phase { bucket = min(Int(quiet / 60), Int(GrokBotActivity.abandonAfter / 60)) } else { bucket = 0 }
            let signature = "\(observation.turnKey):\(phase.sourceEvent):\(phase.detail):\(observation.lastActivityAt.timeIntervalSince1970):\(bucket)"
            guard seen[key] != signature else { continue }
            if seen[key] == nil && quiet > GrokBotActivity.adoptAfter {
                seen[key] = signature
                continue
            }
            seen[key] = signature
            changed.append(GrokBotActivity.event(for: observation, now: now))
        }
        seen = seen.filter { alive.contains($0.key) }
        files = files.filter { file in tracked.contains { $0.url == file.key } }
        return changed
    }
}
