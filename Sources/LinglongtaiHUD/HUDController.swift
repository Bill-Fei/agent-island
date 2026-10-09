import AppKit
import Combine
import LinglongtaiShared
import SwiftUI

@MainActor
final class HUDController: NSObject {
    let store = TaskStore.shared
    private let surface = IslandSurface()
    private var panel: HUDPanel!
    private var hostingView: NSHostingView<HUDRootView>!
    private var cancellables = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var frameTimer: Timer?
    private var lastFrameTime = ProcessInfo.processInfo.systemUptime
    private var lastHeartbeatTime = -Double.infinity
    private var hiding = false
    private var detailsOpenedFromMenu = false
    private var contextMenuMonitor: Any?

    override init() {
        super.init()
        configurePanel()
        configureContextMenu()
        observeState()
        // Sample the existing spring at 120 Hz for smoother high-refresh
        // display motion. Task history caching and background polling remain
        // independent; this does not change spring timing or rebound.
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    func show() {
        hiding = false
        detailsOpenedFromMenu = false
        store.resetInteraction()
        positionOnNotchedScreen()
        surface.setTarget(store.presentation)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        syncApprovalAvailability()
    }

    func toggle() {
        if panel.isVisible && !hiding {
            hiding = true
            store.resetInteraction()
            surface.setTarget(.collapsed)
            syncApprovalAvailability()
        } else {
            show()
        }
    }

    func showDetails() {
        if !panel.isVisible || hiding { show() }
        detailsOpenedFromMenu = true
        store.showTaskDetails()
        panel.makeKeyAndOrderFront(nil)
    }

    private func configurePanel() {
        panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: IslandLayout.canvasSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = "Agent 灵动岛 · 任务"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true

        hostingView = NSHostingView(rootView: HUDRootView(store: store, surface: surface))
        // A fixed transparent canvas prevents AppKit intrinsic sizing from
        // fighting SwiftUI. Only the black contour and its clip animate.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: IslandLayout.canvasSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionOnNotchedScreen() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastFrameTime = ProcessInfo.processInfo.systemUptime
                self.store.resetInteraction()
                self.positionOnNotchedScreen()
            }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.resetInteraction() }
        }
    }

    private func observeState() {
        store.$autoPopOnEvent.removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            ApprovalRelay.updateHUDHeartbeat(canPresent: enabled && self.panel.isVisible && !self.hiding)
        }.store(in: &cancellables)
        store.$presentation.removeDuplicates()
            .sink { [weak self] presentation in
                guard let self, !self.hiding else { return }
                self.surface.setTarget(presentation)
            }
            .store(in: &cancellables)
        store.$notchOffset.removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.positionOnNotchedScreen() }
            .store(in: &cancellables)
        store.$notchWidthAdjustment.removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.positionOnNotchedScreen() }
            .store(in: &cancellables)
        store.$activityWidth.removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.positionOnNotchedScreen() }
            .store(in: &cancellables)
        store.$mediumWingWidth.removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.positionOnNotchedScreen() }
            .store(in: &cancellables)
    }

    private func configureContextMenu() {
        // A local monitor covers SwiftUI buttons and blank areas alike, without
        // placing a transparent view over (and stealing) normal left clicks.
        contextMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  self.store.presentation == .heavy, self.surface.frame.heavyOpacity >= 0.95 else { return event }
            let location = event.locationInWindow
            let point = CGPoint(x: location.x, y: self.panel.frame.height - location.y)
            guard self.surface.contains(point), self.store.beginContextMenu() else { return event }
            self.detailsOpenedFromMenu = false
            defer {
                let mouse = NSEvent.mouseLocation
                let point = CGPoint(x: mouse.x - self.panel.frame.minX, y: self.panel.frame.maxY - mouse.y)
                self.store.endContextMenu(pointerInside: self.surface.contains(point))
            }
            let menu = NSMenu(title: "灵动岛")
            let settings = NSMenuItem(title: "设置…", action: #selector(self.openSettings), keyEquivalent: "")
            settings.target = self
            menu.addItem(settings)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出灵动岛", action: #selector(self.exitIsland), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
            NSMenu.popUpContextMenu(menu, with: event, for: self.hostingView)
            return nil
        }
    }

    @objc private func openSettings() { IslandAppActions.showSettings() }
    @objc private func exitIsland() { IslandAppActions.quit() }

    private func positionOnNotchedScreen() {
        // A change of frontmost app must NOT move the island to another display.
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let layout = IslandLayout(
            screen: screen,
            heightAdjustment: store.notchOffset,
            widthAdjustment: store.notchWidthAdjustment,
            activityWidth: store.activityWidth,
            mediumWingWidth: store.mediumWingWidth
        )
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let center = layout.hasPhysicalNotch ? (left.maxX + right.minX) / 2 : screen.frame.midX
        let size = IslandLayout.canvasSize
        panel.setFrame(NSRect(x: center - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        surface.configure(layout, presentation: hiding ? .collapsed : store.presentation)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(0.05, now - lastFrameTime)
        lastFrameTime = now
        if now - lastHeartbeatTime >= 0.8 {
            syncApprovalAvailability()
            lastHeartbeatTime = now
        }
        guard panel.isVisible else { return }

        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let inside = surface.contains(point)
        // The rest of the fixed canvas is transparent AND click-through.
        panel.ignoresMouseEvents = (!inside && !store.contextMenuIsOpen) || hiding
        // Keyboard/menu opening must survive while the pointer is still at the
        // menu bar. Once it enters the island, normal hover/leave takes over.
        if store.presentation != .heavy || inside { detailsOpenedFromMenu = false }
        if !hiding && !detailsOpenedFromMenu { store.samplePointer(inside: inside, at: now) }
        surface.advance(by: delta, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        if hiding && surface.isSettled {
            panel.orderOut(nil)
            hiding = false
        }
    }

    private func syncApprovalAvailability() {
        ApprovalRelay.updateHUDHeartbeat(canPresent: panel.isVisible && !hiding && store.autoPopOnEvent)
    }

    deinit {
        frameTimer?.invalidate()
        if let contextMenuMonitor { NSEvent.removeMonitor(contextMenuMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }
}

@MainActor
private enum IslandAppActions {
    static func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    static func quit() { NSApp.terminate(nil) }
}

@MainActor
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hudController: HUDController?
    private var statusItem: NSStatusItem?
    private var onboarding: AlphaOnboardingController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            TaskStoreAcceptance.run()
            NSApp.terminate(nil)
            return
        }
        hudController = HUDController()
        hudController?.show()
        configureStatusItem()
        let args = ProcessInfo.processInfo.arguments
        if !args.contains("--qa-empty") && !args.contains("--qa-demo") && !args.contains("--data-dir") {
            onboarding = AlphaOnboardingController(store: TaskStore.shared)
            if !UserDefaults.standard.bool(forKey: "alpha.hasSeenSetup") {
                onboarding?.show()
                UserDefaults.standard.set(true, forKey: "alpha.hasSeenSetup")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let appIcon = NSApp.applicationIconImage?.copy() as? NSImage {
            // The AppIcon has a transparent safety margin around the mark;
            // 24pt gives it the same visual weight as neighboring menu-bar apps.
            appIcon.size = NSSize(width: 24, height: 24)
            appIcon.isTemplate = false
            appIcon.accessibilityDescription = "Agent 灵动岛"
            item.button?.image = appIcon
        } else {
            item.button?.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Agent 灵动岛")
        }
        item.button?.toolTip = "Agent 灵动岛 · 你的 Agent 管家"

        let menu = NSMenu()
        let setup = NSMenuItem(title: "接入与验证…", action: #selector(showIntegrationSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        let details = NSMenuItem(title: "查看任务", action: #selector(showTasks), keyEquivalent: "")
        details.target = self
        menu.addItem(details)
        let toggle = NSMenuItem(title: "显示 / 隐藏 Agent 灵动岛", action: #selector(toggleHUD), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let settings = NSMenuItem(title: "Agent 灵动岛设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Agent 灵动岛", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleHUD() {
        hudController?.toggle()
    }

    @objc private func showTasks() {
        hudController?.showDetails()
    }

    @objc private func showSettings() {
        IslandAppActions.showSettings()
    }

    @objc private func showIntegrationSetup() {
        if onboarding == nil { onboarding = AlphaOnboardingController(store: TaskStore.shared) }
        onboarding?.show()
    }

    @objc private func quitApp() {
        IslandAppActions.quit()
    }
}
