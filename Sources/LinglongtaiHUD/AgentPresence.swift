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
        Self.trace("click \(kind.rawValue) running=\(running.contains(kind)) ax=\(AXIsProcessTrusted())")
        let configuration = Self.openConfiguration(bundleID: Self.bundleIDs[kind], isRunning: running.contains(kind))
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                Self.trace("openApplication error=\(error.map { String(describing: $0) } ?? "nil") app=\(app?.processIdentifier ?? -1)")
                if error != nil || app == nil {
                    self.launchErrors[kind] = "未能打开 \(kind.displayName)，请重试或从访达打开。"
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
                if Self.isFrontmost(pid: pid) && Self.frontWindowIsOwn(pid: pid) { Self.trace("reached top=\(Self.frontWindowsSummary())"); return true }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            Self.trace("not reached front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") visible=\(Self.hasVisibleWindow(pid: pid)) onTop=\(Self.frontWindowIsOwn(pid: pid))")
            return false
        }
        // 1. Bring the app forward (switches to the desktop holding its window).
        bringForward(app)
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
        Self.trace("give up restoration=\(restoration)")
        if app.isTerminated {
            launchErrors[kind] = "\(kind.displayName) 在打开窗口时已退出，请重新打开。"
        } else if Self.hasVisibleWindow(pid: pid) && !Self.isFrontmost(pid: pid) {
            launchErrors[kind] = "\(kind.displayName) 的窗口已打开，但系统未允许切到前台，请点击程序坞图标。"
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
            let islandActive = NSApp.isActive
            NSApp.yieldActivation(to: app)
            let handed = app.activate(from: .current, options: [.activateAllWindows])
            Self.trace("bringForward islandActive=\(islandActive) handed=\(handed)")
        } else {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        Self.trace("axFrontmost=\(Self.bringFrontmost(pid: app.processIdentifier)) raised=\(Self.raiseMainWindow(pid: app.processIdentifier))")
    }

    /// Temporary open-app diagnostics: only app IDs, flags and step results,
    /// never window titles or content. Remove once opening is verified.
    nonisolated private static func trace(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LinglongtaiHUD/open-trace.log")
        let entry = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
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

    /// Diagnostics only: owner app name, layer, alpha and size of the first
    /// on-screen windows. Window titles are never requested.
    private static func frontWindowsSummary() -> String {
        (onScreenWindows() ?? []).prefix(5).map { window in
            let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? -1
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let w = (bounds?["Width"] as? NSNumber)?.intValue ?? 0, h = (bounds?["Height"] as? NSNumber)?.intValue ?? 0
            return "\(owner)/L\(layer)/a\(alpha)/\(w)x\(h)"
        }.joined(separator: ", ")
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
        var seen: [String] = []
        for window in candidates {
            AXUIElementSetMessagingTimeout(window, 0.2)
            var subrole: CFTypeRef?
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            seen.append((subrole as? String ?? "nil") + ((minimized as? Bool) == true ? "/min" : ""))
            if (minimized as? Bool) == true { continue }
            if subrole as? String == kAXStandardWindowSubrole {
                trace("ax windows=\(seen) raise=standard")
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFBoolean)
                return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
            }
            if fallback == nil { fallback = window }
        }
        trace("ax windows=\(seen) raise=\(fallback == nil ? "none" : "fallback")")
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
            return "\(kind.displayName) 已激活，但窗口未出现。灵动岛尚无辅助功能权限，无法恢复最小化窗口：请在系统设置 → 隐私与安全性 → 辅助功能中打开「Agent 灵动岛」后再点一次；若已打开仍无效，先用 − 删除该项再重试。"
        }
        switch restoration {
        case .noWindow:
            return "\(kind.displayName) 在运行，但没有打开的窗口，重新打开请求未被响应。请点击程序坞图标，或在 \(kind.displayName) 菜单中新建窗口。"
        default:
            return "\(kind.displayName) 已激活，但窗口仍未出现在当前桌面，可能在其他桌面或全屏空间。请点击程序坞图标恢复窗口，或检查其他桌面。"
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
