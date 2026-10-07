import Combine
import Foundation
import LinglongtaiShared

/// Kept separate from TaskStore and the animated shell; no database I/O in body.
final class ConversationTitleStore: ObservableObject {
    static let shared = ConversationTitleStore()
    @Published private(set) var titles: [String: String] = [:]
    private var timer: Timer?
    private var loading = false
    private var codexTitles: [String: String] = [:]
    private var workBuddyTitles: [String: String] = [:]

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("--data-dir"), !arguments.contains("--qa-empty"), !arguments.contains("--qa-demo") else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let codex = ConversationTitles.codexSnapshot()
            let workBuddy = ConversationTitles.workBuddySnapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                // A temporarily unavailable source must not erase the other
                // provider or its own last good snapshot. A successful empty
                // snapshot does clear deleted/untitled metadata.
                if let codex { self.codexTitles = codex }
                if let workBuddy { self.workBuddyTitles = workBuddy }
                let combined = self.codexTitles.merging(self.workBuddyTitles) { _, workBuddy in workBuddy }
                if self.titles != combined { self.titles = combined }
            }
        }
    }

    func title(for task: AgentTask) -> String { ConversationTitles.display(task: task, titles: titles) }
}
