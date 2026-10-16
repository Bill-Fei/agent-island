import Foundation
import Darwin

/// Opt-in, one-shot PermissionRequest relay. Never grants standing permissions.
/// Context is local, private, short-lived and excluded from the event journal.
public enum ApprovalRelay {
    /// Claude Code only; hook callers must explicitly opt in. Other providers
    /// remain observation-only, and no standing permissions are returned.
    public static func supports(_ provider: AgentKind) -> Bool { provider == .claude }

    /// The terminal CLI applies the hook's decision. SDK hosts such as Claude
    /// Desktop (`claude-desktop*`) run this hook for every permission check,
    /// including tools they then auto-approve, and decide only in their own
    /// card. There the island answers by pressing that card (see
    /// ClaudePromptLog), never through the hook, and the hook does not wait.
    public static func hostShowsOwnPrompt(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let entrypoint = environment["CLAUDE_CODE_ENTRYPOINT"], !entrypoint.isEmpty else { return false }
        return entrypoint != "cli"
    }

    /// Desktop's own session identity, e.g. `local_<uuid>`; nil when absent or malformed.
    public static func hostSessionID(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let value = environment["CLAUDE_CODE_HOST_SESSION_ID"], value.hasPrefix("local_"),
              UUID(uuidString: String(value.dropFirst(6))) != nil else { return nil }
        return value
    }

    /// A Desktop card may stay open while the user works elsewhere.
    static let hostPromptLifetime: TimeInterval = 600

    public struct Request: Codable, Identifiable, Equatable, Sendable {
        public var protocolVersion = 2
        public var id: UUID
        public var taskID: UUID
        public var provider: AgentKind
        public var tool: String
        public var context: String
        public var expiresAt: Date
        public var processID: Int32
        /// Desktop delivery: the card lives in this host session and is pressed
        /// there. Nil for the terminal CLI, which answers through the hook.
        public var hostSessionID: String?
        /// Raw provider tool name, matched against the host's own prompt record.
        public var toolName: String?
        public var createdAt: Date?

