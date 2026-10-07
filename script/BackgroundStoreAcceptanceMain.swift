import Foundation

@main
struct BackgroundStoreAcceptanceMain {
    @MainActor static func main() async {
        do { try await BackgroundStoreAcceptance.run() }
        catch { fputs("FAIL: background acceptance \(error)\n", stderr); exit(1) }
    }
}
