import Foundation
import LinglongtaiShared

/// Display-only hierarchy. The store remains the authority for lifecycle,
/// freshness and approval; no task is completed or resumed by this mapping.
enum TaskVisualGroup: Int, CaseIterable, Identifiable {
    case active, ended

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .active: return "进行中"
        case .ended: return "已结束"
        }
    }
}

enum TaskVisualState: Hashable {
    case attention, executing, queued, checkingPermission, awaitingReceipt
    case unknown, untracked, completed, failed, cancelled

    static func resolve(_ task: AgentTask, displayedStatus: String, needsAttention: Bool) -> Self {
        // Unknown trajectory endings are NOT evidence of a completed task.
        if ["SupersededTrajectory", "HookTrackingEnded"].contains(task.sourceEvent ?? "") ||
            displayedStatus == "历史记录 · 不再跟踪" { return .untracked }
        if ["DoubaoSilent", "DoubaoAbandoned", "AmbiguousTurn", "ClaudeChatUnknown"].contains(task.sourceEvent ?? "") ||
            ["结果未知", "状态未知", "已停止跟踪 · 状态未知"].contains(displayedStatus) { return .unknown }
        switch task.status {
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .queued: return .queued
        case .running: return .executing
        case .waiting:
            if needsAttention { return .attention }
            return displayedStatus == "等待回执" ? .awaitingReceipt : .checkingPermission
        }
    }

    var group: TaskVisualGroup {
        switch self {
        case .attention, .executing, .queued, .checkingPermission, .awaitingReceipt: return .active
        case .unknown, .untracked: return .ended
        case .completed, .failed, .cancelled: return .ended
        }
    }
    var animates: Bool { self == .executing }
    var symbol: String {
        switch self {
        case .attention: return "hand.raised.fill"
        case .executing: return "waveform"
        case .queued, .awaitingReceipt: return "clock"
        case .checkingPermission: return "lock.shield"
        case .unknown, .untracked: return "questionmark.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "minus.circle"
        }
    }
    var label: String {
        switch self {
        case .attention: return "等你批准"
        case .executing: return "正在执行"
        case .queued: return "排队中"
        case .checkingPermission: return "在 App 里处理"
        case .awaitingReceipt: return "等 App 确认"
        case .unknown: return "结果未知"
        case .untracked: return "不再跟踪"
        case .completed: return "本轮结束"
        case .failed: return "响应失败"
        case .cancelled: return "已停止"
        }
    }
    var unknownExplanation: String? {
        switch self {
        case .unknown: return "暂未收到明确的最新状态，无法确认是否仍在执行；不会把静默当作完成。"
        case .untracked: return "这条记录已不再跟踪，结果未知；没有证据证明仍在执行或已经完成。"
        default: return nil
        }
    }
}

struct TaskVisualItem: Identifiable {
    let task: AgentTask
    let state: TaskVisualState
    var id: UUID { task.id }
}

struct TaskVisualSection: Identifiable {
    let group: TaskVisualGroup
    let items: [TaskVisualItem]
    var id: TaskVisualGroup { group }

    /// Preserve the store's recency ordering within each display group.
    static func grouped(_ items: [TaskVisualItem]) -> [Self] {
        TaskVisualGroup.allCases.compactMap { group in
            let members = items.filter { $0.state.group == group }
            return members.isEmpty ? nil : Self(group: group, items: members)
        }
    }
}
