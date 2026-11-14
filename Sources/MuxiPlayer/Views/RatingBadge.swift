import SwiftUI
import MuxiCore

struct RatingBadge: View {
    let item: MediaItem
    var fallbackLabel = "媒体库"
    var compact = true
    @AppStorage("fetchExternalRatings") private var enabled = true
    @ViewState private var rating: MovieRating?

    var body: some View {
        Group {
            if let rating {
                if compact { label(rating.value, source: rating.source) }
                else {
                    Link(destination: rating.url) { label(rating.value, source: rating.source) }
                        .help(rating.source + (rating.votes.map { " · \($0) 人评分" } ?? "") + " · 缓存 7 天")
                }
            } else if let value = item.CommunityRating, value > 0, value <= 10 {
                label(value, source: fallbackLabel)
            } else { Text("暂无评分").font(.caption2).foregroundStyle(compact ? Color.white.opacity(0.85) : Color.secondary) }
        }
        .task(id: "\(item.id)|\(item.ProviderIds ?? [:])|\(enabled)") {
            rating = nil
            if enabled {
                let value = await MovieRatings.shared.rating(for: item)
                guard !Task.isCancelled else { return }
                rating = value
            }
        }
    }

    private func label(_ value: Double, source: String) -> some View {
        Label(source + " " + String(format: "%.1f", value), systemImage: "star.fill")
            .font(compact ? .caption2.weight(.semibold) : .callout.weight(.medium))
            .foregroundStyle(compact ? Color.white : Theme.accent)
    }
}
