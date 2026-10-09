import SwiftUI

/// The hardware notch contour becomes a provider-neutral product identity.
struct LinglongtaiBrandMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            BrandNotchShape()
                .fill(Color(red: 10 / 255, green: 12 / 255, blue: 13 / 255))
            BrandNotchShape()
                .stroke(LinearGradient(colors: [Color(red: 0.97, green: 0.99, blue: 0.97),
                                                 Color(red: 0.6, green: 0.62, blue: 0.6)],
                                       startPoint: .top, endPoint: .bottom), lineWidth: size * 0.06)
            HStack(spacing: size * 0.07) {
                signal(color: Color(red: 121 / 255, green: 242 / 255, blue: 181 / 255), height: 0.16)
                signal(color: Color(red: 247 / 255, green: 247 / 255, blue: 244 / 255), height: 0.25)
                signal(color: Color(red: 132 / 255, green: 219 / 255, blue: 243 / 255), height: 0.12)
            }
            .offset(y: size * 0.028)
        }
        .frame(width: size * 0.92, height: size * 0.5)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func signal(color: Color, height: CGFloat) -> some View {
        Capsule().fill(color).frame(width: size * 0.07, height: size * height)
    }
}

private struct BrandNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulder = rect.width * 0.12
        let radius = rect.height * 0.35
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + shoulder),
                          control: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: rect.maxY),
                          control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - radius),
                          control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
