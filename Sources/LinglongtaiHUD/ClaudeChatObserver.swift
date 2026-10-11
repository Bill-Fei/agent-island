import ApplicationServices
import AppKit
import Foundation
import LinglongtaiShared

/// Exposes only allowlisted activity signals. Message and input subtrees are skipped.
@MainActor
final class ClaudeChatObserver {
    enum Phase: Equatable { case running, completed, unknown }

    struct Snapshot: Equatable {
        let phase: Phase
        let sessionID: String
        let detail: String
    }

    enum Diagnostic: String, Sendable {
        case permissionRequired = "Claude Chat：灵动岛尚未获得辅助功能授权"
        case notRunning = "Claude Chat：应用未运行"
        case windowUnavailable = "Claude Chat：未读到窗口"
        case unreadable = "Claude Chat：窗口状态暂不可读"
        case codeMode = "Claude 当前为 Code 模式 · 由 Hook 跟踪"
        case unsupportedPage = "Claude Chat：当前页面未匹配聊天会话"
        case observing = "Claude Chat：窗口可读 · 等待生成信号"
        case running = "Claude Chat：已检测到生成中"
        case idle = "Claude Chat：输入控件就绪"
    }

    struct Observation: Sendable {
        let diagnostic: Diagnostic
        var sessionID: String? = nil
        var running = false
        var idle = false
        var scanComplete = true
    }

    var onSnapshot: ((Snapshot) -> Void)?
    var onDiagnostic: ((Diagnostic) -> Void)?
    private var timer: Timer?
    private var pollInFlight = false
    private var lastSnapshot: Snapshot?
    private var lastDiagnostic: Diagnostic?
    private var runningSessionID: String?
    private var lastRunningDelivery = Date.distantPast

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Run one bounded accessibility read immediately after a manual HUD
    /// resync. This does not send anything to Claude or create a new turn.
    func refreshNow() {
        poll()
    }

