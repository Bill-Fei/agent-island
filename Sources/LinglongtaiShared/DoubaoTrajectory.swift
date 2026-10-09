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
        public let hasToolCalls: Bool
        /// A partial/invalid trailing row cannot prove the previous answer final.
        public let uncertainTail: Bool
        public let lastRowOffset: UInt64
        public let hasUserRow: Bool
        public let identityUncertain: Bool
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
            case .unknown: return .running
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
                if quiet < 60 { return "正在等待可用轨迹，状态未知" }
                let minutes = max(1, Int(quiet / 60))
                return "已 \(minutes) 分钟无新记录，状态未知"
            }
        }

        /// Mirrors the hook vocabulary so the island treats both sources alike.
        public var sourceEvent: String {
            switch self {
            case .running: return "DoubaoTurn"
            case .finished: return "DoubaoStop"
            case .unknown: return "DoubaoSilent"
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
        return found.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.map(\.0)
    }

    // MARK: - Parsing

    /// Reads only the tail and returns rows with their absolute byte offsets.
    static func tailRows(at url: URL, budget: Int = tailByteBudget) -> (rows: [(offset: UInt64, text: String)], partial: Bool) {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return ([], true) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return ([], true) }
        var start = UInt64(max(0, Int(size) - budget))
        guard (try? handle.seek(toOffset: start)) != nil else { return ([], true) }
        guard var bytes = try? handle.read(upToCount: Int(size - start)), !bytes.isEmpty else { return ([], true) }
        let partial = bytes.last != 0x0A
        // A tail slice starts mid-row and may start mid-character; drop both.
        if start > 0, let first = bytes.firstIndex(of: 0x0A) {
            start += UInt64(bytes.distance(from: bytes.startIndex, to: first)) + 1
            bytes = Data(bytes[bytes.index(after: first)...])
        }
        // Likewise the final row may be half-written; keep up to its newline.
        guard let last = bytes.lastIndex(of: 0x0A) else { return ([], true) }
        bytes = Data(bytes[...last])
        guard let text = String(data: bytes, encoding: .utf8) else { return ([], true) }
        var rows: [(UInt64, String)] = []
        var offset = start
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let row = String(piece)
            if !row.isEmpty { rows.append((offset, row)) }
            offset += UInt64(row.utf8.count) + 1
        }
        return (rows, partial)
    }

    public static func observation(sessionKey: String, url: URL) -> Observation? {
        let tail = tailRows(at: url)
        let rows = tail.rows
        guard !rows.isEmpty else { return nil }
        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        var lastRole: String?
        var lastTool: String?
        var hasToolCalls = false
        var invalidLastRow = false
        var lastRowOffset: UInt64 = 0
        var hasUserRow = false
        var malformedCalls = false
        var turnKey = "0"
        for (offset, text) in rows {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = object["role"] as? String else { invalidLastRow = true; continue }
            invalidLastRow = false
            lastRowOffset = offset
            lastRole = role
            malformedCalls = false
            if role == "user" { hasUserRow = true; turnKey = String(offset); lastTool = nil; hasToolCalls = false }
            // Only an assistant row decides what is being called. A later tool
            // result leaves it set, which is what "just ran X" reports.
            if role == "assistant" {
                var announced: String?
                hasToolCalls = false
                if let calls = object["tool_calls"] as? [Any] {
                    hasToolCalls = !calls.isEmpty
                    for case let call as [String: Any] in calls {
                        if let name = (call["function"] as? [String: Any])?["name"] as? String {
                            announced = name
                        }
                    }
                } else if let calls = object["tool_calls"], !(calls is NSNull) {
                    malformedCalls = true
                }
                lastTool = announced
            }
        }
        guard let lastRole else { return nil }
        return Observation(sessionKey: sessionKey, turnKey: turnKey, lastRole: lastRole,
                            lastToolName: lastTool, modifiedAt: modifiedAt,
                            hasToolCalls: hasToolCalls, uncertainTail: tail.partial || invalidLastRow || malformedCalls,
                            lastRowOffset: lastRowOffset, hasUserRow: hasUserRow, identityUncertain: !hasUserRow)
    }

    public static func phase(of observation: Observation, now: Date) -> Phase {
        if observation.uncertainTail || observation.identityUncertain {
            return .unknown(quiet: max(0, now.timeIntervalSince(observation.modifiedAt)))
        }
        switch observation.lastRole {
        case "assistant":
            // A call announced but not yet returned is still in flight. An
            // assistant row with no call ends the turn.
            guard observation.hasToolCalls else { return .finished }
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
        var tracker = DoubaoTracker()
        return tracker.poll(root: root, now: now)
    }

    /// Limit sessions, not agents; otherwise two children can hide a second chat.
    static func sessionFiles(root: URL) -> [[URL]] {
        let files = trajectoryFiles(root: root)
        var keys: [String] = []
        var groups: [String: [URL]] = [:]
        for file in files {
            let key = sessionKey(for: file)
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(file)
        }
        return keys.prefix(trackedSessionLimit).map { groups[$0] ?? [] }
    }

    /// Only the main agent can end a multi-agent session. Children can supply
    /// activity, but never replace the main user's byte-offset turn identity.
    static func aggregate(_ input: [(URL, Observation)], hasMainFile: Bool) -> Observation? {
        let observations = input.sorted { $0.1.modifiedAt > $1.1.modifiedAt }
        guard let first = observations.first else { return nil }
        let mains = observations.filter {
            $0.0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.hasPrefix("m_")
        }
        let agentName = first.0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let legacySingle = !hasMainFile && observations.count == 1 && !agentName.hasPrefix("s_") && !agentName.hasPrefix("o_")
        guard let anchor = mains.first ?? (legacySingle ? first : nil) else {
            let value = first.1
            return Observation(sessionKey: value.sessionKey, turnKey: "unanchored", lastRole: "unknown",
                               lastToolName: nil, modifiedAt: value.modifiedAt, hasToolCalls: false, uncertainTail: true, lastRowOffset: value.lastRowOffset, hasUserRow: false, identityUncertain: true)
        }
        let main = anchor.1
        let newerChildren = observations.filter { $0.0 != anchor.0 && $0.1.modifiedAt >= main.modifiedAt }
        let unfinished = newerChildren.filter {
            $0.1.uncertainTail || $0.1.identityUncertain || $0.1.lastRole != "assistant" || $0.1.hasToolCalls
        }
        let activity = unfinished.first?.1
        let newest = newerChildren.first?.1
        // A final child cannot complete a parent still waiting for tool results.
        let childRunning = activity != nil
        return Observation(sessionKey: main.sessionKey, turnKey: main.turnKey,
                           lastRole: childRunning ? "tool" : main.lastRole,
                           lastToolName: activity?.lastToolName ?? main.lastToolName,
                           modifiedAt: max(main.modifiedAt, newest?.modifiedAt ?? main.modifiedAt),
                           hasToolCalls: childRunning || main.hasToolCalls,
                           uncertainTail: main.uncertainTail || (activity?.uncertainTail ?? false),
                           lastRowOffset: main.lastRowOffset, hasUserRow: main.hasUserRow,
                           identityUncertain: main.identityUncertain || (activity?.identityUncertain ?? false))
    }

    /// Resolve user boundaries that moved out of the tail between polls. Bounded
    /// to 4 MiB; larger/invalid gaps are unknown, never attributed as progress.
    static func appendedUserOffset(url: URL, from start: Int, to end: Int) -> (valid: Bool, offset: UInt64?) {
        guard end >= start, end - start <= 4 * 1024 * 1024,
              let handle = FileHandle(forReadingAtPath: url.path) else { return (false, nil) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              let bytes = try? handle.read(upToCount: end - start) else { return (false, nil) }
        var position = UInt64(start)
        var latest: UInt64?
        var rowStart = bytes.startIndex
        for index in bytes.indices where bytes[index] == 0x0A {
            let row = bytes[rowStart..<index]
            if !row.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: Data(row)) as? [String: Any],
                      let role = object["role"] as? String else { return (false, nil) }
                if role == "user" { latest = position }
            }
            position += UInt64(row.count) + 1
            rowStart = bytes.index(after: index)
        }
        return (true, latest)
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
    private struct Cached: Sendable {
        let size: Int
        let modifiedAt: Date
        let observation: DoubaoTrajectory.Observation?
    }
    private var files: [URL: Cached] = [:]

    public init() {}

    public mutating func poll(root: URL = DoubaoTrajectory.defaultRoot, now: Date = Date()) -> [AgentEvent] {
        var changed: [AgentEvent] = []
        var alive: Set<String> = []
        let groups = DoubaoTrajectory.sessionFiles(root: root)
        let aliveFiles = Set(groups.flatMap { $0 })
        for group in groups {
            var observations: [(URL, DoubaoTrajectory.Observation)] = []
            for url in group {
                guard let metadata = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = metadata.fileSize, let modifiedAt = metadata.contentModificationDate else { continue }
                if files[url]?.size != size || files[url]?.modifiedAt != modifiedAt {
                    var value = DoubaoTrajectory.observation(sessionKey: DoubaoTrajectory.sessionKey(for: url), url: url)
                    if value == nil, let previous = files[url]?.observation {
                        value = DoubaoTrajectory.Observation(sessionKey: previous.sessionKey, turnKey: previous.turnKey,
                            lastRole: "unknown", lastToolName: nil, modifiedAt: modifiedAt,
                            hasToolCalls: false, uncertainTail: true, lastRowOffset: previous.lastRowOffset, hasUserRow: false, identityUncertain: previous.identityUncertain)
                    }
                    if value == nil {
                        value = DoubaoTrajectory.Observation(sessionKey: DoubaoTrajectory.sessionKey(for: url), turnKey: "unanchored",
                            lastRole: "unknown", lastToolName: nil, modifiedAt: modifiedAt,
                            hasToolCalls: false, uncertainTail: true, lastRowOffset: 0, hasUserRow: false, identityUncertain: true)
                    }
                    if let parsed = value, !parsed.hasUserRow, let cached = files[url], let previous = cached.observation, size >= cached.size {
                        let from = previous.uncertainTail ? Int(previous.lastRowOffset) : cached.size
                        let gap = DoubaoTrajectory.appendedUserOffset(url: url, from: from, to: size)
                        value = DoubaoTrajectory.Observation(sessionKey: parsed.sessionKey, turnKey: gap.offset.map(String.init) ?? previous.turnKey,
                            lastRole: parsed.lastRole, lastToolName: parsed.lastToolName, modifiedAt: parsed.modifiedAt,
                            hasToolCalls: parsed.hasToolCalls, uncertainTail: parsed.uncertainTail || !gap.valid,
                            lastRowOffset: parsed.lastRowOffset, hasUserRow: gap.offset != nil,
                            identityUncertain: gap.offset == nil && (previous.identityUncertain || !gap.valid))
                    }
                    if let parsed = value, let previous = files[url]?.observation,
                       size == files[url]?.size, parsed.turnKey == previous.turnKey,
                       parsed.lastRole == previous.lastRole, parsed.hasToolCalls == previous.hasToolCalls,
                       parsed.lastToolName == previous.lastToolName, parsed.lastRowOffset == previous.lastRowOffset,
                       parsed.uncertainTail == previous.uncertainTail, parsed.identityUncertain == previous.identityUncertain {
                        // Touching a file is not a new lifecycle event.
                        value = previous
                    }
                    files[url] = Cached(size: size, modifiedAt: modifiedAt, observation: value)
                }
                if let observation = files[url]?.observation { observations.append((url, observation)) }
            }
            let hasMainFile = group.contains { $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.hasPrefix("m_") }
            guard let observation = DoubaoTrajectory.aggregate(observations, hasMainFile: hasMainFile) else { continue }
            let key = observation.sessionKey
            alive.insert(key)
            // A silent row has to be re-reported as time passes so "2 minutes
            // quiet" can become "3 minutes quiet" and eventually be abandoned.
            // Capped: once abandoned there is nothing left to say.
            let quiet = now.timeIntervalSince(observation.modifiedAt)
            let cap = Int(DoubaoTrajectory.abandonAfter / 60)
            let ended = DoubaoTrajectory.phase(of: observation, now: now) == .finished
            let quietBucket = ended ? 0 : min(Int(quiet / 60), cap)
            let signature = "\(observation.turnKey):\(observation.lastRole):"
                + "\(observation.lastToolName ?? ""):\(observation.modifiedAt.timeIntervalSince1970):\(quietBucket):\(observation.hasToolCalls):\(observation.uncertainTail):\(observation.lastRowOffset):\(observation.identityUncertain)"
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
        files = files.filter { aliveFiles.contains($0.key) }
        return changed
    }
}
