import SwiftUI

/// A glowing light: counter-rotating rings in warm gold and amber that follow Lumen's state and your voice.
struct ReactorView: View {
    var state: JarvisState
    var level: Float

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2
                let speed: Double = state == .thinking ? 2.4 : (state == .listening ? 1.4 : 0.6)
                let pulse = state == .listening ? CGFloat(level) : (state == .speaking ? CGFloat(0.35 + 0.25 * sin(t * 9)) : 0)
                let gold = state == .offline ? Color.gray : Theme.accent
                let amber = state == .offline ? Color.gray : Theme.accent2

                // soft glow, the same warm gold as the background bloom
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.62, y: c.y - r * 0.62, width: r * 1.24, height: r * 1.24)),
                         with: .radialGradient(Gradient(colors: [gold.opacity(0.40 + 0.28 * pulse), amber.opacity(0.16), .clear]),
                                               center: c, startRadius: 0, endRadius: r * 0.9))

                func ring(_ radius: CGFloat, width: CGFloat, dash: [CGFloat], angle: Double, opacity: Double, color: Color) {
                    var p = Path()
                    p.addArc(center: c, radius: radius, startAngle: .radians(angle), endAngle: .radians(angle + .pi * 2), clockwise: false)
                    ctx.stroke(p, with: .color(color.opacity(opacity)),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
                }
                ring(r * 0.92, width: 2, dash: [2, 10], angle: t * 0.3 * speed, opacity: 0.55, color: amber)
                ring(r * 0.80, width: 5, dash: [r * 0.55, r * 0.18], angle: -t * 0.8 * speed, opacity: 0.85, color: gold)
                ring(r * 0.66, width: 3, dash: [r * 0.12, r * 0.08], angle: t * 1.3 * speed, opacity: 0.7, color: amber)
                ring(r * 0.52 + pulse * r * 0.06, width: 9, dash: [r * 0.9, r * 0.25], angle: -t * 0.5 * speed, opacity: 0.95, color: gold)

                // core
                let core = r * (0.30 + 0.06 * pulse)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)),
                         with: .radialGradient(Gradient(colors: [Color(red: 1.0, green: 0.97, blue: 0.90), gold, amber.opacity(0.25)]),
                                               center: c, startRadius: 0, endRadius: core))
            }
        }
        .accessibilityLabel(Text(label))
    }

    private var label: String {
        switch state {
        case .idle: return "Lumen is ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .offline: return "Offline"
        }
    }
}
