import AppKit
import CoreGraphics
import CoreServices
import LinglongtaiShared

/// Pure fixtures: never opens an app or reads personal windows.
@main
struct AgentOpenAcceptance {
    @MainActor
    static func main() {
        var count = 0
        func check(_ title: String, _ passes: Bool) {
            precondition(passes, title)
            count += 1
            print("PASS: \(title)")
        }
        let active = AgentPresence.openConfiguration(bundleID: "com.anthropic.claudefordesktop", isRunning: true)
        check("running app explicitly receives reopen", active.appleEvent?.eventID == AEEventID(kAEReopenApplication))
        check("reopen uses core event class", active.appleEvent?.eventClass == AEEventClass(kCoreEventClass))
        check("opening requests foreground, not a hidden duplicate", active.activates && !active.hides && !active.createsNewApplicationInstance)
        check("no recent-item mutation", !active.addsToRecentItems)
        check("cold launch retains default launch event", AgentPresence.openConfiguration(bundleID: "fixture", isRunning: false).appleEvent == nil)
        check("unmapped app receives no targeted event", AgentPresence.openConfiguration(bundleID: nil, isRunning: true).appleEvent == nil)

        func window(pid: Int = 42, layer: Int = 0, alpha: Double = 1, width: Double = 600, height: Double = 500) -> [String: Any] {
            [kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowAlpha as String: NSNumber(value: alpha),
             kCGWindowBounds as String: ["Width": NSNumber(value: width), "Height": NSNumber(value: height)]]
        }
        check("matching normal window is detected", AgentPresence.visibleWindowExists(pid: 42, windows: [window()]))
        check("empty desktop is not window success", !AgentPresence.visibleWindowExists(pid: 42, windows: []))
        check("unavailable metadata is not window success", !AgentPresence.visibleWindowExists(pid: 42, windows: nil))
        check("other app window does not count", !AgentPresence.visibleWindowExists(pid: 42, windows: [window(pid: 7)]))
        check("menu or floating overlay does not count", !AgentPresence.visibleWindowExists(pid: 42, windows: [window(layer: 25)]))
        check("transparent window does not count", !AgentPresence.visibleWindowExists(pid: 42, windows: [window(alpha: 0)]))
        check("tiny helper window does not count", !AgentPresence.visibleWindowExists(pid: 42, windows: [window(width: 1, height: 1)]))
        check("malformed metadata does not count", !AgentPresence.visibleWindowExists(pid: 42, windows: [[:]]))
        check("one real window among overlays counts", AgentPresence.visibleWindowExists(pid: 42, windows: [window(layer: 25), window()]))
        check("missing permission is explained without claiming window recovery", AgentPresence.windowUnavailableMessage(kind: .claude, restoration: .permissionRequired).contains("尚无辅助功能权限"))
        check("attempted restoration is not claimed as success", AgentPresence.windowUnavailableMessage(kind: .claude, restoration: .attempted).contains("窗口仍未出现"))
        check("unreadable window keeps recovery guidance", AgentPresence.windowUnavailableMessage(kind: .claude, restoration: .unavailable).contains("程序坞"))
        check("closed window explains the missing window, not permission", AgentPresence.windowUnavailableMessage(kind: .claude, restoration: .noWindow).contains("没有打开的窗口"))
        check("denied reopen points at Automation settings", AgentPresence.windowUnavailableMessage(kind: .claude, restoration: .automationDenied).contains("自动化"))
        print("\(count) open-app checks passed; no provider or GUI action.")
    }
}
