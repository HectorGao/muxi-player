import SwiftUI
import MuxiCore

struct TidalBackdrop: View {
    let items: [MediaItem]
    let client: EmbyClient
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
                    let wall = posterWall(size: geometry.size)
                        .rotationEffect(.degrees(-7))
                        .saturation(0.32)
                        .blur(radius: 32)
                        .opacity(colorScheme == .dark ? 0.46 : 0.34)
                    // Only the whole-wall transform changes; poster identities and image tasks stay stable.
                    TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !moving)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 80) / 80
                        wall.offset(x: moving ? sin(phase * .pi * 2) * 48 : 0)
                    }
                }
                LinearGradient(colors: [Theme.canvas.opacity(0.12), Theme.canvas.opacity(0.42), Theme.canvas.opacity(0.82)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func posterWall(size: CGSize) -> some View {
        let posters = Array(items.prefix(8).enumerated())
        let width = max(240, max(size.width / 3.35, size.height * 0.42))
        return VStack(spacing: 26) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 26) {
                    ForEach(posters.filter { $0.offset % 2 == row }, id: \.offset) { entry in
                        PosterView(item: entry.element, client: client)
                            .frame(width: width, height: width * 1.5)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                }.offset(x: row == 0 ? -36 : 36)
            }
        }
        .frame(width: size.width + 320, height: size.height + 320)
        .position(x: size.width / 2, y: size.height / 2)
    }

    static func motionEnabled(preference: Bool, reduceMotion: Bool, reduceTransparency: Bool, sceneActive: Bool, active: Bool) -> Bool {
        preference && !reduceMotion && !reduceTransparency && sceneActive && active
    }
}
