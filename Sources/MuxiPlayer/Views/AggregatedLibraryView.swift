import SwiftUI
import MuxiCore

struct AggregatedLibraryView: View {
    let connection: ConnectionStore
    let selection: String
    let search: String
    let playbackRevision: Int
    let online: OnlineLibraryStore
    let onlineRevision: Int
    let open: (MediaItem, SavedMediaSource, LibraryStore, EmbyClient) -> Void
    let browse: (SavedMediaSource, String) -> Void
    let openOnline: (OnlineItem, OnlineSource) -> Void
    let posters: (UUID, [MediaItem]) -> Void
    @ViewState private var libraries: [UUID: LibraryStore] = [:]
    @ViewState private var lastOnlineRevision = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(search.isEmpty ? "媒体墙" : "跨媒体源搜索").font(.system(size: 32, weight: .medium, design: .serif))
                    Text("\(connection.sources.count) 个私人媒体源 · \(online.enabledSources.count) 个在线源")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(connection.sources) { source in
                    if let client = connection.clients[source.id], let library = libraries[source.id] {
                        SourceLibrarySection(source: source, client: client, selection: selection, search: search,
                                             library: library, open: open, browse: browse, posters: posters)
                            .id("\(source.id)|\(connection.revision)")
                    }
                }
                ForEach(selection == "favorites" ? online.sources : online.enabledSources) { source in
                    OnlineLibrarySection(store: online, source: source, selection: selection, search: search, revision: onlineRevision, open: openOnline)
                        .padding(22).background(Theme.surface.opacity(0.42), in: RoundedRectangle(cornerRadius: 22))
                }
            }.padding(28)
        }
        .task(id: [AnyHashable(selection), AnyHashable(search), AnyHashable(playbackRevision), AnyHashable(connection.revision),
                   AnyHashable(online.sources.map(\.id)), AnyHashable(online.sources.map(\.enabled))]) {
            do {
                if !search.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                for source in connection.sources where libraries[source.id] == nil { libraries[source.id] = LibraryStore() }
                let forceOnline = lastOnlineRevision != onlineRevision
                lastOnlineRevision = onlineRevision
                await withTaskGroup(of: Void.self) { group in
                    for source in connection.sources {
                        if let client = connection.clients[source.id], let library = libraries[source.id] {
                            group.addTask {
                                if forceOnline, !search.isEmpty { await library.prepareFilters(client: client, selection: selection, force: true, search: search) }
                                await library.refresh(client: client, selection: selection, search: search)
                            }
                        }
                    }
                    if selection != "favorites" {
                        for source in online.enabledSources { group.addTask { await online.load(source, search: search, force: forceOnline) } }
                    }
                }
            } catch { }
        }
    }
}

private struct SourceLibrarySection: View {
    let source: SavedMediaSource
    let client: EmbyClient
    let selection: String
    let search: String
    let library: LibraryStore
    let open: (MediaItem, SavedMediaSource, LibraryStore, EmbyClient) -> Void
    let browse: (SavedMediaSource, String) -> Void
    let posters: (UUID, [MediaItem]) -> Void
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
                    Button("重试") { Task { await library.refresh(client: client, selection: selection, search: search) } }
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
        }.padding(22).background(Theme.surface.opacity(0.42), in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(Theme.border, lineWidth: 0.5) }
            .onChange(of: library.recommendations, initial: true) { _, items in posters(source.id, items) }
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

}
