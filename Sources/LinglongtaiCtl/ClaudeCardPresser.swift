import AppKit
import ApplicationServices
import Darwin
import LinglongtaiShared

/// Presses "Allow once" / "Deny" on Claude Desktop's own permission card after
/// the island's decision. Desktop ignores hook decisions, so this is the only
/// way an island choice can take effect there.
///
/// It runs as a detached child of the PermissionRequest hook, so macOS
/// attributes it to Claude Desktop and it uses Desktop's own accessibility
/// permission (an ad-hoc island loses its grant on every rebuild, and its
/// presses were silently ignored). It presses only inside the web view routed
/// to the exact session, only when that view holds exactly one card whose own
/// text shows the reviewed command, and only after re-checking Desktop's log
/// that the reviewed card is still that session's only open card.
enum ClaudeCardPresser {
    private static let bundleID = "com.anthropic.claudefordesktop"

    /// `linglongtaictl host-press --request <id>`: wait for the island's
    /// decision on this request, press once, report a fixed result code, exit.
    static func run(requestID: UUID, isolated: Bool) {
        while let request = ApprovalRelay.hostRequest(requestID) {
            if let reply = ApprovalRelay.hostReply(requestID) {
                let code = isolated ? "isolated" : press(request: request, decision: reply.decision, promptID: reply.promptID)
                ApprovalRelay.writeHostResult(requestID, code)
                ApprovalTrace.record(requestID, "presser-" + code)
                return
            }
            usleep(150_000)
        }
        // Superseded by a newer check, answered in Desktop, or expired.
    }

    /// Detach from the hook: own session, no inherited stdio (Desktop waits
    /// for the hook's stdout to close), same executable.
    static func spawn(requestID: UUID, passthrough: [String]) {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return }
        let path = String(cString: buffer)
        let arguments = [path, "host-press", "--request", requestID.uuidString] + passthrough
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        _ = posix_spawn(&pid, path, &actions, &attributes, &argv, environ)
    }

    private static func press(request: ApprovalRelay.Request, decision: ApprovalRelay.Decision, promptID: String) -> String {
        guard let session = request.hostSessionID else { return "not-host" }
        guard AXIsProcessTrusted() else { return "untrusted" }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return "not-running" }
        guard let snippet = reviewedSnippet(request.context) else { return "no-snippet" }
        let stillOpen = {
            var log = ClaudePromptLog()
            _ = log.poll()
            let open = log.openPrompts(in: session)
            return open.count == 1 && open.first?.id == promptID
        }
        guard stillOpen() else { return "card-changed" }
        let pid = app.processIdentifier
        var result = pressCard(pid: pid, session: session, decision: decision, snippet: snippet, stillOpen: stillOpen)
        if result == "session-not-visible", let url = URL(string: "claude://claude.ai/epitaxy/\(session)") {
            // The card is pressable only while its session is on screen.
            let previous = NSWorkspace.shared.frontmostApplication
            if NSWorkspace.shared.open(url) {
                let deadline = Date().addingTimeInterval(3)
                while ["session-not-visible", "no-card"].contains(result), Date() < deadline {
                    usleep(150_000)
                    result = pressCard(pid: pid, session: session, decision: decision, snippet: snippet, stillOpen: stillOpen)
                }
                if let previous, previous.processIdentifier != pid { previous.activate() }
            }
        }
        return result
    }

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

    private static func pressCard(pid: pid_t, session: String, decision: ApprovalRelay.Decision,
                                  snippet: String, stillOpen: () -> Bool) -> String {
        let application = AXUIElementCreateApplication(pid)
        // Electron builds its accessibility tree only for assistive clients that ask.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let windows = copy(application, kAXWindowsAttribute) as? [AXUIElement] else { return "session-not-visible" }
        var areas: [AXUIElement] = []
        for window in windows { collect(from: window, into: &areas) { isSessionArea($0, session: session) } }
        guard !areas.isEmpty else { return "session-not-visible" }
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
        guard !allow.isEmpty, !deny.isEmpty else { return "no-card" }
        guard allow.count == 1, deny.count == 1 else { return "ambiguous" }
        guard cardText(allow[0], deny[0], contains: snippet) else { return "text-mismatch" }
        guard stillOpen() else { return "card-changed" }
        let target = decision == .allow ? allow[0] : deny[0]
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success ? "pressed" : "press-failed"
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
