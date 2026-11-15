import SwiftUI
import MuxiCore

struct RatingBadge: View {
    let item: MediaItem
    var fallbackLabel = "媒体库"
    var compact = true
    @AppStorage("fetchExternalRatings") private var enabled = true
    @ViewState private var ratings = MovieRatingSet()

    var body: some View {
        Group {
            if ratings.hasValues {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { scores }
                    VStack(alignment: .leading, spacing: 3) { scores }
                }
            } else if let value = item.CommunityRating, value > 0, value <= 10 {
                label(value, source: fallbackLabel)
            } else { Text("暂无评分").font(.caption2).foregroundStyle(compact ? Color.white.opacity(0.85) : Color.secondary) }
        }
        .task(id: [AnyHashable(item.id), AnyHashable(item.ProviderIds), AnyHashable(item.ExternalRatings), AnyHashable(enabled)]) {
            ratings = item.ExternalRatings ?? MovieRatingSet()
            if enabled {
                let value = await MovieRatings.shared.ratings(for: item)
                guard !Task.isCancelled else { return }
                ratings = value
            }
        }
    }

    private var scoreValues: [MovieRating] { [ratings.imdb, ratings.douban].compactMap { $0 } }

    private var scores: some View {
        ForEach(scoreValues, id: \.source) { (rating: MovieRating) in
            Group {
                if compact { label(rating.value, source: rating.source) }
                else { Link(destination: rating.url) { label(rating.value, source: rating.source) } }
            }.help(ratingHelp(rating))
        }
    }

    private func ratingHelp(_ rating: MovieRating) -> String {
        let votes = rating.votes.map { " · \($0) 人评分" } ?? ""
        let attribution = rating.attribution ?? "公开评分 · 缓存 7 天"
        return rating.source + votes + " · " + attribution
    }

    private func label(_ value: Double, source: String) -> some View {
        Label(source + " " + String(format: "%.1f", value), systemImage: "star.fill")
            .font(compact ? .caption2.weight(.semibold) : .callout.weight(.medium))
            .foregroundStyle(compact ? Color.white : Theme.accent)
    }
}
