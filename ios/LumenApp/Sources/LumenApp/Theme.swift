import SwiftUI

enum Theme {
    static let accent = Color(red: 1.00, green: 0.761, blue: 0.290)     // #FFC24A warm gold
    static let accent2 = Color(red: 1.00, green: 0.541, blue: 0.239)    // #FF8A3D amber
    static let bgTop = Color(red: 0.09, green: 0.06, blue: 0.03)
    static let bgBottom = Color(red: 0.02, green: 0.01, blue: 0.01)
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
