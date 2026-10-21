import SwiftUI
import MuxiCore

struct MediaCard: View {
    let item: MediaItem
    let client: EmbyClient
    let library: LibraryStore
    var landscape = false
    let open: (MediaItem) -> Void
    @ViewState private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { open(item) } label: {
                PosterView(item: item, client: client, backdrop: landscape)
                    .aspectRatio(landscape ? 16 / 9 : 2 / 3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottom) {
                        if landscape, item.resumeTicks > 0 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(PlaybackTime.label(Double(item.resumeTicks) / 10_000_000) + " / " + PlaybackTime.label(Double(item.RunTimeTicks ?? 0) / 10_000_000))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.white)
                                ProgressView(value: min(item.UserData?.PlayedPercentage ?? 0, 100), total: 100).tint(.white)
                            }.padding(9).background(.black.opacity(0.65))
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !landscape, let rating = item.CommunityRating, rating > 0 {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(5)
                                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5)).padding(7)
                        }
                    }
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(hovered ? Theme.accent : Theme.border, lineWidth: hovered ? 2 : 0.5) }
                    .shadow(color: .black.opacity(hovered ? 0.2 : 0.1), radius: hovered ? 10 : 5, y: 4)
            }.buttonStyle(.plain).accessibilityLabel(item.Name + "，" + item.subtitle)
                .overlay(alignment: .topTrailing) {
                    FavoriteButton(item: item, client: client, library: library, compact: true).padding(7)
                }
            Button { open(item) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.Name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(item.subtitle.isEmpty ? (item.isContainer ? "打开目录" : "视频") : item.subtitle)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.onHover { hovered = $0 }.help(item.Name)
            .contextMenu {
                Button(library.isFavorite(item) ? "取消收藏" : "加入收藏") { Task { await library.toggleFavorite(item, client: client) } }
                    .disabled(library.favoritePending.contains(item.id))
            }
    }
}

struct FavoriteButton: View {
    let item: MediaItem
    let client: EmbyClient
    let library: LibraryStore
    var compact = false

    var body: some View {
        let saved = library.isFavorite(item)
        Button { Task { await library.toggleFavorite(item, client: client) } } label: {
            if compact {
                Image(systemName: saved ? "heart.fill" : "heart")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(saved ? Color(red: 0.95, green: 0.77, blue: 0.47) : .white)
                    .frame(width: 30, height: 30).background(.black.opacity(0.65), in: Circle())
            } else { Label(saved ? "已收藏" : "收藏", systemImage: saved ? "heart.fill" : "heart") }
        }.buttonStyle(.plain).disabled(library.favoritePending.contains(item.id))
            .accessibilityLabel((saved ? "取消收藏：" : "收藏：") + item.Name)
            .help(saved ? "取消收藏" : "收藏到服务器")
    }
}

struct PosterView: View {
    let item: MediaItem
    let client: EmbyClient
    var backdrop = false
    @ViewState private var image: NSImage?
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 180
        cache.totalCostLimit = 80 * 1_024 * 1_024
        return cache
    }()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.surface
                if let image { Image(nsImage: image).resizable().scaledToFill() }
                else { Image(systemName: item.isContainer ? "rectangle.stack" : "film").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(.tertiary) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.task(id: "\(client.baseURL)|\(client.connection?.user.Id ?? "")|\(item.id)|\(backdrop)|\(item.ImageTags?["Primary"] ?? "")|\(item.BackdropImageTags?.first ?? "")") {
            image = nil
            do {
                guard let request = try client.imageRequest(item: item, backdrop: backdrop) else { return }
                let key = "\(client.connection?.user.Id ?? "")|\(request.url!.absoluteString)" as NSString
                if let cached = Self.cache.object(forKey: key) { image = cached; return }
                let data = try await client.data(for: request)
                guard !Task.isCancelled, let loaded = NSImage(data: data) else { return }
                Self.cache.setObject(loaded, forKey: key, cost: Int(loaded.size.width * loaded.size.height * 4))
                image = loaded
            } catch { /* Missing artwork leaves the media item usable. */ }
        }
    }
}
