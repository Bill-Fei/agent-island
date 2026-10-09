import LinglongtaiShared
import SwiftUI

/// Semantic and agent identity colors for the dark Dynamic Island surface.
enum HUDColorTokens {
    // Muted semantic accents keep the black surface calm and legible.
    static let info = Color(red: 0.54, green: 0.68, blue: 0.91)
    static let attention = Color(red: 0.91, green: 0.69, blue: 0.50)
    static let success = Color(red: 0.53, green: 0.78, blue: 0.67)
    static let danger = Color(red: 0.88, green: 0.56, blue: 0.59)
    static let neutral = Color(red: 0.62, green: 0.66, blue: 0.73)

    // Agent identity accents: bright progress over deep activity-card surfaces.
    static let codex = Color(red: 0.48, green: 0.66, blue: 1.00)
    static let claude = Color(red: 0.68, green: 0.49, blue: 1.00)
    static let doubao = Color(red: 1.00, green: 0.43, blue: 0.28)
    static let workBuddy = Color(red: 0.20, green: 0.84, blue: 0.62)
    static let custom = Color(red: 0.64, green: 0.68, blue: 0.76)

    static let codexSurface = Color(red: 0.06, green: 0.12, blue: 0.24)
    static let claudeSurface = Color(red: 0.13, green: 0.07, blue: 0.25)
    static let doubaoSurface = Color(red: 0.25, green: 0.08, blue: 0.04)
    static let workBuddySurface = Color(red: 0.03, green: 0.19, blue: 0.15)

    static func agent(_ kind: AgentKind) -> Color {
        switch kind {
        case .codex: return codex
        case .claude: return claude
        case .doubao: return doubao
        case .workBuddy: return workBuddy
        case .custom: return custom
        }
    }

    static func agentSurface(_ kind: AgentKind) -> Color {
        switch kind {
        case .codex: return codexSurface
        case .claude: return claudeSurface
        case .doubao: return doubaoSurface
        case .workBuddy: return workBuddySurface
        case .custom: return Color.black.opacity(0.22)
        }
    }
}