        public var deliversThroughHost: Bool { hostSessionID != nil }
        var lifetime: TimeInterval { deliversThroughHost ? ApprovalRelay.hostPromptLifetime : 45 }
    }
    public enum Decision: String, Codable { case allow, deny }
    private struct Reply: Codable { var id: UUID; var decision: Decision }
    private struct Heartbeat: Codable { var processID: Int32; var updatedAt: Date; var canPresent: Bool }
    private static var directory: URL { LinglongtaiPaths.applicationSupport.appendingPathComponent("pending-approvals") }
    private static func requestURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    private static func replyURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".reply") }

    public static func makeRequest(payload: Data, event: AgentEvent, now: Date = Date()) -> Request? {
        guard let taskID = event.id, event.type == "upsert", event.status == .waiting,
              event.requiresApproval == true, event.sourceEvent == "PermissionRequest",
              let provider = event.agent.map(AgentKind.resolve), supports(provider),
              let input = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              input["hook_event_name"] as? String == "PermissionRequest",
              (input["agent_id"] as? String ?? "").isEmpty,
              let tool = input["tool_name"] as? String, !tool.isEmpty, tool.count <= 120,
              let arguments = input["tool_input"] as? [String: Any], JSONSerialization.isValidJSONObject(arguments),
              let cwd = input["cwd"] as? String, cwd.hasPrefix("/"), cwd.count <= 1_024,
              let data = try? JSONSerialization.data(withJSONObject: ["tool": tool, "working_directory": cwd, "arguments": arguments], options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]),
              data.count <= 8_192, let context = String(data: data, encoding: .utf8),
              !context.isEmpty else { return nil }
        // Do not move likely credentials into the secondary approval surface.
        // Unsupported/sensitive requests fall through to the provider UI.
        let sensitive = "(?i)(api[_-]?key|authorization|bearer |password|secret|token|sk-[a-z0-9]|private.key|credential|\\.env)"
        guard context.range(of: sensitive, options: .regularExpression) == nil else { return nil }
        var host: String?
        if hostShowsOwnPrompt() {
            // An SDK host without a verifiable session cannot be pressed safely.
            guard let session = hostSessionID() else { return nil }
            host = session
        }
        return Request(id: UUID(), taskID: taskID, provider: provider,
                       tool: ToolStep.label(for: tool), context: context,
                       expiresAt: now.addingTimeInterval(host == nil ? 45 : hostPromptLifetime), processID: getpid(),
                       hostSessionID: host, toolName: host == nil ? nil : tool, createdAt: host == nil ? nil : now)
    }

    public static func publish(_ request: Request) -> Bool {
        guard supports(request.provider), request.protocolVersion == 2,
              request.processID == getpid(), request.expiresAt > Date(),
              request.expiresAt.timeIntervalSinceNow <= request.lifetime + 1 else { return false }
        guard prepareDirectory(), let data = try? JSONEncoder().encode(request) else { return false }
        cleanupExpired()
        if let session = request.hostSessionID { cleanupHostSession(session) }
        let published = writeExclusive(data, to: requestURL(request.id))
        if published { ApprovalTrace.record(request.id, "published", heartbeatAge: hudStatus(stallTolerance: 4).age) }
        return published
    }

    /// Only a live, recently responsive HUD can intercept a permission prompt.
    public static var hasActiveHUD: Bool { hudStatus(stallTolerance: 4).available }

    /// A published request survives a brief main-thread stall of a live HUD.
    /// A quit, crashed or hidden HUD still releases the provider immediately.
    static let waitStallTolerance: TimeInterval = 12

    /// One heartbeat read, so a traced age always matches the decision made.
    static func hudStatus(stallTolerance: TimeInterval) -> (available: Bool, age: TimeInterval?) {
        guard let data = readPrivate(directory.appendingPathComponent("hud.heartbeat")),
              let beat = try? JSONDecoder().decode(Heartbeat.self, from: data) else { return (false, nil) }
        let age = Date().timeIntervalSince(beat.updatedAt)
        let available = beat.canPresent && age >= -1 && age < stallTolerance && beat.processID > 0 && kill(beat.processID, 0) == 0
        return (available, age)
    }

    public static func updateHUDHeartbeat(canPresent: Bool) {
        guard prepareDirectory(),
              let data = try? JSONEncoder().encode(Heartbeat(processID: getpid(), updatedAt: Date(), canPresent: canPresent)) else { return }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".heartbeat-tmp")
        if writeExclusive(data, to: temporary) {
            _ = rename(temporary.path, directory.appendingPathComponent("hud.heartbeat").path)
            try? FileManager.default.removeItem(at: temporary)
        }
        cleanupExpired()
    }

    /// Clear only our valid, privately owned, expired request/reply files.
    /// Runs on launch, heartbeat and publication, also recovering from crashes.
    public static func cleanupExpired(now: Date = Date()) {
        guard directoryIsPrivate(), let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls {
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let request = readRequest(id),
                  request.expiresAt <= now ||
                  (!request.deliversThroughHost && request.processID > 0 && kill(request.processID, 0) != 0) else { continue }
            cleanup(id)
        }
    }

    /// A host session asks one permission at a time; a newer check supersedes
    /// its earlier (auto-approved or answered) requests.
    static func cleanupHostSession(_ session: String) {
        guard directoryIsPrivate(), let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls {
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let request = readRequest(id), request.hostSessionID == session else { continue }
            cleanup(id)
        }
    }

    /// Explicit reset of our own relay files, not provider history.
    /// Normal startup must use cleanupExpired(), preserving live requests.
    public static func clearPendingRequests() {
        guard directoryIsPrivate(), let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "json" || url.pathExtension == "reply" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            cleanup(id)
        }
    }

    public static func pending(_ id: UUID, taskID: UUID, now: Date = Date()) -> Request? {
        guard let request = readRequest(id), supports(request.provider), request.protocolVersion == 2, request.taskID == taskID,
              request.expiresAt > now, request.expiresAt.timeIntervalSince(now) <= request.lifetime + 1,
              request.deliversThroughHost || (request.processID > 0 && kill(request.processID, 0) == 0),
              !FileManager.default.fileExists(atPath: replyURL(id).path) else { return nil }
        return request
    }

    public static func respond(to request: Request, decision: Decision) -> Bool {
        // A host-delivered request has no listener; its card must be pressed.
        guard !request.deliversThroughHost, pending(request.id, taskID: request.taskID) == request,
              let data = try? JSONEncoder().encode(Reply(id: request.id, decision: decision)) else { return false }
        let written = writeExclusive(data, to: replyURL(request.id))
        ApprovalTrace.record(request.id, written ? "decision-written" : "decision-write-failed")
        return written
    }

    public static func wait(for request: Request) -> Decision? {
        guard supports(request.provider), request.protocolVersion == 2 else { return nil }
        defer { cleanup(request.id) }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while Date() < request.expiresAt && ProcessInfo.processInfo.systemUptime < deadline {
            if let data = readPrivate(replyURL(request.id)),
               let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.id == request.id {
                ApprovalTrace.record(request.id, "reply-consumed")
                return reply.decision
            }
            // A HUD quit, hide or prolonged stall must not hold the provider's normal prompt.
            let hud = hudStatus(stallTolerance: waitStallTolerance)
            if !hud.available {
                ApprovalTrace.record(request.id, "released-hud-unavailable", heartbeatAge: hud.age)
                return nil
            }
            usleep(100_000)
        }
        ApprovalTrace.record(request.id, "released-expired")
        return nil // No decision: provider's normal permission UI remains authoritative.
    }

    public static func cleanup(_ id: UUID) {
        guard directoryIsPrivate() else { return }
        try? FileManager.default.removeItem(at: requestURL(id))
        try? FileManager.default.removeItem(at: replyURL(id))
    }

    private static func readRequest(_ id: UUID) -> Request? {
        guard let data = readPrivate(requestURL(id)),
              let request = try? JSONDecoder().decode(Request.self, from: data), request.id == id else { return nil }
        return request
    }

    private static func prepareDirectory() -> Bool {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return false }
        return directoryIsPrivate()
    }

    private static func directoryIsPrivate() -> Bool {
        var info = stat()
        return lstat(directory.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR &&
            info.st_uid == getuid() && (info.st_mode & 0o777) == 0o700
    }

    private static func readPrivate(_ url: URL) -> Data? {
        guard directoryIsPrivate() else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o600,
              info.st_size > 0, info.st_size < 16_384 else { return nil }
        var data = Data(count: Int(info.st_size))
        let succeeded = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.read(fd, base.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        return succeeded ? data : nil
    }

    private static func writeExclusive(_ data: Data, to url: URL) -> Bool {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return fsync(fd) == 0
        }
    }
}
