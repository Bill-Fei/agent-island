import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import CoreServices
import LinglongtaiShared

/// Reads OS lifecycle/window metadata, never private chat contents or logs.
/// Running application != running task; the UI keeps these two facts separate.
@MainActor
final class AgentPresence: ObservableObject {
    static let shared = AgentPresence()
    @Published private(set) var running: Set<AgentKind> = []
    @Published private(set) var foreground: AgentKind?
    @Published private(set) var icons: [AgentKind: NSImage] = [:]
    @Published private(set) var opening: Set<AgentKind> = []
    @Published private(set) var launchErrors: [AgentKind: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private var iconPaths: [AgentKind: String] = [:]
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
        guard !opening.contains(kind) else { return }
        launchErrors[kind] = nil
        guard let url = applicationURL(for: kind) else {
            launchErrors[kind] = "未找到 \(kind.displayName)，请确认应用已安装。"
            return
        }
        opening.insert(kind)
        let configuration = Self.openConfiguration(bundleID: Self.bundleIDs[kind], isRunning: running.contains(kind))
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil || app == nil {
                    self.launchErrors[kind] = "未能打开 \(kind.displayName)，请重试或从访达打开。"
                    self.opening.remove(kind)
                } else if let app {
                    app.unhide()
                    if !app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
                        self.launchErrors[kind] = "\(kind.displayName) 已运行，但未能切到前台，请从程序坞打开。"
                        self.opening.remove(kind)
                    } else {
                        await self.verifyVisibleWindow(of: app, kind: kind)
                    }
                }
                self.refresh()
            }
        }
    }

    func canOpen(_ kind: AgentKind) -> Bool {
        applicationURL(for: kind) != nil
    }

    static func openConfiguration(bundleID: String?, isRunning: Bool) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.hides = false
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        // A running process can own the menu bar with no usable window.
        // Explicitly request the same reopen event used by a Dock click.
        if let bundleID, isRunning {
            configuration.appleEvent = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
            )
        }
        return configuration
    }

    private func verifyVisibleWindow(of app: NSRunningApplication, kind: AgentKind) async {
        defer { opening.remove(kind) }
        if Self.hasVisibleWindow(pid: app.processIdentifier) { return }
        let pid = app.processIdentifier
        let restoration = await Task.detached(priority: .userInitiated) {
            Self.restoreAccessibleWindow(pid: pid)
        }.value
        // A restored window only comes forward once the app is activated again.
        if restoration == .attempted { app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) }
        // Observe only window geometry and PID, never titles or window contents.
        // Reopening is asynchronous; allow a short bounded creation interval.
        for _ in 0..<12 {
            if app.isTerminated {
                launchErrors[kind] = "\(kind.displayName) 在打开窗口时已退出，请重新打开。"
                return
            }
            if Self.hasVisibleWindow(pid: app.processIdentifier) { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        launchErrors[kind] = Self.windowUnavailableMessage(kind: kind, restoration: restoration)
    }

    private static func hasVisibleWindow(pid: pid_t) -> Bool {
        visibleWindowExists(pid: pid, windows: CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])
    }

    enum WindowRestoration: Sendable { case permissionRequired, attempted, unavailable }

    private nonisolated static func restoreAccessibleWindow(pid: pid_t) -> WindowRestoration {
        // Asking (instead of only checking) adds the island to System Settings →
        // Accessibility and shows the system prompt; without it the app is absent
        // from that list and cannot be enabled there.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { return .permissionRequired }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let windows = rawWindows as? [AXUIElement] else { return .unavailable }
        for window in windows.prefix(4) {
            AXUIElementSetMessagingTimeout(window, 0.1)
            var subrole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
                  subrole as? String == kAXStandardWindowSubrole else { continue }
            // Only manipulate window lifecycle attributes; never read titles or content.
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFBoolean)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFBoolean)
            return .attempted
        }
        return .unavailable
    }

    static func windowUnavailableMessage(kind: AgentKind, restoration: WindowRestoration) -> String {
        if restoration == .permissionRequired {
            return "\(kind.displayName) 已激活，但窗口未出现。灵动岛尚无辅助功能权限，无法恢复最小化窗口：请在系统设置 → 隐私与安全性 → 辅助功能中打开「Agent 灵动岛」后再点一次；若已打开仍无效，先用 − 删除该项再重试。"
        }
        return "\(kind.displayName) 已激活，但窗口仍未出现在当前桌面。请点击程序坞图标恢复窗口，或检查其他桌面。"
    }

    static func visibleWindowExists(pid: pid_t, windows: [[String: Any]]?) -> Bool {
        guard let windows else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return false }
            return width >= 100 && height >= 100
        }
    }

    private func applicationURL(for kind: AgentKind) -> URL? {
        guard let bundleID = Self.bundleIDs[kind] else { return nil }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }), let url = running.bundleURL { return url }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private func refresh() {
        for (kind, bundleID) in Self.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                if iconPaths[kind] != url.path {
                    icons[kind] = NSWorkspace.shared.icon(forFile: url.path)
                    iconPaths[kind] = url.path
                }
            } else if icons[kind] != nil {
                icons[kind] = nil
                iconPaths[kind] = nil
            }
        }
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let nextRunning = Set(Self.bundleIDs.compactMap { ids.contains($0.value) ? $0.key : nil })
        if running != nextRunning { running = nextRunning }
        let activeID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let nextForeground = Self.bundleIDs.first { $0.value == activeID }?.key
        if foreground != nextForeground { foreground = nextForeground }
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
