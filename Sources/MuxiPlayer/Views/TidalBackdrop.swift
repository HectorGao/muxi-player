import SwiftUI
import MuxiCore

struct TidalBackdrop: View {
    let items: [MediaItem]
    let client: EmbyClient?
    let active: Bool
    @AppStorage("ambientMotion") private var ambientMotion = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var moving: Bool {
        Self.motionEnabled(preference: ambientMotion, reduceMotion: reduceMotion,
                           reduceTransparency: reduceTransparency,
                           sceneActive: scenePhase == .active, active: active)
    }

    var body: some View {
        ZStack {
            Theme.canvas
            if !reduceTransparency, !items.isEmpty {
                GeometryReader { geometry in
                    TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !moving)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 38) / 38
                        posterWall(size: geometry.size, offset: moving ? sin(phase * .pi * 2) * 190 : 0)
                            .rotationEffect(.degrees(-6))
                            .saturation(colorScheme == .dark ? 0.72 : 0.58)
                            .blur(radius: 20)
                            .opacity(colorScheme == .dark ? 0.64 : 0.44)
                    }
                }
                LinearGradient(colors: [Theme.canvas.opacity(0.08), Theme.canvas.opacity(0.20), Theme.canvas.opacity(0.52)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func posterWall(size: CGSize, offset: Double) -> some View {
        let posters = Array(items.prefix(10))
        let width = max(240, max(size.width / 3.35, size.height * 0.42))
        let columns = Int(ceil((size.width + 600) / (width + 26))) + 1
        return VStack(spacing: 26) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 26) {
                    ForEach(0..<columns, id: \.self) { column in
                        PosterView(item: posters[(column + row * columns) % posters.count], client: client)
                            .frame(width: width, height: width * 1.5)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                }.offset(x: row == 0 ? offset - 36 : -offset + 36)
            }
        }
        .frame(width: size.width + 320, height: size.height + 320)
        .position(x: size.width / 2, y: size.height / 2)
    }

    static func motionEnabled(preference: Bool, reduceMotion: Bool, reduceTransparency: Bool, sceneActive: Bool, active: Bool) -> Bool {
        preference && !reduceMotion && !reduceTransparency && sceneActive && active
    }
}
