import LinglongtaiShared
import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject private var presence = AgentPresence.shared

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    behaviorSection
                    sizingSection
                    agentsSection
                    dataSection
                    footer
                }
                .padding(30)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                LinglongtaiBrandMark(size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent 灵动岛")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("你的 Agent 管家")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var behaviorSection: some View {
        SettingsCard(title: "出现方式") {
            Toggle(isOn: Binding(
                get: { store.autoPopOnEvent },
                set: { store.setAutoPopOnEvent($0) }
            )) {
                SettingLabel(
                    title: "任务变化时自动提示",
                    detail: "新任务、待确认或结束时展开 10 秒。"
                )
            }

            Divider()

            Toggle(isOn: Binding(
                get: { store.autoOpenApproval },
                set: { store.setAutoOpenApproval($0) }
            )) {
                SettingLabel(
                    title: "收到批准请求时直接打开批准窗",
                    detail: "默认关闭。开启后会占用键盘焦点，打字时可能被打断；仍需按 ⌘↩ 才会批准，弹出后 0.6 秒内的决定键会被忽略。"
                )
            }

            Divider()

            Toggle(isOn: Binding(
                get: { store.heavyOnHover },
                set: { store.setHeavyOnHover($0) }
            )) {
                SettingLabel(
                    title: "悬停查看详情",
                    detail: "悬停 0.2 秒展开，移开后收起。"
                    )
            }
        }
    }

    private var sizingSection: some View {
        SettingsCard(title: "尺寸", subtitle: "调整时在顶部预览 6 秒，空闲时贴合物理刘海。") {
            Toggle("自动按内容适配宽度", isOn: Binding(
                get: { store.automaticActivityWidth },
                set: { store.setAutomaticActivityWidth($0) }
            ))
            Text(store.automaticActivityWidth ? "自动适配中；拖动宽度滑块可切换为手动。" : "手动宽度；开启上方选项可恢复自动适配。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    SettingLabel(title: "提示宽度", detail: "调整两侧空间，小态同步收窄。")
                    Spacer()
                    Text("\(Int(store.activityWidth)) pt")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(get: { store.activityWidth }, set: { store.setActivityWidth($0) }),
                       in: 200...300, step: 2)
                    .tint(.white.opacity(0.72))
            }
            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    SettingLabel(
                        title: "高度微调",
                        detail: "只调整展开和活动状态。"
                    )
                    Spacer()
                    Text(offsetLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { store.notchOffset },
                    set: { store.setNotchOffset($0) }
                ), in: -12...24, step: 1)
                .tint(.white.opacity(0.72))
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    SettingLabel(
                        title: "宽度微调",
                        detail: "校准整体宽度，保留摄像头安全空间。"
                    )
                    Spacer()
                    Text(widthOffsetLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { store.notchWidthAdjustment },
                    set: { store.setNotchWidthAdjustment($0) }
                ), in: -56...96, step: 1)
                .tint(.white.opacity(0.72))
            }
            HStack(spacing: 10) {
                Button("预览小态") { store.previewCalibration(.compact) }
                Button("预览中态") { store.previewCalibration(.medium) }
                Spacer()
                Button("恢复自动尺寸") { store.resetCalibration() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var offsetLabel: String {
        let value = Int(store.notchOffset.rounded())
        if value == 0 { return "自动" }
        return value > 0 ? "+\(value) pt" : "\(value) pt"
    }

    private var widthOffsetLabel: String {
        let value = Int(store.notchWidthAdjustment.rounded())
        if value == 0 { return "自动" }
        return value > 0 ? "+\(value) pt" : "\(value) pt"
    }

    private var agentsSection: some View {
        SettingsCard(title: "Agent") {
            HStack {
                Text("查看任务状态，或管理应用接入。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("管理接入…") {
                    NSApp.sendAction(Selector(("showIntegrationSetup")), to: nil, from: nil)
                }.buttonStyle(.bordered)
            }
            VStack(spacing: 10) {
                ForEach(AgentCatalog.supportedKinds, id: \.self) { kind in
                    HStack(spacing: 12) {
                        AgentIcon(kind: kind, size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.displayName)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                            Text(presence.label(for: kind) + " · " + store.statusSummary(for: kind))
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary)
                            if kind == .doubao {
                                Text("仅支持 Agent 模式")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer()
                        Button("打开") { presence.open(kind) }
                            .buttonStyle(.bordered)
                            .disabled(!presence.canOpen(kind) || presence.opening.contains(kind))
                            .help("打开 \(kind.displayName)")
                            .accessibilityLabel("打开 \(kind.displayName)")
                            .fixedSize()
                    }
                    if let error = presence.launchErrors[kind] {
                        Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if kind != AgentCatalog.supportedKinds.last {
                        Divider()
                    }
                }
            }
        }
    }

    private var dataSection: some View {
        SettingsCard(title: "本地记录", subtitle: "记录只保存在这台 Mac 上。") {
            HStack {
                Text("清空显示不会停止任务或删除原应用会话。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("清空显示…") {
                    let confirmation = NSAlert()
                    confirmation.messageText = "清空本地任务显示？"
                    confirmation.informativeText = "不会停止 Agent，也不会删除原应用会话。清理后今日统计会随保留记录减少。"
                    confirmation.addButton(withTitle: "取消")
                    confirmation.addButton(withTitle: "清空显示")
                    if confirmation.runModal() == .alertSecondButtonReturn { store.clearAllTasks() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var footer: some View {
        Text("Agent 灵动岛 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · \(Bundle.main.object(forInfoDictionaryKey: "IslandSourceRevision") as? String ?? "未打包")")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(18)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
    }
}

private struct SettingLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
