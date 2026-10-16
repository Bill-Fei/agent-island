import Foundation

/// Metadata only. A tool name is classified, never copied from arbitrary input.
public struct ToolStep: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case running, returned, failed }
    public var id: String
    public var label: String
    public var state: State
    public var updatedAt: Date

    public static func label(for name: String?) -> String {
        switch name {
        case "Bash", "exec_command", "shell", "shell_command": return "执行命令"
        case "Read", "read_file": return "读取文件"
        case "Write", "Edit", "apply_patch": return "编辑文件"
        case "Grep", "Glob": return "检索文件"
        case "WebSearch", "web_search": return "搜索资料"
        case "WebFetch": return "读取网页"
        default: return "工具调用"
        }
    }
}

extension AgentTask {
    public mutating func recordToolEvent(_ event: AgentEvent) {
        guard let name = event.sourceEvent,
              ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(name),
              let date = event.createdAt else { return }
        // Never pair anonymous callbacks speculatively. Their labels describe
        // observations, not uniquely identified executions.
        let key = event.toolStepID ?? "observation:\(name):\(date.timeIntervalSince1970)"
        let state: ToolStep.State = name == "PreToolUse" ? .running : name == "PostToolUseFailure" ? .failed : .returned
        if let index = toolSteps.firstIndex(where: { $0.id == key }) {
            guard date >= toolSteps[index].updatedAt,
                  toolSteps[index].state == .running else { return }
            toolSteps[index].state = state
            toolSteps[index].updatedAt = date
        } else {
            toolSteps.append(ToolStep(id: key, label: event.toolLabel ?? "工具调用", state: state, updatedAt: date))
        }
    }

    public var returnedToolSteps: [ToolStep] {
        toolSteps.filter { $0.state != .running }.sorted { $0.updatedAt > $1.updatedAt }
    }
    public var hasUnidentifiedToolSteps: Bool { toolSteps.contains { $0.id.hasPrefix("observation:") } }

    /// One line a person can read at a glance, built only from classified
    /// labels: "改文件 2 次 · 跑命令 1 次 · 读文件 6 次". Edits and commands
    /// lead because they change things; reads and searches trail.
    public var toolStepSummary: String? {
        let counts = toolStepCounts
        guard !counts.isEmpty else { return nil }
        return counts.map { LF("%@ %lld 次", L($0.verb), $0.count) }.joined(separator: " · ")
    }

    /// The same tally as structured pairs, in display order, for count tiles.
    public var toolStepCounts: [(verb: String, count: Int)] {
        let steps = returnedToolSteps
        let order: [(label: String, verb: String)] = [
            ("编辑文件", "改文件"), ("执行命令", "跑命令"), ("读取文件", "读文件"),
            ("检索文件", "搜文件"), ("读取网页", "看网页"), ("搜索资料", "搜资料"), ("工具调用", "其他工具"),
        ]
        var counts = order.compactMap { entry -> (verb: String, count: Int)? in
            let count = steps.filter { $0.label == entry.label }.count
            return count == 0 ? nil : (entry.verb, count)
        }
        let known = Set(order.map(\.label))
        let other = steps.filter { !known.contains($0.label) }.count
        if other > 0 { counts.append(("其他", other)) }
        return counts
    }

    public var failedToolStepCount: Int { returnedToolSteps.filter { $0.state == .failed }.count }
}
