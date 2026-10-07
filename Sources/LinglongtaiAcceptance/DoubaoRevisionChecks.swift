import Foundation
import LinglongtaiShared

/// Doubao is observed through its on-disk trajectory instead of a hook, which
/// makes it the only source that can silently go stale. These checks pin both
/// the lifecycle derivation and the privacy boundary.
func runDoubaoRevisionChecks(check: (String, Bool) -> Void) {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("linglongtai-doubao-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }

    func write(_ root: URL, session: String, rows: [[String: Any]], age: TimeInterval, now: Date) -> URL {
        let dir = root.appendingPathComponent("\(session)/agents/a_1/system", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("trajectory.jsonl")
        var text = ""
        for row in rows {
            let data = try! JSONSerialization.data(withJSONObject: row)
            text += String(data: data, encoding: .utf8)! + "\n"
        }
        try? text.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        return file
    }

    func user(_ text: String = "你好") -> [String: Any] { ["role": "user", "content": text] }
    func assistant(tool: String? = nil) -> [String: Any] {
        var row: [String: Any] = ["role": "assistant", "content": "正在处理"]
        if let tool {
            row["tool_calls"] = [["function": ["name": tool]]]
        }
        return row
    }
    func toolResult(_ text: String = "输出") -> [String: Any] { ["role": "tool", "content": text] }

    let now = Date()
    let root = base.appendingPathComponent("sessions", isDirectory: true)

    do {
        // 1. An assistant row with no pending call ends the turn.
        let file = write(root, session: "s-finished", rows: [user(), assistant()], age: 5, now: now)
        let observation = DoubaoTrajectory.observation(sessionKey: "s-finished", url: file)
        let phase = observation.map { DoubaoTrajectory.phase(of: $0, now: now) }
        check("doubao: assistant with no pending call ends the turn",
              phase == .finished)
        check("doubao: a finished turn is reported as completed",
              observation.map { DoubaoTrajectory.event(for: $0, now: now).status } == .completed)

        // 2. A call that has been announced but not returned is still in flight.
        let pending = write(root, session: "s-pending", rows: [user(), assistant(tool: "Bash")], age: 5, now: now)
        let pendingObservation = DoubaoTrajectory.observation(sessionKey: "s-pending", url: pending)
        check("doubao: an announced tool call keeps the turn running",
              pendingObservation.map { DoubaoTrajectory.phase(of: $0, now: now) } == .running(tool: "Bash"))
        let pendingDetail = pendingObservation.flatMap { DoubaoTrajectory.event(for: $0, now: now).detail } ?? ""
        check("doubao: an unreturned assistant tool becomes unknown after four minutes",
              pendingObservation.map { DoubaoTrajectory.phase(of: $0, now: now.addingTimeInterval(240)) } == .unknown(quiet: 245))
        check("doubao: an unreturned tool stops tracking without claiming completion",
              pendingObservation.map { DoubaoTrajectory.event(for: $0, now: now.addingTimeInterval(1_200)).sourceEvent } == "DoubaoAbandoned")
        check("doubao: a tool call is reported by classified label, never raw name",
              pendingDetail.contains("执行命令") && !pendingDetail.contains("Bash"))

        // 3. A tool result means the model is continuing.
        let returned = write(root, session: "s-tool", rows: [user(), assistant(tool: "Bash"), toolResult()], age: 5, now: now)
        check("doubao: a returned tool result keeps the turn running",
              DoubaoTrajectory.observation(sessionKey: "s-tool", url: returned)
                  .map { DoubaoTrajectory.phase(of: $0, now: now) } == .running(tool: "Bash"))

        // 4. Silence is never promoted to completion.
        let quiet = write(root, session: "s-quiet", rows: [user()], age: 300, now: now)
        let quietEvent = DoubaoTrajectory.observation(sessionKey: "s-quiet", url: quiet)
            .map { DoubaoTrajectory.event(for: $0, now: now) }
        check("doubao: a quiet trajectory is never reported as completed",
              quietEvent?.status == .running)
        check("doubao: a quiet trajectory says the state is unknown",
              quietEvent?.detail?.contains("状态未知") == true)

        // 5. Long silence stops tracking rather than holding the island forever.
        let abandoned = write(root, session: "s-abandoned", rows: [user()], age: 1_300, now: now)
        let abandonedEvent = DoubaoTrajectory.observation(sessionKey: "s-abandoned", url: abandoned)
            .map { DoubaoTrajectory.event(for: $0, now: now) }
        check("doubao: long silence stops tracking instead of staying live",
              abandonedEvent?.status == .cancelled)
        let unknown = write(root, session: "s-unknown", rows: [user(), ["role": "unexpected"]], age: 5, now: now)
        check("doubao: unrecognized role is unknown, never completed", DoubaoTrajectory.observation(sessionKey: "s-unknown", url: unknown).map { DoubaoTrajectory.event(for: $0, now: now).status } != .completed)
        let abandonedTask = AgentTask(agent: "豆包", title: "fixture", status: .cancelled, detail: "", model: "", sourceEvent: "DoubaoAbandoned")
        check("doubao: stopped tracking does not claim provider interruption", abandonedTask.statusLabel == "已停止跟踪 · 状态未知")

        // 6. The privacy boundary: row content must never reach the island.
        let secret = "绝不外传的私密内容-9f3a"
        let secretFile = write(root, session: "s-secret", rows: [user(secret), assistant(tool: "Bash")], age: 5, now: now)
        let secretEvent = DoubaoTrajectory.observation(sessionKey: "s-secret", url: secretFile)
            .map { DoubaoTrajectory.event(for: $0, now: now) }
        let rendered = "\(secretEvent?.detail ?? "")|\(secretEvent?.title ?? "")|\(secretEvent?.sessionID ?? "")"
        check("doubao: row content never reaches the island", !rendered.contains(secret))
        check("doubao: the turn key is a byte offset, not the message",
              secretEvent?.turnID?.contains(secret) == false)

        // 7. Identity is stable within a turn and distinct across sessions.
        let first = DoubaoTrajectory.observation(sessionKey: "s-secret", url: secretFile)
        let second = DoubaoTrajectory.observation(sessionKey: "s-secret", url: secretFile)
        check("doubao: repeated reads of one turn share a single identity",
              first.map { DoubaoTrajectory.event(for: $0, now: now).id } ==
              second.map { DoubaoTrajectory.event(for: $0, now: now).id })
        let other = write(root, session: "s-other", rows: [user(), assistant(tool: "Bash")], age: 4, now: now)
        check("doubao: separate sessions never share a task identity",
              DoubaoTrajectory.observation(sessionKey: "s-other", url: other)
                  .map { DoubaoTrajectory.event(for: $0, now: now).id } != secretEvent?.id)
    }

    // 8. A long-quiet session seen for the first time is remembered, not shown.
    // Its own root: neighbouring fixtures must not be what gets reported.
    do {
        let soloBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("linglongtai-doubao-solo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: soloBase) }
        let soloRoot = soloBase.appendingPathComponent("sessions", isDirectory: true)
        _ = write(soloRoot, session: "s-old", rows: [user()], age: 3_600, now: now)
        var tracker = DoubaoTracker()
        check("doubao: launching never resurrects a cold trajectory",
              tracker.poll(root: soloRoot, now: now).isEmpty)
        // Once live, the same session is reported normally.
        _ = write(soloRoot, session: "s-old", rows: [user(), assistant(tool: "Read")], age: 2, now: now)
        check("doubao: a revived session is reported once it moves",
              tracker.poll(root: soloRoot, now: now).count == 1)
        check("doubao: unchanged state is not re-applied",
              tracker.poll(root: soloRoot, now: now).isEmpty)
    }

    // 9. Only the newest sessions are tracked, so history cannot flood the island.
    do {
        let many = FileManager.default.temporaryDirectory
            .appendingPathComponent("linglongtai-doubao-many-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: many) }
        for index in 0..<6 {
            let dir = many.appendingPathComponent("sessions/s-\(index)/agents/a_1/system", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("trajectory.jsonl")
            try? "{\"role\":\"user\",\"content\":\"x\"}\n".write(to: file, atomically: true, encoding: .utf8)
            // Spaced well apart: one-second gaps can collapse on disk.
            try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-TimeInterval(index) * 10)],
                                                   ofItemAtPath: file.path)
        }
        let manyRoot = many.appendingPathComponent("sessions")
        let files = DoubaoTrajectory.trajectoryFiles(root: manyRoot)
        check("doubao: trajectories are discovered newest first",
              files.count == 6 && files.first?.path.contains("s-0") == true)
        var tracker = DoubaoTracker()
        check("doubao: only the newest sessions are tracked",
              tracker.poll(root: manyRoot, now: now).count == DoubaoTrajectory.trackedSessionLimit)
    }

    // 10. A trajectory larger than the read budget is still parsed from its tail.
    do {
        let big = FileManager.default.temporaryDirectory
            .appendingPathComponent("linglongtai-doubao-big-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: big) }
        let dir = big.appendingPathComponent("sessions/s-big/agents/a_1/system", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("trajectory.jsonl")
        var text = ""
        for _ in 0..<4_000 { text += "{\"role\":\"tool\",\"content\":\"\(String(repeating: "填充内容", count: 40))\"}\n" }
        text += "{\"role\":\"assistant\",\"content\":\"结束\"}\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
        check("doubao: a multi-megabyte trajectory is read from its tail",
              DoubaoTrajectory.observation(sessionKey: "s-big", url: file)?.lastRole == "assistant")
    }
}
