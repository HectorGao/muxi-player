import SwiftUI
import MuxiCore

struct AggregatedLibraryView: View {
    let connection: ConnectionStore
    let selection: String
    let search: String
    let playbackRevision: Int
    let open: (MediaItem, SavedMediaSource, LibraryStore, EmbyClient) -> Void
    let browse: (SavedMediaSource, String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(search.isEmpty ? "你的私人影视库" : "跨媒体源搜索").font(.system(size: 32, weight: .medium, design: .serif))
                    Text("\(connection.sources.count) 个媒体源 · 收藏与进度分别同步到所属服务器")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(connection.sources) { source in
                    if let client = connection.clients[source.id] {
                        SourceLibrarySection(source: source, client: client, selection: selection, search: search,
                                             revision: playbackRevision, open: open, browse: browse)
                            .id("\(source.id)|\(connection.revision)")
                    }
                }
            }.padding(28)
        }
    }
}

private struct SourceLibrarySection: View {
    let source: SavedMediaSource
    let client: EmbyClient
    let selection: String
    let search: String
    let revision: Int
    let open: (MediaItem, SavedMediaSource, LibraryStore, EmbyClient) -> Void
    let browse: (SavedMediaSource, String) -> Void
    @ViewState private var library = LibraryStore()
    private var home: Bool { selection == "home" && search.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name).font(.title2.weight(.semibold))
                    Text("\((source.connection.serverKind ?? .emby).label) · \(source.connection.user.Name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("浏览此源") { browse(source, "home") }.buttonStyle(.bordered)
            }
            if library.loading { ProgressView("正在读取媒体库…") }
            if let error = library.error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") { Task { await refresh() } }
                }.font(.callout)
            }
            if let error = library.favoriteError { Text(error).font(.caption).foregroundStyle(.red) }
            if home {
                if !library.libraries.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(library.libraries) { item in
                                Button { browse(source, "library:" + item.id) } label: { Label(item.Name, systemImage: "folder") }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
                if !library.resume.isEmpty { Text("继续观看").font(.headline); row(library.resume, landscape: true) }
                if !library.recommendations.isEmpty { Text("为你推荐").font(.headline); row(library.recommendations) }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)], spacing: 22) {
                    ForEach(library.items) { item in card(item) }
                }
                if library.hasMore {
                    Button(library.loadingMore ? "正在加载…" : "加载更多") {
                        Task { await library.more(client: client, selection: selection, search: search) }
                    }.disabled(library.loadingMore)
                }
            }
            if !library.loading, library.error == nil, (home ? library.recommendations.isEmpty && library.resume.isEmpty : library.items.isEmpty) {
                Text(selection == "search" && search.isEmpty ? "输入片名，搜索所有媒体源。" : "暂无内容")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.padding(22).background {
            TidalBackdrop(items: library.recommendations, client: client, active: true)
                .overlay(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 22))
        }
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(Theme.border, lineWidth: 0.5) }
            .task(id: "\(selection)|\(search)|\(revision)") { await refresh() }
    }

    private func card(_ item: MediaItem, landscape: Bool = false) -> some View {
        MediaCard(item: item, client: client, library: library, landscape: landscape) { open($0, source, library, client) }
    }

    private func row(_ items: [MediaItem], landscape: Bool = false) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 18) {
                ForEach(items) { item in card(item, landscape: landscape).frame(width: landscape ? 248 : 154) }
            }.padding(.bottom, 8)
        }
    }

    private func refresh() async { await library.refresh(client: client, selection: selection, search: search) }
}
