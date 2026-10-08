import Foundation
import LinglongtaiShared

@main
struct TaskVisualAcceptance {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ value: Bool) {
            precondition(value, name)
            count += 1
            print("PASS: \(name)")
        }
        func task(_ status: AgentTaskStatus, event: String? = nil) -> AgentTask {
            AgentTask(agent: "Codex", title: "fixture", status: status, detail: "fixture", model: "fixture",
                      source: .liveEvent, sourceEvent: event)
        }
        func state(_ status: AgentTaskStatus, label: String, event: String? = nil, attention: Bool = false) -> TaskVisualState {
            TaskVisualState.resolve(task(status, event: event), displayedStatus: label, needsAttention: attention)
        }
        check("fresh execution has its own dynamic state", state(.running, label: "处理中") == .executing)
        check("execution alone permits motion", TaskVisualState.executing.animates)
        check("reduced motion has a distinct static waveform fallback", TaskVisualState.executing.symbol == "waveform")
        check("queued is active but never animated", state(.queued, label: "排队中") == .queued && !TaskVisualState.queued.animates)
        check("real attention is separate from execution", state(.waiting, label: "等待确认", attention: true) == .attention)
        check("permission observation is not a user approval", state(.waiting, label: "权限检查中", event: "PermissionRequest") == .checkingPermission)
        check("submitted decision stays static while awaiting receipt", state(.waiting, label: "等待回执") == .awaitingReceipt)
        check("finished outcome has a static checkmark", state(.completed, label: "本轮已结束") == .completed && TaskVisualState.completed.symbol == "checkmark.circle")
        check("failure retains a distinct warning", state(.failed, label: "失败") == .failed)
        check("cancellation is not success", state(.cancelled, label: "本轮已中断") == .cancelled)
        for label in ["等待状态更新", "状态未知", "已停止跟踪 · 状态未知"] {
            check("unknown label \(label) cannot inherit running motion", state(.running, label: label) == .unknown)
        }
        for event in ["DoubaoSilent", "DoubaoAbandoned", "AmbiguousTurn", "ClaudeChatUnknown"] {
            check("unknown source \(event) remains unknown", state(.running, label: "处理中", event: event) == .unknown)
        }
        check("abandoned trajectory is not a terminal outcome", state(.cancelled, label: "已停止跟踪 · 状态未知", event: "DoubaoAbandoned") == .unknown)
        for event in ["SupersededTrajectory", "HookTrackingEnded"] {
            check("untracked source \(event) is separated", state(.running, label: "历史记录 · 不再跟踪", event: event) == .untracked)
        }
        check("unknown has question marker, never a progress glyph", TaskVisualState.unknown.symbol == "questionmark.circle" && !TaskVisualState.unknown.animates)
        check("untracked explanation does not claim completion", TaskVisualState.untracked.unknownExplanation?.contains("结果未知") == true)
        let original = task(.running, event: "ClaudeChatUnknown")
        _ = TaskVisualState.resolve(original, displayedStatus: "等待状态更新", needsAttention: false)
        check("visual mapping never mutates raw lifecycle", original.status == .running && original.sourceEvent == "ClaudeChatUnknown")
        let first = TaskVisualItem(task: task(.running), state: .executing)
        let second = TaskVisualItem(task: task(.running), state: .executing)
        let sections = TaskVisualSection.grouped([
            TaskVisualItem(task: task(.completed), state: .completed),
            TaskVisualItem(task: task(.running), state: .unknown),
            first, TaskVisualItem(task: task(.waiting), state: .attention), second
        ])
        check("display groups prioritize attention, active, unknown, ended", sections.map(\.group) == [.attention, .active, .unknown, .ended])
        check("same-group ordering is stable", sections.first { $0.group == .active }?.items.map(\.id) == [first.id, second.id])
        check("empty groups are omitted", TaskVisualSection.grouped([first]).map(\.group) == [.active])
        check("empty list creates no placeholder task", TaskVisualSection.grouped([]).isEmpty)
        check("all nonexecution states stay static", [TaskVisualState.attention, .queued, .checkingPermission, .awaitingReceipt, .unknown, .untracked, .completed, .failed, .cancelled].allSatisfy { !$0.animates })
        print("\(count) task visual hierarchy checks passed; display-only fixtures.")

        // Optional isolated visual data for the real bundled HUD. Never writes
        // the personal events journal or sends a provider request.
        if let index = CommandLine.arguments.firstIndex(of: "--fixture-root"), CommandLine.arguments.count > index + 1 {
            let root = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            guard root.path.hasPrefix("/private/tmp/island-task-visual.") else { fatalError("explicit isolated temp root required") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let date = Date()
            let fixtures: [(String, AgentTaskStatus, String, String)] = [
                ("Codex", .running, "PreToolUse", "验收预览 · 正在检查界面层级"),
                ("Claude", .completed, "Stop", "验收预览 · 本轮已经结束"),
                ("WorkBuddy", .running, "ClaudeChatUnknown", "验收预览 · 等待真实状态更新"),
                ("豆包", .running, "SupersededTrajectory", "验收预览 · 不再跟踪的历史记录"),
                ("Claude", .failed, "StopFailure", "验收预览 · 本轮响应失败"),
                ("WorkBuddy", .cancelled, "Interrupt", "验收预览 · 本轮已中断")
            ]
            var journal = Data()
            for (offset, fixture) in fixtures.enumerated() {
                let event = AgentEvent(type: "upsert", id: UUID(), agent: fixture.0, title: fixture.3, status: fixture.1,
                                       detail: "隔离视觉验收数据，非真实厂商任务", createdAt: date.addingTimeInterval(-Double(offset)), sourceEvent: fixture.2)
                journal.append(try JSONEncoder().encode(event)); journal.append(10)
            }
            let url = root.appendingPathComponent("events.jsonl")
            try journal.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            print("Isolated visual fixtures: \(url.path)")
        }
    }
}
