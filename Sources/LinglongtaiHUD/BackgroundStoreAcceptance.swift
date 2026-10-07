import Foundation
import LinglongtaiShared

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
        print("3 isolated background store checks passed")
    }
}
