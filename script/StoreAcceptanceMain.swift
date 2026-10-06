import Foundation
import LinglongtaiShared

/// Runs the production state store without NSApplication or GUI permissions.
@main
struct StoreAcceptanceMain {
    @MainActor static func main() {
        TaskStoreAcceptance.run()
        let report = LinglongtaiPaths.applicationSupport.appendingPathComponent("acceptance.txt")
        guard let text = try? String(contentsOf: report, encoding: .utf8),
              text.contains("PASS:"), !text.contains("FAIL:") else { exit(1) }
        print("\(text.split(separator: "\n").count) isolated TaskStore checks passed")
    }
}
