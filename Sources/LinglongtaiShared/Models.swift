import Foundation
import Darwin

public enum AgentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude
    case doubao
    case workBuddy = "work-buddy"
    case custom

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .doubao: return "豆包"
        case .workBuddy: return "WorkBuddy"
        case .custom: return "Agent"
        }
    }

    public var defaultModel: String {
        switch self {
        case .codex: return "Codex Agent"
        case .claude: return "Claude Code"
        case .doubao: return "豆包 Agent"
        case .workBuddy: return "Work Buddy Agent"
        case .custom: return "Local Agent"
        }
    }

    public var colorHex: String {
        switch self {
        case .codex: return "#8FAEFF"
        case .claude: return "#F5A97F"
        case .doubao: return "#B794FF"
        case .workBuddy: return "#79D6B1"
        case .custom: return "#A7B0C5"
        }
    }

    public var symbolName: String {
        switch self {
        case .codex: return "terminal.fill"
        case .claude: return "sparkles"
        case .doubao: return "bubble.left.and.bubble.right.fill"
        case .workBuddy: return "person.2.fill"
        case .custom: return "circle.dashed"
        }
    }

    public static func resolve(_ rawValue: String) -> AgentKind {
        let compact = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        switch compact {
        case "codex", "openaicodex": return .codex
        case "claude", "claudecode", "anthropicclaude": return .claude
        case "豆包", "doubao", "bytedancedoubao", "volcenginedoubao": return .doubao
        case "workbuddy", "wb": return .workBuddy
        default: return .custom
        }
    }
}

public struct AgentProfile: Equatable, Sendable {
    public let kind: AgentKind
    public let name: String
    public let defaultModel: String
    public let colorHex: String
    public let symbolName: String

    public init(
        kind: AgentKind,
        name: String,
        defaultModel: String,
        colorHex: String,
        symbolName: String
    ) {
        self.kind = kind
        self.name = name
        self.defaultModel = defaultModel
        self.colorHex = colorHex
        self.symbolName = symbolName
    }
}

public enum AgentCatalog {
    public static let supportedKinds: [AgentKind] = [.codex, .claude, .doubao, .workBuddy]

    public static func profile(for rawName: String) -> AgentProfile {
        let kind = AgentKind.resolve(rawName)
        if kind == .custom {
            let customName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentProfile(
                kind: .custom,
                name: customName.isEmpty ? AgentKind.custom.displayName : customName,
                defaultModel: AgentKind.custom.defaultModel,
                colorHex: AgentKind.custom.colorHex,
                symbolName: AgentKind.custom.symbolName
            )
        }
        return AgentProfile(
            kind: kind,
            name: kind.displayName,
            defaultModel: kind.defaultModel,
            colorHex: kind.colorHex,
            symbolName: kind.symbolName
        )
    }

    public static func canonicalName(for rawName: String) -> String {
        profile(for: rawName).name
    }
}

public enum AgentTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case waiting
    case completed
    case failed
    case cancelled

    public var label: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "运行中"
        case .waiting: return "待确认"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已停止"
        }
    }

    public var symbolName: String {
        switch self {
        case .queued: return "clock"
        case .running: return "waveform.path.ecg"
        case .waiting: return "hand.raised"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }
}

public enum AgentTaskSource: String, Codable, CaseIterable, Sendable {
    case liveEvent
    case demo
    case legacy
    case unknown

    public var isLive: Bool { self == .liveEvent }
}

