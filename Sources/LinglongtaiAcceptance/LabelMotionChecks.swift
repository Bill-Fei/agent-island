import AppKit
import LinglongtaiShared

func runLabelMotionChecks(check: (String, Bool) -> Void) {
    let font = NSFont.systemFont(ofSize: 13, weight: .bold)
    for name in ["Codex", "Claude", "WorkBuddy", "豆包"] {
        let measured = ceil((name as NSString).size(withAttributes: [.font: font]).width) + 1
        for width in [200.0, 228, 300] {
            let metrics = IslandMetrics(activityWidth: width)
            let wings = IslandWingLayout(surfaceWidth: metrics.size(for: .medium).width,
                                         centerExclusionWidth: metrics.centerExclusionWidth, shoulderInset: 8)
            let viewport = wings.wingWidth - 24 - 6
            let distance = IslandLabelMotion.overflow(textWidth: measured, viewportWidth: viewport)
            var values: [Double] = []
            for frame in 0...1200 {
                values.append(IslandLabelMotion.offset(elapsed: Double(frame) / 60,
                                                       textWidth: measured, viewportWidth: viewport))
            }
            check("label \(name)/\(width): both ends are readable without escaping the viewport",
                  values.allSatisfy { $0 <= 0 && $0 >= -distance } && values.max() == 0 &&
                  abs((values.min() ?? 0) + distance) < 0.01)
            check("label \(name)/\(width): no wrap jump and no motion for fitting names",
                  zip(values, values.dropFirst()).allSatisfy { abs($0 - $1) < 1 } &&
                  (distance > 0.5 || values.allSatisfy { $0 == 0 }))
        }
    }
    check("label starts with a reading pause and safely handles no viewport",
          IslandLabelMotion.offset(elapsed: 0.79, textWidth: 90, viewportWidth: 40) == 0 &&
          IslandLabelMotion.offset(elapsed: 3, textWidth: 90, viewportWidth: 0) == 0)

    let statusFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    for title in ["执行工具", "等待状态更新", "1项结束 · 12项进行", "正在处理较长的任务状态描述"] {
        let measured = ceil((title as NSString).size(withAttributes: [.font: statusFont]).width) + 1
        for width in [200.0, 228, 300] {
            let metrics = IslandMetrics(activityWidth: width)
            let viewport = IslandWingLayout(surfaceWidth: metrics.size(for: .medium).width,
                                            centerExclusionWidth: metrics.centerExclusionWidth, shoulderInset: 8).wingWidth
            let distance = IslandLabelMotion.overflow(textWidth: measured, viewportWidth: viewport)
            let values = (0...2400).map {
                IslandLabelMotion.offset(elapsed: Double($0) / 60, textWidth: measured, viewportWidth: viewport)
            }
            check("status \(title)/\(width): full text is reachable inside the fixed right wing",
                  values.allSatisfy { $0 <= 0 && $0 >= -distance } &&
                  abs((values.min() ?? 0) + distance) < 0.01 && values.max() == 0)
            check("status \(title)/\(width): no loop jump or unnecessary scrolling",
                  zip(values, values.dropFirst()).allSatisfy { abs($0 - $1) < 1 } &&
                  (distance > 0.5 || values.allSatisfy { $0 == 0 }))
        }
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var task = AgentTask(agent: "Codex", title: "activity gate", status: .running,
                         detail: "", model: "", updatedAt: now, source: .liveEvent)
    for status in AgentTaskStatus.allCases {
        task.status = status
        check("activity only animates running, not \(status.rawValue)",
              AgentActivityMotion.isExecuting(task, now: now) == (status == .running))
    }
    task.status = .running
    for source in AgentTaskSource.allCases {
        task.source = source
        check("activity requires live source: \(source.rawValue)",
              AgentActivityMotion.isExecuting(task, now: now) == source.isLive)
    }
    task.source = .liveEvent
    for age in [-6.0, -5, 0, 120, 120.01, 600] {
        task.updatedAt = now.addingTimeInterval(-age)
        check("activity freshness boundary \(age)",
              AgentActivityMotion.isExecuting(task, now: now) == (age >= -5 && age <= 120))
    }
    task.updatedAt = now
    task.sourceEvent = "AmbiguousTurn"
    check("ambiguous activity is static", !AgentActivityMotion.isExecuting(task, now: now))
    task.sourceEvent = nil
    task.requiresApproval = true
    check("pending approval never breathes", !AgentActivityMotion.isExecuting(task, now: now))
    check("absent task is static", !AgentActivityMotion.isExecuting(nil, now: now))
    let breaths = (0...1440).map { AgentActivityMotion.breath(elapsed: Double($0) / 60) }
    check("breath stays bounded, subtle and continuous", breaths.allSatisfy { $0 >= 0 && $0 <= 1 } &&
          zip(breaths, breaths.dropFirst()).allSatisfy { abs($0 - $1) < 0.025 })
    check("breath completes its cycle without a jump", AgentActivityMotion.breath(elapsed: 0) == 0 &&
          abs(AgentActivityMotion.breath(elapsed: 2.4)) < 0.00001 &&
          abs(AgentActivityMotion.breath(elapsed: 1.2) - 1) < 0.00001)
    let barSamples = (0..<3).flatMap { index in
        (0...240).map { AgentActivityMotion.barScale(elapsed: Double($0) / 60, index: index) }
    }
    check("compact running glyph stays bounded and indeterminate", barSamples.allSatisfy { $0 >= 0.38 && $0 <= 1 })
    check("compact running glyph has continuous staggered motion", (0..<3).allSatisfy { index in
        let samples = (0...240).map { AgentActivityMotion.barScale(elapsed: Double($0) / 60, index: index) }
        return samples.contains(where: { $0 > 0.95 }) && samples.contains(where: { $0 < 0.45 }) &&
            zip(samples, samples.dropFirst()).allSatisfy { abs($0 - $1) < 0.08 }
    })
}
