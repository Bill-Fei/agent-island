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
        // Electron can leave its web accessibility tree disabled until explicitly requested.
        _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = copy(application, attribute: kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let window = copyElement(application, attribute: kAXFocusedWindowAttribute) ?? windows.first else {
            return Observation(diagnostic: .windowUnavailable)
        }
        let session = "s_" + IdentityDigest.digest(namespace: "claude-chat-v1", components: [
            String(pid), String(launch), String(CFHash(window))
        ])
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
            guard let role = copy(element, attribute: kAXRoleAttribute) as? String else {
                complete = false
                continue
            }
            if role == kAXTextAreaRole || role == kAXTextFieldRole { continue }
            if role == kAXGroupRole {
                let label = (copy(element, attribute: kAXDescriptionAttribute) as? String) ??
                    (copy(element, attribute: kAXTitleAttribute) as? String) ?? ""
                if label == "Chat messages" || label == "Sidebar" || label.hasPrefix("Message ") { continue }
                if label == "Currently streaming message" { running = true }
            } else if role == kAXButtonRole || role == kAXPopUpButtonRole {
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    guard let label = copy(element, attribute: attribute) as? String else { continue }
                    switch label {
                    case "Stop", "Stop response", "停止", "停止回复", "停止生成": running = true
                    case "Send", "Send message", "发送": idle = true
                    case "Claude code" where role == kAXPopUpButtonRole: codeMode = true
                    default: break
                    }
                }
            } else if role == kAXStaticTextRole {
                if let label = copy(element, attribute: kAXValueAttribute) as? String,
                   label == "Claude is responding" || label == "正在生成" { running = true }
            }
            if let children = copy(element, attribute: kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        if codeMode { return Observation(diagnostic: .codeMode) }
        return Observation(diagnostic: running ? .running : (idle && complete ? .idle : (complete ? .observing : .unreadable)),
                           sessionID: session, running: running, idle: idle, scanComplete: complete)
    }

    private nonisolated static func copy(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private nonisolated static func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute: attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