public struct AgentTask: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var agent: String
    public var title: String
    public var status: AgentTaskStatus
    public var progress: Double
    public var detail: String
    public var model: String
    public var updatedAt: Date
    public var requiresApproval: Bool
    public var colorHex: String
    public var source: AgentTaskSource
    public var progressKnown: Bool
    public var sourceEvent: String?
    public var sessionID: String?
    public var turnID: String?
    public var toolSteps: [ToolStep] = []
    public var approvalRequestID: UUID?

    public var statusLabel: String {
        // An earlier phase event must never override the persisted outcome.
        switch status {
        case .completed: return sourceEvent == nil ? status.label : "本轮已结束"
        case .failed: return sourceEvent == nil ? status.label : "本轮响应失败"
        case .cancelled:
            if sourceEvent == "DoubaoAbandoned" { return "已停止跟踪 · 状态未知" }
            if sourceEvent == "SessionEnd" { return "会话已关闭" }
            return sourceEvent == nil ? status.label : "本轮已中断"
        case .queued, .running, .waiting:
            if sourceEvent == "DoubaoSilent" { return "状态未知" }
            if sourceEvent == "AmbiguousTurn" { return "等待状态更新" }
            if status == .waiting { return "等待确认" }
            if status == .queued { return status.label }
            if sourceEvent == "PreToolUse" { return "执行工具" }
            return sourceEvent == nil ? status.label : "处理中"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, agent, title, status, progress, detail, model, updatedAt,
             requiresApproval, colorHex, source, progressKnown, sourceEvent, sessionID, turnID, toolSteps, approvalRequestID
    }

    public var profile: AgentProfile {
        AgentCatalog.profile(for: agent)
    }

    public init(
        id: UUID = UUID(),
        agent: String,
        title: String,
        status: AgentTaskStatus,
        progress: Double = 0,
        detail: String,
        model: String,
        updatedAt: Date = Date(),
        requiresApproval: Bool = false,
        colorHex: String = "#89A8FF",
        source: AgentTaskSource = .unknown,
        progressKnown: Bool = false,
        sourceEvent: String? = nil,
        sessionID: String? = nil,
        turnID: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.title = title
        self.status = status
        self.progress = min(max(progress, 0), 1)
        self.detail = detail
        self.model = model
        self.updatedAt = updatedAt
        self.requiresApproval = requiresApproval
        self.colorHex = colorHex
        self.source = source
        self.progressKnown = progressKnown || source == .demo
        self.sourceEvent = sourceEvent
        self.sessionID = sessionID
        self.turnID = turnID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        agent = try values.decode(String.self, forKey: .agent)
        title = try values.decode(String.self, forKey: .title)
        status = try values.decode(AgentTaskStatus.self, forKey: .status)
        progress = min(max(try values.decode(Double.self, forKey: .progress), 0), 1)
        detail = try values.decode(String.self, forKey: .detail)
        model = try values.decode(String.self, forKey: .model)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        requiresApproval = try values.decode(Bool.self, forKey: .requiresApproval)
        colorHex = try values.decode(String.self, forKey: .colorHex)
        source = try values.decodeIfPresent(AgentTaskSource.self, forKey: .source) ?? .unknown
        progressKnown = try values.decodeIfPresent(Bool.self, forKey: .progressKnown) ?? (source == .demo)
        sourceEvent = try values.decodeIfPresent(String.self, forKey: .sourceEvent)
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        turnID = try values.decodeIfPresent(String.self, forKey: .turnID)
        toolSteps = try values.decodeIfPresent([ToolStep].self, forKey: .toolSteps) ?? []
        approvalRequestID = try values.decodeIfPresent(UUID.self, forKey: .approvalRequestID)
    }
}

public struct AgentEvent: Codable, Sendable {
    public var type: String
    public var id: UUID?
    public var agent: String?
    public var title: String?
    public var status: AgentTaskStatus?
    public var progress: Double?
    public var detail: String?
    public var model: String?
    public var requiresApproval: Bool?
    public var colorHex: String?
    public var createdAt: Date?
    public var sourceEvent: String?
    public var sessionID: String?
    public var turnID: String?
    public var legacySessionID: UUID?
    public var replacesTaskID: UUID?
    public var toolStepID: String?
    public var toolLabel: String?
    public var approvalRequestID: UUID?

    public init(
        type: String,
        id: UUID? = nil,
        agent: String? = nil,
        title: String? = nil,
        status: AgentTaskStatus? = nil,
        progress: Double? = nil,
        detail: String? = nil,
        model: String? = nil,
        requiresApproval: Bool? = nil,
        colorHex: String? = nil,
        createdAt: Date? = Date(),
        sourceEvent: String? = nil,
        sessionID: String? = nil,
        turnID: String? = nil,
        legacySessionID: UUID? = nil,
        replacesTaskID: UUID? = nil
    ) {
        self.type = type
        self.id = id
        self.agent = agent
        self.title = title
        self.status = status
        self.progress = progress
        self.detail = detail
        self.model = model
        self.requiresApproval = requiresApproval
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.sourceEvent = sourceEvent
        self.sessionID = sessionID
        self.turnID = turnID
        self.legacySessionID = legacySessionID
        self.replacesTaskID = replacesTaskID
    }
}

public enum LinglongtaiPaths {
    public static let applicationSupport: URL = {
        // Explicit local test/adapter directory; never inferred from a file.
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--data-dir"), args.indices.contains(index + 1),
           args[index + 1].hasPrefix("/") {
            return URL(fileURLWithPath: args[index + 1], isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LinglongtaiHUD", isDirectory: true)
    }()

    public static var tasks: URL { applicationSupport.appendingPathComponent("tasks.json") }
    public static var state: URL { applicationSupport.appendingPathComponent("state.json") }
    public static var events: URL { applicationSupport.appendingPathComponent("events.jsonl") }
    public static var eventOffset: URL { applicationSupport.appendingPathComponent("events.offset") }
    public static var commands: URL { applicationSupport.appendingPathComponent("commands.jsonl") }
    public static var hookTurns: URL { applicationSupport.appendingPathComponent("hook-turns.json") }

    public static func prepare() {
        try? FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        // Avoid the check-then-createFile race truncating a concurrent hook.
        for file in [events, commands] {
            let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
    }
}
