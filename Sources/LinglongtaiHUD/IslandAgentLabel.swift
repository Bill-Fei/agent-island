import AppKit
import LinglongtaiShared
import SwiftUI

final class IslandMotionClock: ObservableObject {
    @Published var startedAt = Date()
    @Published var frozenElapsed: TimeInterval = 0
    @Published var running = false

    func setRunning(_ enabled: Bool) {
        guard enabled != running else { return }
        if enabled { startedAt = Date().addingTimeInterval(-frozenElapsed) }
        else { frozenElapsed = Date().timeIntervalSince(startedAt) }
        running = enabled
    }
    func reset() { startedAt = Date(); frozenElapsed = 0 }
}

struct IslandAgentLabel: View {
    let text: String
    let width: CGFloat
    let active: Bool
    var isStatus = false
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var clock = IslandMotionClock()
    private var textWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: isStatus ? 12 : 13,
                                                                              weight: isStatus ? .medium : .bold)]).width) + 1
    }

    var body: some View {
        Group {
            if !reduceMotion && textWidth > width + 0.5 {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !clock.running)) { context in
                    label.offset(x: IslandLabelMotion.offset(elapsed: clock.running ? context.date.timeIntervalSince(clock.startedAt) : clock.frozenElapsed,
                                                             textWidth: textWidth, viewportWidth: width))
                }
            } else {
                label.scaleEffect(reduceMotion ? min(1, max(0, width) / textWidth) : 1, anchor: .leading)
            }
        }
        .frame(width: max(0, width), height: 18, alignment: isStatus && textWidth <= width ? .trailing : .leading)
        .clipped()
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onAppear { clock.setRunning(active && !reduceMotion) }
        .onChange(of: active) { clock.setRunning($0 && !reduceMotion) }
        .onChange(of: text) { _ in clock.reset() }
        .onChange(of: width) { _ in clock.reset() }
        .onChange(of: reduceMotion) { clock.setRunning(active && !$0) }
    }

    private var label: some View {
        Text(text).font(.system(size: isStatus ? 12 : 13, weight: isStatus ? .medium : .bold))
            .foregroundStyle(tint).lineLimit(1).fixedSize(horizontal: true, vertical: true)
            .frame(width: textWidth, height: 18, alignment: .leading)
    }
}
