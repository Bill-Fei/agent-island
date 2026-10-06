import Foundation
import LinglongtaiShared

/// Focused L2 checks; no personal data, hooks, approval writes, or GUI input.
@main
struct HoverMotionAcceptance {
    static func main() {
        var count = 0
        func check(_ name: String, _ passed: Bool) {
            guard passed else {
                fputs("FAIL: \(name)\n", stderr)
                exit(1)
            }
            count += 1
        }
        runMotionRevisionChecks(check: check)
        runWingLayoutRevisionChecks(check: check)
        runContentWidthRevisionChecks(check: check)
        var pointer = IslandInteraction()
        pointer.samplePointer(inside: true, at: 0)
        pointer.samplePointer(inside: true, at: 0.199)
        check("hover respects the dwell", !pointer.isHovering)
        pointer.samplePointer(inside: true, at: 0.2)
        check("hover opens at 200ms", pointer.isHovering)
        for index in 0...60 {
            pointer.samplePointer(inside: false, at: 1 + Double(index) / 120)
        }
        check("continuous pointer polling still closes", !pointer.isHovering)
        print("PASS: \(count) focused hover, motion and wing layout checks")
    }
}
