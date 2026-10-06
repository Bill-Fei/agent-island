import AppKit
import Combine
import LinglongtaiShared

/// Reads only OS application lifecycle, never private chat contents or logs.
/// Running application != running task; the UI keeps these two facts separate.
@MainActor
final class AgentPresence: ObservableObject {
    static let shared = AgentPresence()
    @Published private(set) var running: Set<AgentKind> = []
    @Published private(set) var foreground: AgentKind?
    @Published private(set) var icons: [AgentKind: NSImage] = [:]
    private var observers: [NSObjectProtocol] = []
    private static let bundleIDs: [AgentKind: String] = [
        .codex: "com.openai.codex",
        .claude: "com.anthropic.claudefordesktop",
        .doubao: "com.bot.pc.doubao",
        .workBuddy: "com.workbuddy.workbuddy"
    ]

    init() {
        refresh()
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } })
        }
    }

    func label(for kind: AgentKind) -> String {
        if foreground == kind { return "应用在前台" }
        return running.contains(kind) ? "应用运行中" : "应用未运行"
    }

    func open(_ kind: AgentKind) {
        guard let bundleID = Self.bundleIDs[kind],
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func canOpen(_ kind: AgentKind) -> Bool {
        guard let bundleID = Self.bundleIDs[kind] else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private func refresh() {
        for (kind, bundleID) in Self.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                icons[kind] = NSWorkspace.shared.icon(forFile: url.path)
            } else { icons[kind] = nil }
        }
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        running = Set(Self.bundleIDs.compactMap { ids.contains($0.value) ? $0.key : nil })
        let activeID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        foreground = Self.bundleIDs.first { $0.value == activeID }?.key
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
