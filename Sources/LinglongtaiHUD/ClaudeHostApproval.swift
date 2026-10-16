import AppKit
import ApplicationServices
import LinglongtaiShared

/// Presses "Allow once" / "Deny" on Claude Desktop's own permission card.
/// Desktop ignores hook decisions, so this is the only way an island choice
/// can take effect there. It presses only inside the web view routed to the
/// exact session, only when that view holds exactly one card, and success is
/// judged afterwards from Desktop's own log, never assumed.
@MainActor
enum ClaudeHostApproval {
    private static let bundleID = "com.anthropic.claudefordesktop"

    static func deliver(session: String, promptID: String, decision: ApprovalRelay.Decision,
                        completion: @escaping (TaskStore.HostPressOutcome) -> Void) {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            completion(.failed("需要在系统设置里允许灵动岛使用辅助功能"))
            return
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            completion(.failed("Claude 未运行"))
            return
        }
        let pid = app.processIdentifier
        let previous = NSWorkspace.shared.frontmostApplication
        Task {
            // A session already on screen (main window or split pane) is pressed in place.
            var result = await scanAndPress(pid: pid, session: session, decision: decision, wait: 0)
            var navigated = false
            if result == .sessionNotVisible, let url = URL(string: "claude://claude.ai/epitaxy/\(session)") {
                navigated = NSWorkspace.shared.open(url)
                if navigated { result = await scanAndPress(pid: pid, session: session, decision: decision, wait: 3) }
            }
            if navigated, let previous, previous.processIdentifier != pid,
               previous.bundleIdentifier != Bundle.main.bundleIdentifier {
                previous.activate()
            }
            switch result {
            case .pressed: completion(.pressed)
            case .sessionNotVisible: completion(.failed("没能打开对应的对话"))
            case .ambiguous: completion(.failed("该对话里有多张确认卡"))
            case .noCard: completion(.failed("没找到 App 中的确认卡"))
            case .pressFailed: completion(.failed("按钮没有响应"))
            }
        }
    }

    enum ScanResult: Equatable, Sendable { case pressed, sessionNotVisible, noCard, ambiguous, pressFailed }

    private static func scanAndPress(pid: pid_t, session: String, decision: ApprovalRelay.Decision,
                                     wait: TimeInterval) async -> ScanResult {
        await Task.detached(priority: .userInitiated) {
            let deadline = ProcessInfo.processInfo.systemUptime + wait
            var result = ScanResult.sessionNotVisible
            repeat {
                result = pressCard(pid: pid, session: session, decision: decision)
                if result == .pressed || result == .ambiguous || result == .pressFailed { return result }
                usleep(150_000)
            } while ProcessInfo.processInfo.systemUptime < deadline
            return result
        }.value
    }

    private nonisolated static func pressCard(pid: pid_t, session: String, decision: ApprovalRelay.Decision) -> ScanResult {
        let application = AXUIElementCreateApplication(pid)
        // Electron builds its accessibility tree only for assistive clients that ask.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let windows = copy(application, kAXWindowsAttribute) as? [AXUIElement] else { return .sessionNotVisible }
        var areas: [AXUIElement] = []
        for window in windows { collect(from: window, into: &areas) { isSessionArea($0, session: session) } }
        guard !areas.isEmpty else { return .sessionNotVisible }
        var allow: [AXUIElement] = [], deny: [AXUIElement] = []
        for area in areas {
            var buttons: [AXUIElement] = []
            collect(from: area, into: &buttons) { (copy($0, kAXRoleAttribute) as? String) == kAXButtonRole }
            for button in buttons {
                let title = (copy(button, kAXTitleAttribute) as? String) ?? ""
                if ["Allow once", "仅允许一次", "允许一次"].contains(where: title.hasPrefix) { allow.append(button) }
                if ["Deny", "拒绝"].contains(where: title.hasPrefix) { deny.append(button) }
            }
        }
        // A real card shows both choices; anything else is not ours to press.
        guard !allow.isEmpty, !deny.isEmpty else { return .noCard }
        guard allow.count == 1, deny.count == 1 else { return .ambiguous }
        let target = decision == .allow ? allow[0] : deny[0]
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success ? .pressed : .pressFailed
    }

    /// The Code tab routes each session's web view as app://localhost/epitaxy/<session>.
    private nonisolated static func isSessionArea(_ element: AXUIElement, session: String) -> Bool {
        guard (copy(element, kAXRoleAttribute) as? String) == "AXWebArea" else { return false }
        let value = copy(element, kAXURLAttribute)
        guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)),
              url.scheme == "app", url.host == "localhost" else { return false }
        return url.pathComponents.filter { $0 != "/" } == ["epitaxy", session]
    }

    /// Bounded depth-first walk; matches are not descended into.
    private nonisolated static func collect(from root: AXUIElement, into found: inout [AXUIElement],
                                           where matches: (AXUIElement) -> Bool) {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var budget = 8_000
        while let (element, depth) = stack.popLast(), budget > 0 {
            budget -= 1
            if matches(element) { found.append(element); continue }
            guard depth < 48, let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
    }

    private nonisolated static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