    private func poll() {
        guard !pollInFlight else { return }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.anthropic.claudefordesktop"
        }) else {
            receive(Observation(diagnostic: .notRunning))
            return
        }
        let pid = app.processIdentifier
        let launch = app.launchDate?.timeIntervalSince1970 ?? 0
        pollInFlight = true
        Task { [weak self] in
            let observation = await Task.detached(priority: .utility) {
                Self.scan(pid: pid, launch: launch)
            }.value
            guard let self else { return }
            self.pollInFlight = false
            guard self.timer != nil else { return }
            self.receive(observation)
        }
    }

    // Kept separate from AX I/O so real store transitions can be verified in isolation.
    func receive(_ observation: Observation, at date: Date = Date()) {
        if lastDiagnostic != observation.diagnostic {
            lastDiagnostic = observation.diagnostic
            onDiagnostic?(observation.diagnostic)
        }
        guard observation.diagnostic != .codeMode,
              let session = observation.sessionID else {
            emitUnknownIfNeeded(detail: observation.diagnostic.rawValue)
            return
        }
        if observation.running {
            if let previous = runningSessionID, previous != session {
                emit(Snapshot(phase: .unknown, sessionID: previous, detail: "Claude Chat 已切换窗口，原任务状态未知"))
            }
            runningSessionID = session
            let snapshot = Snapshot(phase: .running, sessionID: session, detail: "Claude Chat 正在生成")
            // A confirmed running signal refreshes long tasks without pulsing the island again.
            if lastSnapshot != snapshot || date.timeIntervalSince(lastRunningDelivery) >= 30 {
                lastRunningDelivery = date
                emit(snapshot, force: true)
            }
        } else if runningSessionID == session && observation.idle && observation.scanComplete {
            runningSessionID = nil
            emit(Snapshot(phase: .completed, sessionID: session, detail: "Claude Chat 本轮已结束"))
        } else {
            emitUnknownIfNeeded(detail: "Claude Chat 状态暂不可读")
        }
    }

    private func emitUnknownIfNeeded(detail: String) {
        guard let session = runningSessionID else { return }
        emit(Snapshot(phase: .unknown, sessionID: session, detail: detail))
    }

    private func emit(_ snapshot: Snapshot, force: Bool = false) {
        guard force || lastSnapshot != snapshot else { return }
        lastSnapshot = snapshot
        onSnapshot?(snapshot)
    }

    private nonisolated static func scan(pid: pid_t, launch: TimeInterval) -> Observation {
        guard AXIsProcessTrusted() else { return Observation(diagnostic: .permissionRequired) }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        let windowsRead = read(application, attribute: kAXWindowsAttribute)
        let windows = windowsRead.value as? [AXUIElement] ?? []
        if isBlocking(windowsRead.error) { return Observation(diagnostic: .windowUnavailable) }
        guard let window = copyElement(application, attribute: kAXFocusedWindowAttribute) ?? windows.first else {
            return Observation(diagnostic: .windowUnavailable)
        }
        var session: String?
        var running = false, idle = false, codeMode = false, complete = true
        var remaining = 1_200
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        while let (element, depth) = stack.popLast() {
            guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else {
                complete = false
                break
            }
            remaining -= 1
            guard depth <= 36 else { complete = false; continue }
            let roleRead = read(element, attribute: kAXRoleAttribute)
            guard let role = roleRead.value as? String else {
                complete = false
                continue
            }
            if role == kAXTextAreaRole || role == kAXTextFieldRole ||
                role == kAXStaticTextRole || role == "AXHeading" || role == "AXLink" { continue }
            if role == "AXWebArea" {
                // Read only the document route; retain its digest, never the URL or page title.
                let value = copy(element, attribute: kAXURLAttribute)
                let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                if let url {
                    let route = documentIdentity(url: url, pid: pid, launch: launch)
                    if route.codeMode { return Observation(diagnostic: .codeMode) }
                    if let id = route.sessionID { session = id }
                }
            }
            if role == kAXGroupRole {
                var label = ""
                for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
                    let result = read(element, attribute: attribute)
                    if isBlocking(result.error) { complete = false }
                    if let value = result.value as? String { label = value; break }
                }
                if label == "Chat messages" || label == "Sidebar" || label.hasPrefix("Message ") { continue }
                if label == "Currently streaming message" { running = true }
            } else if role == kAXButtonRole || role == kAXPopUpButtonRole {
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    let result = read(element, attribute: attribute)
                    if isBlocking(result.error) { complete = false }
                    guard let label = result.value as? String else { continue }
                    switch label {
                    case "Stop", "Stop response", "停止", "停止回复", "停止生成": running = true
                    case "Send", "Send message", "发送": idle = true
                    case "Claude code" where role == kAXPopUpButtonRole: codeMode = true
                    default: break
                    }
                }
            }
            let childrenRead = read(element, attribute: kAXChildrenAttribute)
            if isBlocking(childrenRead.error) { complete = false }
            if let children = childrenRead.value as? [AXUIElement] {
                stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        if codeMode { return Observation(diagnostic: .codeMode) }
        guard let session else { return Observation(diagnostic: complete ? .unsupportedPage : .unreadable) }
        return Observation(diagnostic: running ? .running : (idle && complete ? .idle : (complete ? .observing : .unreadable)),
                           sessionID: session, running: running, idle: idle, scanComplete: complete)
    }

    nonisolated static func documentIdentity(url: URL, pid: pid_t, launch: TimeInterval) -> (sessionID: String?, codeMode: Bool) {
        let route = url.pathComponents.filter { $0 != "/" }
        let local = url.scheme == "app" && url.host == "localhost"
        let remote = url.scheme == "https" && url.host == "claude.ai"
        if local && route.first == "epitaxy" { return (nil, true) }
        guard route.count == 2, !route[1].isEmpty,
              (local && ["chat", "cowork"].contains(route[0])) || (remote && route[0] == "chat") else {
            return (nil, false)
        }
        return ("s_" + IdentityDigest.digest(namespace: "claude-chat-v2", components: [
            String(pid), String(launch), route[0], route[1]
        ]), false)
    }

    private nonisolated static func read(_ element: AXUIElement, attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    private nonisolated static func copy(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        read(element, attribute: attribute).value
    }

    nonisolated static func isBlocking(_ error: AXError) -> Bool {
        error != .success && error != .attributeUnsupported && error != .noValue
    }

    private nonisolated static func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute: attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
