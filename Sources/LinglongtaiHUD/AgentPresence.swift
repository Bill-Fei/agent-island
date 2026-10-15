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
        // WorkBuddy's macOS app identifies itself as Tencent WorkBuddy.
        // The old `com.workbuddy.workbuddy` value never resolved on installed
        // builds, so the island silently fell back to the generic SF Symbol.
        .workBuddy: "com.tencent.workbuddy.mac"
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
            launchErrors[kind] = LF("未找到 %@，请确认应用已安装。", L(kind.displayName))
            return
        }
        opening.insert(kind)
        let configuration = Self.openConfiguration(bundleID: Self.bundleIDs[kind], isRunning: running.contains(kind))
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil || app == nil {
                    self.launchErrors[kind] = LF("未能打开 %@，请重试或从访达打开。", L(kind.displayName))
                    self.opening.remove(kind)
                } else if let app {
                    await self.verifyVisibleWindow(of: app, kind: kind)
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

    /// Done only when the app is frontmost *and* shows a window; either alone
    /// leaves the user looking at the same screen as before the click.
    private func verifyVisibleWindow(of app: NSRunningApplication, kind: AgentKind) async {
        defer { opening.remove(kind) }
        let pid = app.processIdentifier
        func reached(polls: Int) async -> Bool {
            for _ in 0..<polls {
                if Self.isFrontmost(pid: pid) && Self.frontWindowIsOwn(pid: pid) { return true }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return false
        }
        // 1. Bring the app forward (switches to the desktop holding its window).
        bringForward(app)
        // Switching to the window's desktop takes a moment, and Accessibility
        // lists no window until it lands; raise once more after the switch.
        // A raise during the switch reports success but has no effect, so an
        // early success cannot end the wait.
        try? await Task.sleep(nanoseconds: 400_000_000)
        _ = Self.raiseMainWindow(pid: pid)
        if await reached(polls: 4) { return }
        // 2. Frontmost without a window: ask it to reopen one, like a Dock click.
        if let bundleID = app.bundleIdentifier {
            await Task.detached(priority: .userInitiated) { Self.launchServicesReopen(bundleID: bundleID) }.value
            bringForward(app)
            if await reached(polls: 6) { return }
        }
        // 3. Still nothing: un-minimize a window through Accessibility.
        let restoration = await Task.detached(priority: .userInitiated) {
            Self.restoreAccessibleWindow(pid: pid)
        }.value
        bringForward(app)
        if await reached(polls: 8) { return }
        if app.isTerminated {
            launchErrors[kind] = LF("%@ 在打开窗口时已退出，请重新打开。", L(kind.displayName))
        } else if Self.hasVisibleWindow(pid: pid) && !Self.isFrontmost(pid: pid) {
            launchErrors[kind] = LF("%@ 的窗口已打开，但系统未允许切到前台，请点击程序坞图标。", L(kind.displayName))
        } else {
            launchErrors[kind] = Self.windowUnavailableMessage(kind: kind, restoration: restoration)
        }
    }

    /// A non-activating panel cannot activate another app on macOS 14+
    /// (cooperative activation). Take activation from the user's click first,
    /// then hand it to the target; Accessibility frontmost covers older paths.
    private func bringForward(_ app: NSRunningApplication) {
        app.unhide()
        if #available(macOS 14.0, *) {
            NSApp.activate()
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [.activateAllWindows])
        } else {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        _ = Self.bringFrontmost(pid: app.processIdentifier)
        _ = Self.raiseMainWindow(pid: app.processIdentifier)
    }

    private static func isFrontmost(pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func hasVisibleWindow(pid: pid_t) -> Bool {
        visibleWindowExists(pid: pid, windows: onScreenWindows())
    }

    private static func frontWindowIsOwn(pid: pid_t) -> Bool {
        frontWindowBelongs(to: pid, windows: onScreenWindows())
    }

    private static func onScreenWindows() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }

    enum WindowRestoration: Sendable { case permissionRequired, attempted, noWindow, unavailable }

    /// Makes the app frontmost through Accessibility. Only sets the frontmost
    /// flag; never reads titles or content. False when not yet trusted.
    private nonisolated static func bringFrontmost(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        return AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, true as CFBoolean) == .success
    }

    /// Activation alone can leave another app's window on top; raise this app's
    /// main window explicitly. Only window order changes; titles are never read.
    private nonisolated static func raiseMainWindow(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var candidates: [AXUIElement] = []
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                candidates.append(value as! AXUIElement)
            }
        }
        var rawWindows: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
           let windows = rawWindows as? [AXUIElement] {
            candidates.append(contentsOf: windows.prefix(4))
        }
        // Some apps (Doubao) expose no standard-subrole window, so prefer a
        // standard one but fall back to any window that is not minimized.
        var fallback: AXUIElement?
        for window in candidates {
            AXUIElementSetMessagingTimeout(window, 0.2)
            var subrole: CFTypeRef?
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            if (minimized as? Bool) == true { continue }
            if subrole as? String == kAXStandardWindowSubrole {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFBoolean)
                return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
            }
            if fallback == nil { fallback = window }
        }
        guard let fallback else { return false }
        AXUIElementSetAttributeValue(fallback, kAXMainAttribute as CFString, true as CFBoolean)
        return AXUIElementPerformAction(fallback, kAXRaiseAction as CFString) == .success
    }

    private nonisolated static func launchServicesReopen(bundleID: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
    }

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
        if windows.isEmpty { return .noWindow }
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
            return LF("%@ 已激活，但窗口未出现。灵动岛尚无辅助功能权限，无法恢复最小化窗口：请在系统设置 → 隐私与安全性 → 辅助功能中打开「Agent 灵动岛」后再点一次；若已打开仍无效，先用 − 删除该项再重试。", L(kind.displayName))
        }
        switch restoration {
        case .noWindow:
            return LF("%1$@ 在运行，但没有打开的窗口，重新打开请求未被响应。请点击程序坞图标，或在 %1$@ 菜单中新建窗口。", L(kind.displayName))
        default:
            return LF("%@ 已激活，但窗口仍未出现在当前桌面，可能在其他桌面或全屏空间。请点击程序坞图标恢复窗口，或检查其他桌面。", L(kind.displayName))
        }
    }

    static func visibleWindowExists(pid: pid_t, windows: [[String: Any]]?) -> Bool {
        guard let windows else { return false }
        return windows.contains { isNormalWindow($0) && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
    }

    /// On-screen windows are listed front to back, so the first normal window is
    /// the one the user sees on top. Overlays such as the island are skipped.
    static func frontWindowBelongs(to pid: pid_t, windows: [[String: Any]]?) -> Bool {
        guard let front = windows?.first(where: isNormalWindow) else { return false }
        return (front[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
    }

    private static func isNormalWindow(_ window: [String: Any]) -> Bool {
        guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return false }
        return width >= 100 && height >= 100
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
