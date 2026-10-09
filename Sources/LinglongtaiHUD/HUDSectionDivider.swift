import SwiftUI

struct HUDSectionDivider: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
