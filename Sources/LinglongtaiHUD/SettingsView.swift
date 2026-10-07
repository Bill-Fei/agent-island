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
                    doubaoSection
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
            Text("新任务出现时展开提示，10 秒后收成小态；连续悬停 0.2 秒查看详情，没有任务时融回物理刘海。")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var behaviorSection: some View {
        SettingsCard(title: "出现方式", subtitle: "控制灵动岛主动靠近你的距离") {
            Toggle(isOn: Binding(
                get: { store.autoPopOnEvent },
                set: { store.setAutoPopOnEvent($0) }
            )) {
                SettingLabel(
                    title: "有事件时自动弹出",
                    detail: "新任务、待确认或结束时显示中态 10 秒。进行中任务随后保持小态；最后真实活动超过 24 小时后隐藏。"
                )
            }

            Divider()

            Toggle(isOn: Binding(
                get: { store.heavyOnHover },
                set: { store.setHeavyOnHover($0) }
            )) {
                SettingLabel(
                    title: "悬停展开完整详情",
                    detail: "连续悬停 0.2 秒展开，提前移开立即取消计时。主动事件提示不受影响。"
                    )
            }
            Text("悬停列表保留最近 24 小时的会话记录，进行中优先，已完成仍可查看。超过 24 小时无真实活动的记录隐藏，不代表完成；新活动到达后会重新出现。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var sizingSection: some View {
        SettingsCard(title: "刘海与活动提示尺寸", subtitle: "拖动滑块会在顶部预览 6 秒，预览不会创建任务") {
            Toggle("自动按内容适配宽度", isOn: Binding(
                get: { store.automaticActivityWidth },
                set: { store.setAutomaticActivityWidth($0) }
            ))
            Text(store.automaticActivityWidth ? "当前：自动适配。拖动下方宽度会切换到手动，长文字可滚动显示。" : "当前：手动宽度。小态按比例收窄，中态使用滑块值。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    SettingLabel(title: "活动提示宽度", detail: "控制中态左右两翼；小态按比例收窄。较长名称和状态会缓慢往返滚动；减少动态效果时静态适配。")
                    Spacer()
                    Text("两翼预算 \(Int(store.activityWidth)) pt")
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
                        title: "活动状态高度微调",
                        detail: "调整小态、中态高度及详情顶部留白。空闲态始终回到物理刘海，不会多出一截。"
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
                        title: "刘海基准宽度微调",
                        detail: "校准活动状态总宽度，保留摄像头避让区和图标最小空间；空闲态跟随真实刘海。"
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
            Text("空闲：物理刘海 · 小态：持续任务 · 中态：重要变化 10 秒 · 悬停：完整详情")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(effectiveSizeSummary)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text("负向宽度校准若已到摄像头安全下限，不会再缩窄中央；高度只调整活动态，详情顶部不会侵入物理刘海。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var effectiveSizeSummary: String {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return "等待屏幕尺寸" }
        let layout = IslandLayout(screen: screen, heightAdjustment: store.notchOffset,
                                 widthAdjustment: store.notchWidthAdjustment, activityWidth: store.activityWidth,
                                 mediumWingWidth: store.automaticActivityWidth ? store.mediumWingWidth : nil)
        let compact = layout.size(for: .compact), medium = layout.size(for: .medium)
        return "实际 小态 \(Int(compact.width))×\(Int(compact.height)) · 中态 \(Int(medium.width))×\(Int(medium.height)) pt"
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
        SettingsCard(title: "Agent", subtitle: "Codex、Claude Code、WorkBuddy 走 Hook 事件；豆包读取本地 Agent 模式轨迹") {
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
                        }
                        Spacer()
                        Text(store.connectionLabel(for: kind))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(store.latestLiveTask(for: kind) == nil ? Color.secondary : Color.mint)
                    }
                    if kind != AgentCatalog.supportedKinds.last {
                        Divider()
                    }
                }
            }
            Text("Codex / Claude Code / WorkBuddy 仅观察真实 Hook；权限检查不等于需要你确认。明确待确认时请打开原应用处理，当前版本不在岛上批准、停止或重试。Claude 接入指 Claude Code，不覆盖普通 Claude Chat；打开应用也不保证定位到原会话。豆包只读 Agent 轨迹，普通聊天不可见；长时间无更新显示未知或停止跟踪，不代表完成或中断。收到过回调不等于连接持续健康。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var dataSection: some View {
        SettingsCard(title: "本地任务数据", subtitle: "事件与任务只保存在这台 Mac 上") {
            HStack(spacing: 10) {
                Button(store.demoPreviewActive ? "退出演示预览" : "预览演示（非真实状态）") {
                    if store.demoPreviewActive { store.endDemoPreview() }
                    else { store.loadDemoTasks() }
                }
                .buttonStyle(.borderedProminent)

                Button("清空任务") {
                    let confirmation = NSAlert()
                    confirmation.messageText = "清空本地任务显示？"
                    confirmation.informativeText = "不会停止 Agent，也不会删除原应用会话。清理后今日统计会随保留记录减少。"
                    confirmation.addButton(withTitle: "取消")
                    confirmation.addButton(withTitle: "清空显示")
                    if confirmation.runModal() == .alertSecondButtonReturn { store.clearAllTasks() }
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            Text("事件文件：~/Library/Application Support/LinglongtaiHUD/events.jsonl")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("当前提示：" + store.notice)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("24 小时仅是显示窗口，不自动删除日志。统计为保留记录中今日有活动的轮次，非 API 调用次数；清理显示后统计会减少。事件按批增量读取，保留原日志用于恢复。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var doubaoSection: some View {
        SettingsCard(title: "豆包接入状态", subtitle: "只读本地 Agent 模式轨迹，看不到普通聊天") {
            HStack {
                AgentIcon(kind: .doubao, size: 32)
                Text(presence.label(for: .doubao))
                Spacer()
                Button("打开豆包") { presence.open(.doubao) }.disabled(!presence.canOpen(.doubao))
            }
            Text("已接入：豆包桌面端会把 Agent 模式的每一步写在本地，岛上直接读这个文件推导“运行中 / 本轮已结束 / 状态未知”。审批回传仍未接入——豆包没有可回写的接口，需要你确认的操作只能回豆包里点。普通聊天全程在云端，本地不留痕迹，因此无法接入。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("豆包官网", destination: URL(string: "https://www.doubao.com/")!)
                Link("火山引擎模型平台", destination: URL(string: "https://www.volcengine.com/product/ark")!)
            }.font(.system(size: 11))
            Text("只读取角色与工具类别，不读对话内容，不索取 API Key，也不会用模拟任务填充这里。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
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
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
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
