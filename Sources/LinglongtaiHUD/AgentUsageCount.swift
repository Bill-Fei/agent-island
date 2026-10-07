import LinglongtaiShared

struct AgentUsageCount: Identifiable, Equatable {
    let kind: AgentKind
    let count: Int
    var id: AgentKind { kind }
}
