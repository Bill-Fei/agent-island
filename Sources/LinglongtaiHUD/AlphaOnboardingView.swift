import AppKit
import LinglongtaiShared
import SwiftUI

struct AlphaOnboardingView: View {
    @ObservedObject var store: TaskStore
    @StateObject private var setup = AlphaIntegrationSetup()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    LinglongtaiBrandMark(size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("让 Agent 状态，在这里汇合").font(.title2.bold())
                        Text("Alpha · 本地状态层，不是任务调度器").foregroundStyle(.secondary)
                    }
                }
                Text("忙时收成小态，需要你时轻轻展开。当前只观察状态；批准、停止和回复仍在原应用完成。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                selectionSection
                verificationSection
                GroupBox("3 · 看清隐私与能力边界") {
                    Text("Hook 仅保留状态元数据，不保存输入和工具内容。为区分任务，会只读 Codex / WorkBuddy 的会话标题；标题可能包含敏感信息。最近 24 小时是显示窗口，不是自动删除期限。退出不会卸载 Hook，卸载不会删除历史。没有联网分析或云端同步；不要把原始日志和真实标题截图提交到 GitHub。")
                        .font(.callout).foregroundStyle(.secondary).padding(10)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(28)
        }
        .frame(minWidth: 650, minHeight: 600)
        .onAppear { setup.refresh() }
    }

    private var selectionSection: some View {
        GroupBox("1 · 选择接入，知情安装") {
            VStack(alignment: .leading, spacing: 14) {
                Text("无需 API Key 或 Python。仅合并所选本地 Hook 配置，保留其他设置，并生成备份。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(IntegrationConfiguration.providers, id: \.self) { kind in
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { setup.selected.contains(kind) }, set: { value in
                            if value { setup.selected.insert(kind) } else { setup.selected.remove(kind) }
                        })) {
                            Text(kind == .claude ? L("Claude Code（不是 Claude Chat）") : L(kind.displayName))
                        }
                        Spacer()
                        Text(L(setup.diagnostics[kind] ?? "正在检查接入"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("查看并安装所选接入") { setup.confirm(uninstall: false) }
                        .buttonStyle(.borderedProminent).disabled(setup.selected.isEmpty || setup.busy)
                    Button("重新检查") { setup.refresh() }.disabled(setup.busy)
                    Spacer()
                    Button("移除所选接入") { setup.confirm(uninstall: true) }
                        .disabled(setup.selected.isEmpty || setup.busy)
                }
                Text(L(setup.message)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.padding(10)
        }
    }

    private var verificationSection: some View {
        GroupBox("2 · 用真实任务验证") {
            VStack(alignment: .leading, spacing: 12) {
                Text("在所选应用发起一轮你自己的任务。安装成功、收到过回调、任务正在运行，是三件不同的事。这里不会替你发请求或填充模拟状态。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(IntegrationConfiguration.providers, id: \.self) { kind in
                    HStack {
                        Text(kind == .claude ? "Claude Code" : L(kind.displayName))
                        Spacer()
                        if let date = store.connections[kind.rawValue] {
                            Text("最近收到 ").foregroundStyle(.secondary)
                            Text(date, style: .date).monospacedDigit()
                            Text(date, style: .time).monospacedDigit()
                        } else { Text("尚未收到真实回调").foregroundStyle(.secondary) }
                    }.font(.callout)
                    if store.tasks.contains(where: { $0.profile.kind == kind && $0.sourceEvent == "AmbiguousTurn" && [.running, .waiting].contains($0.status) }) {
                        Text("\(L(kind.displayName))：收到回调，但轮次无法识别；不视为正常执行。请在下一轮请求后核实。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Text("升级时仅维护已接入的观察器；被移除的接入不会自动恢复。未收到回调不等于断连或任务结束，可能正在长时间执行。配置异常请检查，Codex 的信任仍需在 /hooks 审阅；第三方协议变更不能保证自动兼容。豆包仅观察本地 Agent 轨迹，普通聊天不可见。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
    }
}

@MainActor
final class AlphaOnboardingController {
    private var window: NSWindow?
    private let store: TaskStore
    init(store: TaskStore) { self.store = store }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L("Agent 灵动岛 · 接入与验证")
            window.contentView = NSHostingView(rootView: AlphaOnboardingView(store: store))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
