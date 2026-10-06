import SwiftUI

@main
struct LinglongtaiHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            AppSettingsView(store: TaskStore.shared)
        }
        .defaultSize(width: 720, height: 620)
        .commands {
            CommandMenu("灵动岛") {
                Button("查看任务") {
                    NSApp.sendAction(Selector(("showTasks")), to: nil, from: nil)
                }
            }
        }
    }
}
