import Foundation

/// Read-only observer for Doubao desktop **Agent mode** trajectories.
///
/// Why this exists: Doubao exposes no hook, no CLI event and no approval channel.
/// Its Agent mode nevertheless writes an OpenAI-style trajectory to disk as it
/// runs. This adapter reads that file instead of asking the app to report itself.
///
/// Hard limits, deliberately not worked around:
///   - Only `role` and `function.name` are read. Prompt text, tool input, tool
///     output, file names and cwd are never parsed, stored or logged.
///   - Nothing can be written back: the island can *show* Doubao but can never
///     approve, cancel or reply to it.
///   - Ordinary chat lives in the cloud and leaves nothing on disk; only Agent
///     mode is observable.
///   - Trajectory rows carry no timestamp. Freshness comes from the file mtime,
///     so a turn that stops mid-flight is reported as unknown, never completed.
public enum DoubaoTrajectory {

    public static let defaultRoot: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doubao/Default/.doubao/agent_mode/workspace/.sessions",
                                    isDirectory: true)
    }()

    /// A session is only picked up if it was touched this recently. Older ones
    /// are remembered silently, so launching the island never resurrects a
    /// trajectory from days ago as if it were live.
    public static let adoptAfter: TimeInterval = 600
    /// A trajectory unchanged for this long is no longer evidence of progress.
    /// Measured against real runs: a turn legitimately sits silent for minutes
    /// while the model thinks, so this is deliberately looser than the tool
    /// turnaround it is meant to survive.
    public static let staleAfter: TimeInterval = 240
    /// After this, tracking stops instead of leaving a permanently running row.
    /// Doubao never emits a completion signal, so ending a turn can only be
    /// inferred from its last assistant row, never from silence alone.
    public static let abandonAfter: TimeInterval = 1_200

    /// Only the most recently touched sessions are shown; history never floods the island.
    public static let trackedSessionLimit = 2
    /// Trajectories reach megabytes; only the tail is ever read.
    static let tailByteBudget = 256 * 1024

    public struct Observation: Sendable, Equatable {
        public let sessionKey: String
        /// Byte offset of the latest `user` row. Identifies a turn without
        /// reading the message itself.
        public let turnKey: String
        public let lastRole: String
        public let lastToolName: String?
        public let modifiedAt: Date
    }

    public enum Phase: Sendable, Equatable {
        case running(tool: String?)
        case finished
        /// The trajectory stopped changing. Its real state is not knowable from disk.
        case unknown(quiet: TimeInterval)

        public var status: AgentTaskStatus {
            switch self {
            case .running: return .running
            case .finished: return .completed
            case .unknown(let quiet): return quiet >= abandonAfter ? .cancelled : .running
            }
        }

        public var detail: String {
            switch self {
            case .running(let tool):
                if let tool { return "刚\(ToolStep.label(for: tool))，正在继续" }
                return "已收到你的请求，正在处理"
            case .finished:
                return "本轮响应已结束"
            case .unknown(let quiet):
                let minutes = max(1, Int(quiet / 60))
                if quiet >= abandonAfter { return "轨迹 \(minutes) 分钟未更新，已停止跟踪" }
                return "已 \(minutes) 分钟无新记录，状态未知"
            }
        }

        /// Mirrors the hook vocabulary so the island treats both sources alike.
        public var sourceEvent: String {
            switch self {
            case .running: return "DoubaoTurn"
            case .finished: return "DoubaoStop"
            case .unknown(let quiet): return quiet >= abandonAfter ? "DoubaoAbandoned" : "DoubaoSilent"
            }
        }
    }

    // MARK: - Discovery

    public static func trajectoryFiles(root: URL = defaultRoot) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "trajectory.jsonl" else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            found.append((url, date))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: - Parsing

    /// Reads only the tail and returns rows with their absolute byte offsets.
    static func tailRows(at url: URL, budget: Int = tailByteBudget) -> [(offset: UInt64, text: String)] {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return [] }
        var start = UInt64(max(0, Int(size) - budget))
        guard (try? handle.seek(toOffset: start)) != nil else { return [] }
        guard var bytes = try? handle.readToEnd(), !bytes.isEmpty else { return [] }
        // A tail slice starts mid-row and may start mid-character; drop both.
        if start > 0, let first = bytes.firstIndex(of: 0x0A) {
            start += UInt64(bytes.distance(from: bytes.startIndex, to: first)) + 1
            bytes = Data(bytes[bytes.index(after: first)...])
        }
        // Likewise the final row may be half-written; keep up to its newline.
        if let last = bytes.lastIndex(of: 0x0A) { bytes = Data(bytes[...last]) }
        guard let text = String(data: bytes, encoding: .utf8) else { return [] }
        var rows: [(UInt64, String)] = []
        var offset = start
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let row = String(piece)
            if !row.isEmpty { rows.append((offset, row)) }
            offset += UInt64(row.utf8.count) + 1
        }
        return rows
    }

    public static func observation(sessionKey: String, url: URL) -> Observation? {
        let rows = tailRows(at: url)
        guard !rows.isEmpty else { return nil }
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        var lastRole: String?
        var lastTool: String?
        var turnKey = "0"
        for (offset, text) in rows {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = object["role"] as? String else { continue }
            lastRole = role
            if role == "user" { turnKey = String(offset) }
            // Only an assistant row decides what is being called. A later tool
            // result leaves it set, which is what "just ran X" reports.
            if role == "assistant" {
                var announced: String?
                if let calls = object["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        if let name = (call["function"] as? [String: Any])?["name"] as? String {
                            announced = name
                        }
                    }
                }
                lastTool = announced
            }
        }
        guard let lastRole else { return nil }
        return Observation(sessionKey: sessionKey, turnKey: turnKey, lastRole: lastRole,
                            lastToolName: lastTool, modifiedAt: modifiedAt)
    }

    public static func phase(of observation: Observation, now: Date) -> Phase {
        switch observation.lastRole {
        case "assistant":
            // A call announced but not yet returned is still in flight. An
            // assistant row with no call ends the turn.
            guard observation.lastToolName != nil else { return .finished }
            let quiet = now.timeIntervalSince(observation.modifiedAt)
            return quiet >= staleAfter ? .unknown(quiet: quiet) : .running(tool: observation.lastToolName)
        case "user", "tool":
            let quiet = now.timeIntervalSince(observation.modifiedAt)
            return quiet >= staleAfter ? .unknown(quiet: quiet) : .running(tool: observation.lastToolName)
        default:
            return .unknown(quiet: max(0, now.timeIntervalSince(observation.modifiedAt)))
        }
    }

    // MARK: - Events

    public static func event(for observation: Observation, now: Date) -> AgentEvent {
        let phase = phase(of: observation, now: now)
        let sessionID = "s_" + IdentityDigest.digest(namespace: "doubao-session-v1", components: [observation.sessionKey])
        let turnID = "t_" + IdentityDigest.digest(namespace: "doubao-turn-v1", components: [sessionID, observation.turnKey])
        let kind = AgentKind.doubao
        return AgentEvent(
            type: "upsert",
            id: IdentityDigest.uuid(namespace: "doubao-task-v1", components: [sessionID, turnID]),
            agent: kind.displayName,
            title: "豆包 Agent 会话",
            status: phase.status,
            detail: phase.detail,
            model: kind.defaultModel,
            requiresApproval: false,
            colorHex: kind.colorHex,
            // Rows carry no timestamp. The file mtime is the only honest clock
            // available and is exactly what freshness is judged against.
            createdAt: observation.modifiedAt,
            sourceEvent: phase.sourceEvent,
            sessionID: sessionID,
            turnID: turnID
        )
    }

    /// One event per recently active session, newest first.
    public static func events(root: URL = defaultRoot, now: Date = Date()) -> [AgentEvent] {
        trajectoryFiles(root: root).prefix(trackedSessionLimit).compactMap { url in
            observation(sessionKey: sessionKey(for: url), url: url).map { event(for: $0, now: now) }
        }
    }

    public static func sessionKey(for url: URL) -> String {
        // .../sessions/<sessionID>/agents/<agentID>/system/trajectory.jsonl
        let components = url.pathComponents
        guard let system = components.lastIndex(of: "system"), system >= 3 else {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return components[system - 3]
    }
}

