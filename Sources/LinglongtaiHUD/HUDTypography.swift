import SwiftUI

/// The expanded island uses three sizes; weight and contrast express priority.
enum HUDTypography {
    static let pageTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12, weight: .regular)
    static let bodyEmphasis = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 10, weight: .regular)
    static let captionEmphasis = Font.system(size: 10, weight: .medium)
    static let metric = Font.system(size: 13, weight: .medium)
}
