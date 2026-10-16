import AppKit
import ApplicationServices
import LinglongtaiShared

/// Presses "Allow once" / "Deny" on Claude Desktop's own permission card.
/// Desktop ignores hook decisions, so this is the only way an island choice
/// can take effect there. It presses only inside the web view routed to the
/// exact session, only when that view holds exactly one card whose own text
/// shows the reviewed request, only after re-checking Desktop's log that this
/// card is still the session's only open one, and success is judged afterwards
/// from Desktop's own log, never assumed.
@MainActor
enum ClaudeHostApproval {
    private static let bundleID = "com.anthropic.claudefordesktop"

    static func deliver(session: String, promptID: String, decision: ApprovalRelay.Decision,
                        stillOpen: @escaping () -> Bool, context: String,
                        completion: @escaping (TaskStore.HostPressOutcome) -> Void) {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else {
            completion(.failed(code: "untrusted", reason: "需要在系统设置里允许灵动岛使用辅助功能"))
            return
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            completion(.failed(code: "not-running", reason: "Claude 未运行"))
            return
        }
        guard let snippet = reviewedSnippet(context) else {
            completion(.failed(code: "no-snippet", reason: "这次请求无法与 App 中的卡片逐字核对"))
            return
        }
        let pid = app.processIdentifier
        let previous = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            // A session already on screen (main window or split pane) is pressed in place.
            var result = press(pid: pid, session: session, decision: decision, snippet: snippet, stillOpen: stillOpen)
            var navigated = false
            if result == .sessionNotVisible, let url = URL(string: "claude://claude.ai/epitaxy/\(session)") {
                navigated = NSWorkspace.shared.open(url)
                let deadline = Date().addingTimeInterval(3)
                while navigated, [.sessionNotVisible, .noCard].contains(result), Date() < deadline {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    result = press(pid: pid, session: session, decision: decision, snippet: snippet, stillOpen: stillOpen)
                }
            }
            if navigated, let previous, previous.processIdentifier != pid,
               previous.bundleIdentifier != Bundle.main.bundleIdentifier {
                previous.activate()
            }
            switch result {
            case .pressed: completion(.pressed)
            case .sessionNotVisible: completion(.failed(code: "session-not-visible", reason: "没能打开对应的对话"))
            case .ambiguous: completion(.failed(code: "ambiguous", reason: "该对话里有多张确认卡"))
            case .noCard: completion(.failed(code: "no-card", reason: "没找到 App 中的确认卡"))
            case .textMismatch: completion(.failed(code: "text-mismatch", reason: "App 中的卡片与岛上审阅的内容不一致"))
            case .cardChanged: completion(.failed(code: "card-changed", reason: "App 中的确认卡已经变化"))
            case .pressFailed: completion(.failed(code: "press-failed", reason: "按钮没有响应"))
            }
        }
    }

    enum ScanResult: Equatable { case pressed, sessionNotVisible, noCard, ambiguous, textMismatch, cardChanged, pressFailed }

    /// The longest string argument's first line: what the card itself displays.
    static func reviewedSnippet(_ context: String) -> String? {
        guard let data = context.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arguments = object["arguments"] as? [String: Any] else { return nil }
        let longest = arguments.values.compactMap { $0 as? String }.max { $0.count < $1.count } ?? ""
        let line = compact(longest.split(separator: "\n").first.map(String.init) ?? "")
        return line.count >= 4 ? String(line.prefix(24)) : nil
    }

    /// Whitespace-free, so highlighted code split into spans or wrapped lines still compares.
    private static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    /// Runs entirely on the main actor, so the log re-check and the press are
    /// one uninterrupted step. Bounded AX timeouts keep it short.
    private static func press(pid: pid_t, session: String, decision: ApprovalRelay.Decision,
                              snippet: String, stillOpen: () -> Bool) -> ScanResult {
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
        guard cardText(allow[0], deny[0], contains: snippet) else { return .textMismatch }
        guard stillOpen() else { return .cardChanged }
        let target = decision == .allow ? allow[0] : deny[0]
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success ? .pressed : .pressFailed
    }

    /// The card is the nearest container of both buttons; its own text must
    /// show the reviewed command, so a different card is never pressed.
    private static func cardText(_ allow: AXUIElement, _ deny: AXUIElement, contains snippet: String) -> Bool {
        var chain: [AXUIElement] = []
        var cursor: AXUIElement? = allow
        while let element = cursor, chain.count < 16 { chain.append(element); cursor = parent(of: element) }
        var common: AXUIElement?
        cursor = deny
        for _ in 0..<16 {
            guard let element = cursor else { break }
            if chain.contains(where: { CFEqual($0, element) }) { common = element; break }
            cursor = parent(of: element)
        }
        guard var container = common else { return false }
        for _ in 0..<6 {
            var texts: [AXUIElement] = []
            collect(from: container, into: &texts) {
                let role = copy($0, kAXRoleAttribute) as? String
                return role == kAXStaticTextRole || role == kAXTextAreaRole
            }
            let text = compact(texts.compactMap { copy($0, kAXValueAttribute) as? String }.joined())
            if text.contains(snippet) { return true }
            guard let next = parent(of: container) else { return false }
            container = next
        }
        return false
    }

    /// The Code tab routes each session's web view as app://localhost/epitaxy/<session>.
    private static func isSessionArea(_ element: AXUIElement, session: String) -> Bool {
        guard (copy(element, kAXRoleAttribute) as? String) == "AXWebArea" else { return false }
        let value = copy(element, kAXURLAttribute)
        guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)),
              url.scheme == "app", url.host == "localhost" else { return false }
        return url.pathComponents.filter { $0 != "/" } == ["epitaxy", session]
    }

    /// Bounded depth-first walk; matches are not descended into.
    private static func collect(from root: AXUIElement, into found: inout [AXUIElement],
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

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = copy(element, kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