/// Remembers what was already reported so a timer can poll without re-applying
/// identical state. Keeps only a coarse signature, never row content.
public struct DoubaoTracker: Sendable {
    private var seen: [String: String] = [:]

    public init() {}

    public mutating func poll(root: URL = DoubaoTrajectory.defaultRoot, now: Date = Date()) -> [AgentEvent] {
        var changed: [AgentEvent] = []
        var alive: Set<String> = []
        for url in DoubaoTrajectory.trajectoryFiles(root: root).prefix(DoubaoTrajectory.trackedSessionLimit) {
            let key = DoubaoTrajectory.sessionKey(for: url)
            guard let observation = DoubaoTrajectory.observation(sessionKey: key, url: url) else { continue }
            alive.insert(key)
            // A silent row has to be re-reported as time passes so "2 minutes
            // quiet" can become "3 minutes quiet" and eventually be abandoned.
            // Capped: once abandoned there is nothing left to say.
            let quiet = now.timeIntervalSince(observation.modifiedAt)
            let cap = Int(DoubaoTrajectory.abandonAfter / 60)
            let ended = observation.lastRole == "assistant" && observation.lastToolName == nil
            let quietBucket = ended ? 0 : min(Int(quiet / 60), cap)
            let signature = "\(observation.turnKey):\(observation.lastRole):"
                + "\(observation.lastToolName ?? ""):\(Int(observation.modifiedAt.timeIntervalSince1970)):\(quietBucket)"
            guard seen[key] != signature else { continue }
            // First sighting of a long-quiet session is recorded, not announced.
            if seen[key] == nil && quiet > DoubaoTrajectory.adoptAfter {
                seen[key] = signature
                continue
            }
            seen[key] = signature
            changed.append(DoubaoTrajectory.event(for: observation, now: now))
        }
        seen = seen.filter { alive.contains($0.key) }
        return changed
    }
}
