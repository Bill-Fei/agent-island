import Foundation
import LinglongtaiShared
import SQLite3

@MainActor
enum BackgroundStoreAcceptance {
    static func run() async throws {
        let root = LinglongtaiPaths.applicationSupport
        guard ProcessInfo.processInfo.arguments.contains("--data-dir"), root.path.hasPrefix("/private/tmp/") else {
            throw NSError(domain: "AcceptanceIsolation", code: 1)
        }
        func check(_ name: String, _ value: Bool) throws {
            print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { throw NSError(domain: name, code: 1) }
        }
        func emit(_ event: AgentEvent) throws {
            let handle = try FileHandle(forWritingTo: LinglongtaiPaths.events)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONEncoder().encode(event) + Data([10]))
        }
        func eventually(_ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NSError(domain: "BackgroundTimeout", code: 1)
        }
        let store = TaskStore()
        store.clearAllTasks()
        let first = UUID()
        try emit(AgentEvent(type: "upsert", id: first, agent: "Codex", status: .running))
        store.pollEvents()
        try await eventually {
            guard let data = try? Data(contentsOf: LinglongtaiPaths.state),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["tasks"] as? [[String: Any]] else { return false }
            return rows.contains { ($0["id"] as? String) == first.uuidString }
        }
        try check("background read + atomic checkpoint survives restart", TaskStore().tasks == store.tasks)
        store.clearAllTasks()
        // Only the explicit disposable QA directory is modified. Recoverable
        // backup preserves the previous snapshot throughout this failure probe.
        let backup = root.appendingPathComponent("checkpoint-backup.json")
        try FileManager.default.moveItem(at: LinglongtaiPaths.state, to: backup)
        try FileManager.default.createDirectory(at: LinglongtaiPaths.state, withIntermediateDirectories: false)
        let second = UUID()
        try emit(AgentEvent(type: "upsert", id: second, agent: "WorkBuddy", status: .running))
        store.pollEvents()
        try await eventually { store.tasks.contains { $0.id == second } && store.notice.contains("重试最新快照") }
        try check("failed background write retains already-applied task", store.tasks.contains { $0.id == second })
        store.clearAllTasks()
        try FileManager.default.removeItem(at: LinglongtaiPaths.state)
        try FileManager.default.moveItem(at: backup, to: LinglongtaiPaths.state)
        store.pollEvents()
        try await eventually {
            guard let data = try? Data(contentsOf: LinglongtaiPaths.state),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["tasks"] as? [[String: Any]] else { return false }
            return rows.isEmpty && (object["eventOffset"] as? NSNumber)?.uint64Value == UInt64((try? Data(contentsOf: LinglongtaiPaths.events).count) ?? 0)
        }
        try check("failure recovery persists latest clear without replay resurrection", TaskStore().tasks.isEmpty && store.tasks.isEmpty)
        var date = Date()
        let clockStore = TaskStore(now: { date })
        let session = UUID().uuidString.lowercased(), turn = UUID().uuidString.lowercased()
        let ghost = UUID().uuidString.lowercased()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        let folder = root.appendingPathComponent("fixture-codex-sessions/" + formatter.string(from: date))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rollout = folder.appendingPathComponent("rollout-fixture-" + session + ".jsonl")
        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database) == SQLITE_OK else { throw NSError(domain: "fixture database", code: 1) }
        defer { sqlite3_close(database) }
        let create = "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, updated_at INTEGER); INSERT INTO threads VALUES ('\(session)','\(rollout.path)',1)"
        try check("Codex fixture has a readable thread index", sqlite3_exec(database, create, nil, nil, nil) == SQLITE_OK)
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\"}}\n"
        func lifecycle(_ event: String) -> String {
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(event)\",\"turn_id\":\"\(turn)\"}}\n"
        }
        try Data((meta + lifecycle("task_started")).utf8).write(to: rollout)
        func hook(_ rawSession: String, _ name: String) throws -> UUID {
            let payload = try JSONSerialization.data(withJSONObject: ["session_id": rawSession, "turn_id": turn, "hook_event_name": name])
            guard let event = HookEventMapper.map(provider: .codex, payload: payload, now: date), let id = event.id else { throw NSError(domain: "fixture hook", code: 1) }
            try emit(event)
            clockStore.consumeEvents()
            return id
        }
        let active = try hook(session, "UserPromptSubmit")
        let orphan = try hook(ghost, "UserPromptSubmit")
        await clockStore.reconcileCodexActivity()
        try check("new starts have time to appear in Codex", clockStore.compactCountText == "2")
        date.addTimeInterval(TaskStore.codexPromptGrace + 11)
        await clockStore.reconcileCodexActivity()
        try check("unindexed prompt alone does not inflate a real turn's count", clockStore.currentActivityTasks.map(\.id) == [active] && clockStore.tasks.first { $0.id == orphan }.map { clockStore.displayedStatus(for: $0) } == "结果未知")
        let parallel = UUID().uuidString.lowercased()
        let peer = try hook(parallel, "PreToolUse")
        date.addTimeInterval(11)
        await clockStore.reconcileCodexActivity()
        try check("two real concurrent activities still count as two with an orphan present", Set(clockStore.currentActivityTasks.map(\.id)) == [active, peer])
        _ = try hook(parallel, "Stop")
        try Data((meta + lifecycle("task_started") + lifecycle("turn_aborted")).utf8).write(to: rollout)
        date.addTimeInterval(3)
        await clockStore.reconcileCodexActivity()
        try check("missing Stop plus real abort returns count to zero", clockStore.compactCountText.isEmpty && clockStore.tasks.first { $0.id == active }?.status == .cancelled)
        _ = try hook(session, "PostToolUse")
        try check("late tool callback cannot revive an aborted native turn", clockStore.compactCountText.isEmpty)
        try check("restart does not resurrect ghost count", TaskStore(now: { date }).compactCountText.isEmpty)
        let staleSnapshots = clockStore.tasks.filter { $0.id == orphan }
        _ = try hook(ghost, "PreToolUse")
        try check("actual tool callback readmits an unconfirmed turn", clockStore.currentActivityTasks.map(\.id) == [orphan])
        clockStore.applyCodexEvidence(staleSnapshots, results: [.cancelled])
        try check("a stale asynchronous result cannot overwrite a newer tool hook", clockStore.currentActivityTasks.map(\.id) == [orphan])
        let beforeClear = clockStore.currentActivityTasks
        clockStore.clearAllTasks()
        clockStore.applyCodexEvidence(beforeClear, results: [.completed])
        try check("an asynchronous result after clear cannot recreate a row", clockStore.tasks.isEmpty)
    }
}
