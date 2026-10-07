import ApplicationServices
import AppKit
import Foundation
import LinglongtaiShared

/// Read-only bridge for Claude Desktop's visible Chat/Cowork state.
/// It compares only a small allow-list of accessibility status strings.
/// Message bodies, input values, URLs, and titles are never retained or emitted.
@MainActor
final class ClaudeChatObserver {
    enum Phase: Equatable {
        case running
        case completed
        case unknown
    }

    struct Snapshot: Equatable {
        let phase: Phase
        let sessionID: String
        let detail: String
    }

    var onSnapshot: ((Snapshot) -> Void)?

    private let bundleIdentifier = "com.anthropic.claudefordesktop"
    private var timer: Timer?
    private var lastSnapshot: Snapshot?
    private var lastSessionID: String?
    private var runningSessionID: String?

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) else {
            emitUnknownIfNeeded(sessionID: lastSessionID ?? sessionID(for: nil, window: nil),
                                detail: "Claude Chat 应用未运行，状态未知")
            return
        }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        let focusedWindow = copyElement(application, attribute: kAXFocusedWindowAttribute)
        let windows = (copy(application, attribute: kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let window = focusedWindow ?? windows.first
        let session = sessionID(for: app, window: window)

        guard AXIsProcessTrusted() else {
            emitUnknownIfNeeded(sessionID: session, detail: "Claude Chat 需要辅助功能权限，状态未知")
            return
        }
        guard let window else {
            emitUnknownIfNeeded(sessionID: session, detail: "未读取到 Claude Chat 窗口，状态未知")
            return
        }

        var signals = Set<Signal>()
        collectSignals(from: window, depth: 0, into: &signals)
        if signals.contains(.responding) || signals.contains(.streaming) || signals.contains(.stop) {
            runningSessionID = session
            emit(Snapshot(phase: .running, sessionID: session, detail: "Claude Chat 正在生成"))
        } else if runningSessionID == session && signals.contains(.send) {
            runningSessionID = nil
            emit(Snapshot(phase: .completed, sessionID: session, detail: "Claude Chat 本轮已结束"))
        } else if let runningSessionID {
            emitUnknownIfNeeded(sessionID: runningSessionID, detail: "Claude Chat 状态暂不可读")
        }
    }

    private func emitUnknownIfNeeded(sessionID: String, detail: String) {
        guard runningSessionID != nil else { return }
        emit(Snapshot(phase: .unknown, sessionID: sessionID, detail: detail))
    }

    private func emit(_ snapshot: Snapshot) {
        lastSessionID = snapshot.sessionID
        guard lastSnapshot != snapshot else { return }
        lastSnapshot = snapshot
        onSnapshot?(snapshot)
    }

    private enum Signal: Hashable {
        case responding
        case streaming
        case stop
        case send
    }

    private func collectSignals(from element: AXUIElement, depth: Int, into signals: inout Set<Signal>) {
        guard depth < 14 else { return }
        let role = stringValue(copy(element, attribute: kAXRoleAttribute))
        if role == kAXStaticTextRole || role == kAXButtonRole || role == kAXGroupRole {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                guard let text = stringValue(copy(element, attribute: attribute)) else { continue }
                switch text {
                case "Claude is responding", "正在生成": signals.insert(.responding)
                case "Currently streaming message", "正在流式生成": signals.insert(.streaming)
                case "Stop response", "停止回复", "停止生成": signals.insert(.stop)
                case "Send message", "Send", "发送": signals.insert(.send)
                default: break
                }
            }
        }
        guard let children = copy(element, attribute: kAXChildrenAttribute) as? [AXUIElement] else { return }
        for child in children { collectSignals(from: child, depth: depth + 1, into: &signals) }
    }

    private func copy(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return error == .success ? value : nil
    }

    private func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute: attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func stringValue(_ value: CFTypeRef?) -> String? { value as? String }

    private func sessionID(for app: NSRunningApplication?, window: AXUIElement?) -> String {
        let pid = app?.processIdentifier ?? 0
        let launch = app?.launchDate?.timeIntervalSince1970 ?? 0
        let windowHash = window.map { String(CFHash($0)) } ?? "none"
        return "s_" + IdentityDigest.digest(namespace: "claude-chat-v1", components: [
            String(pid), String(launch), windowHash
        ])
    }
}
