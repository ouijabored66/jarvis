import SwiftUI

enum Theme {
    static let accent = Color(red: 0.20, green: 0.95, blue: 0.70)      // reactor green
    static let accent2 = Color(red: 0.25, green: 0.75, blue: 1.00)     // cool cyan
    static let bgTop = Color(red: 0.03, green: 0.06, blue: 0.08)
    static let bgBottom = Color(red: 0.00, green: 0.01, blue: 0.02)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.10)

    static var background: some View {
        ZStack {
            LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(0.18), .clear], center: .top, startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}
