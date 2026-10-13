import Combine
import Foundation
import LinglongtaiShared

/// Independent incremental reader: never interferes with TaskStore's cursor or
/// checkpoint. Replays the existing metadata journal after restart, off main.
@MainActor
final class AIWorkDurationStore: ObservableObject {
    static let shared = AIWorkDurationStore()
    @Published private(set) var summary = AIWorkDuration.Summary(seconds: 0, incomplete: false, loading: true)
    private var ledger = AIWorkDuration()
    private var offset: UInt64 = 0
    private var loading = false
    private var timer: Timer?

    private init() {
        let args = ProcessInfo.processInfo.arguments
        guard !args.contains("--qa-empty"), !args.contains("--qa-demo"), !args.contains("--data-dir") else {
            summary = .init(seconds: 0, incomplete: false)
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard !loading else { return }
        loading = true
        let previous = ledger, cursor = offset, url = LinglongtaiPaths.events
        Task {
            let result = await Task.detached(priority: .utility) { () -> (AIWorkDuration, UInt64, Bool, Bool) in
                var ledger = previous, offset = cursor
                if !FileManager.default.fileExists(atPath: url.path) { return (ledger, offset, false, false) }
                do {
                    // Bound each background pass; large journals continue on
                    // the next pass without blocking UI or dropping history.
                    for _ in 0..<16 {
                        let batch = try EventJournal.read(at: url, offset: offset, lineLimit: 2048)
                        if batch.start < offset { ledger = AIWorkDuration() }
                        offset = batch.end
                        if batch.rejectedRowCount > 0 {
                            // Cannot locate a discarded waiting/terminal row:
                            // exclude this whole batch rather than bridge it.
                            ledger.discontinuity(at: Date())
                        } else { for event in batch.events { ledger.consume(event) } }
                        if batch.blockedByOversizedLine { return (ledger, offset, false, true) }
                        if batch.end == batch.start {
                            ledger.discardHistory(before: Calendar.autoupdatingCurrent.startOfDay(for: Date()))
                            return (ledger, offset, false, false)
                        }
                    }
                    return (ledger, offset, true, false)
                } catch { return (ledger, offset, false, true) }
            }.value
            ledger = result.0; offset = result.1; loading = false
            var next = ledger.summary(now: Date())
            next.loading = result.2
            if result.3 { next.incomplete = true }
            if next != summary { summary = next }
        }
    }
}
