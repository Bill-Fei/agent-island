import Foundation
import Darwin
import LinglongtaiShared

@main
struct LinglongtaiCtl {
    private struct PendingAppend: Codable {
        var offset: Int64
        var data: Data
    }

    private struct HookBridgeState: Codable {
        var version = 2
        var tracker = HookTurnTracker()
        var pending: PendingAppend?
    }

    static func main() {
        LinglongtaiPaths.prepare()
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "start": start(arguments)
        case "update": update(arguments)
        case "finish": finish(arguments)
        case "wait": wait(arguments)
        case "fail": fail(arguments)
        case "stop": stop(arguments)
        case "delete": delete(arguments)
        case "clear": append(AgentEvent(type: "clear"))
        case "emit": emit(arguments)
        case "list": list()
        case "hook": receiveHook(arguments)
        default: printUsage()
        }
    }

    private static func start(_ args: [String]) {
        let id = uuidOption("--id", args) ?? UUID()
        let agent = valueOption("--agent", args) ?? "Agent"
        let profile = AgentCatalog.profile(for: agent)
        let title = valueOption("--title", args) ?? "新任务"
        let model = valueOption("--model", args) ?? profile.defaultModel
        let detail = valueOption("--detail", args) ?? "任务已进入执行队列"
        let color = valueOption("--color", args) ?? profile.colorHex
        append(AgentEvent(type: "upsert", id: id, agent: profile.name, title: title, status: .running, detail: detail, model: model, colorHex: color))
        print(id.uuidString)
    }

    private static func update(_ args: [String]) {
        guard let id = uuidOption("--id", args) else {
            print("缺少 --id")
            return
        }
        let status = valueOption("--status", args).flatMap(AgentTaskStatus.init(rawValue:))
        let progress = valueOption("--progress", args).flatMap(Double.init)
        append(AgentEvent(
            type: "upsert",
            id: id,
            agent: valueOption("--agent", args),
            title: valueOption("--title", args),
            status: status,
            progress: progress,
            detail: valueOption("--detail", args),
            model: valueOption("--model", args),
            requiresApproval: boolOption("--approval", args),
            colorHex: valueOption("--color", args)
        ))
    }

    private static func finish(_ args: [String]) {
        guard let id = uuidOption("--id", args) else { print("缺少 --id"); return }
        append(AgentEvent(type: "upsert", id: id, status: .completed, progress: 1, detail: valueOption("--detail", args) ?? "任务已完成"))
    }

    private static func wait(_ args: [String]) {
        guard let id = uuidOption("--id", args) else { print("缺少 --id"); return }
        append(AgentEvent(type: "upsert", id: id, status: .waiting, detail: valueOption("--detail", args) ?? "等待用户确认", requiresApproval: true))
    }

    private static func fail(_ args: [String]) {
        guard let id = uuidOption("--id", args) else { print("缺少 --id"); return }
        append(AgentEvent(type: "upsert", id: id, status: .failed, detail: valueOption("--detail", args) ?? "任务执行失败"))
    }

    private static func stop(_ args: [String]) {
        guard let id = uuidOption("--id", args) else { print("缺少 --id"); return }
        append(AgentEvent(type: "upsert", id: id, status: .cancelled, detail: "已停止", requiresApproval: false))
    }

    private static func delete(_ args: [String]) {
        guard let id = uuidOption("--id", args) else { print("缺少 --id"); return }
        append(AgentEvent(type: "delete", id: id))
    }

    private static func emit(_ args: [String]) {
        let payload = args.dropFirst().joined(separator: " ")
        guard let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(AgentEvent.self, from: data) else {
            print("emit 需要一段合法 JSON AgentEvent")
            return
        }
        append(event)
    }

    private static func list() {
        guard let data = try? Data(contentsOf: LinglongtaiPaths.tasks),
              let tasks = try? JSONDecoder().decode([AgentTask].self, from: data) else {
            print("没有本地任务")
            return
        }
        for task in tasks.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            print(task.id.uuidString + "\t" + task.status.rawValue + "\t" + task.agent + "\t" + task.title)
        }
    }

    private static func append(_ event: AgentEvent) {
        withEventLock { fd in
            guard var state = loadBridgeState(), recoverPending(&state, descriptor: fd),
                  let data = encodedEvents([event]) else { return }
            _ = writeAll(data, descriptor: fd)
        }
    }

    private static func withEventLock(_ body: (Int32) -> Void) {
        let fd = Darwin.open(LinglongtaiPaths.events.path, O_RDWR | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        body(fd)
    }

    private static func encodedEvents(_ events: [AgentEvent]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var batch = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { return nil }
            batch.append(line)
            batch.append(0x0A)
        }
        return batch
    }

    private static func writeAll(_ data: Data, descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let address = buffer.baseAddress else { return buffer.count == 0 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, address.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func loadBridgeState() -> HookBridgeState? {
        guard FileManager.default.fileExists(atPath: LinglongtaiPaths.hookTurns.path) else {
            return HookBridgeState()
        }
        guard let data = try? Data(contentsOf: LinglongtaiPaths.hookTurns),
              let state = try? JSONDecoder().decode(HookBridgeState.self, from: data),
              state.version == 2 else { return nil }
        return state
    }

    private static func saveBridgeState(_ state: HookBridgeState) -> Bool {
        do {
            try JSONEncoder().encode(state).write(to: LinglongtaiPaths.hookTurns, options: .atomic)
            _ = chmod(LinglongtaiPaths.hookTurns.path, 0o600)
            return true
        } catch { return false }
    }

    /// The sidecar is committed with a pending metadata-only batch before the
    /// append. After an interrupted process, verify its already written prefix
    /// and append only missing bytes. Never truncate or overwrite the log.
    private static func recoverPending(_ state: inout HookBridgeState, descriptor: Int32) -> Bool {
        guard let pending = state.pending else { return true }
        let end = lseek(descriptor, 0, SEEK_END)
        guard pending.offset >= 0, end >= pending.offset else { return false }
        let count = Int(min(end - pending.offset, Int64(pending.data.count)))
        if count > 0 {
            var existing = Data(count: count)
            let didRead = existing.withUnsafeMutableBytes { buffer -> Bool in
                guard let address = buffer.baseAddress else { return false }
                var offset = 0
                while offset < count {
                    let size = pread(descriptor, address.advanced(by: offset), count - offset,
                                     pending.offset + Int64(offset))
                    if size < 0 && errno == EINTR { continue }
                    guard size > 0 else { return false }
                    offset += size
                }
                return true
            }
            guard didRead, existing == pending.data.prefix(count) else { return false }
        }
        if count < pending.data.count {
            guard end == pending.offset + Int64(count),
                  writeAll(Data(pending.data.dropFirst(count)), descriptor: descriptor) else { return false }
        }
        guard fsync(descriptor) == 0 else { return false }
        state.pending = nil
        return saveBridgeState(state)
    }

    private static func receiveHook(_ args: [String]) {
        guard let provider = valueOption("--provider", args) else { return }
        var input = Data()
        while input.count <= 1_048_576 {
            let chunk = FileHandle.standardInput.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            input.append(chunk)
        }
        var publishedEvent = false
        var approval: ApprovalRelay.Request?
        // Explicit opt-in applies ONLY to Claude Code's documented contract.
        withEventLock { fd in
            let kind = AgentKind.resolve(provider)
            let mapped = HookEventMapper.map(provider: kind, payload: input)
            guard var state = loadBridgeState(), recoverPending(&state, descriptor: fd) else { return }
            var events: [AgentEvent]
            if let mapped { events = state.tracker.route(mapped) }
            else {
                // Deliberately ignored subagent/filtered notification events
                // are not protocol failures. Everything else leaves only a
                // metadata discontinuity, never the rejected payload itself.
                let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
                if let agentID = object?["agent_id"] as? String, !agentID.isEmpty { return }
                if object?["hook_event_name"] as? String == "Notification",
                   let type = object?["notification_type"] as? String,
                   !["permission_prompt", "elicitation_dialog", "agent_needs_input"].contains(type) { return }
                events = [AgentEvent(type: "source-unknown", agent: kind.displayName, sourceEvent: "UnrecognizedHook")]
            }
            HookHealth.record(provider: kind, parsed: mapped != nil, directory: LinglongtaiPaths.applicationSupport)
            if args.contains("--approval-relay"), ApprovalRelay.supports(AgentKind.resolve(provider)),
               ApprovalRelay.hasActiveHUD, events.count == 1,
               let request = ApprovalRelay.makeRequest(payload: input, event: events[0]),
               ApprovalRelay.publish(request) {
                approval = request
                events[0].approvalRequestID = request.id
            }
            guard !events.isEmpty, let data = encodedEvents(events) else { return }
            let offset = lseek(fd, 0, SEEK_END)
            guard offset >= 0 else { return }
            state.pending = PendingAppend(offset: offset, data: data)
            guard saveBridgeState(state) else { return }
            publishedEvent = recoverPending(&state, descriptor: fd)
        }
        if !publishedEvent, let request = approval {
            ApprovalRelay.cleanup(request.id)
            approval = nil
        }
        // Wait outside the journal lock. No decision falls back to the provider.
        if let request = approval, let decision = ApprovalRelay.wait(for: request) {
            let result: [String: Any] = ["hookSpecificOutput": [
                "hookEventName": "PermissionRequest", "decision": ["behavior": decision.rawValue]
            ]]
            if let data = try? JSONSerialization.data(withJSONObject: result),
               let json = String(data: data, encoding: .utf8) {
                print(json)
                let flushed = fflush(stdout) == 0
                ApprovalTrace.record(request.id, flushed ? "decision-output" : "decision-output-failed")
            }
        }
    }

    private static func valueOption(_ key: String, _ args: [String]) -> String? {
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func uuidOption(_ key: String, _ args: [String]) -> UUID? {
        valueOption(key, args).flatMap(UUID.init(uuidString:))
    }

    private static func boolOption(_ key: String, _ args: [String]) -> Bool? {
        valueOption(key, args).flatMap { Bool($0) }
    }

    private static func printUsage() {
        print("灵动岛本地事件总线")
        print("  start --agent codex|claude|doubao|work-buddy --title \"任务\"")
        print("  update --id <UUID> [--status running|waiting|completed|failed] [--progress 0.6]")
        print("  finish|wait|fail|stop|delete --id <UUID>")
        print("  clear | list | emit '<AgentEvent JSON>'")
        print("  hook --provider codex|claude|work-buddy < hook-input.json")
    }
}
