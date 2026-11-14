import SwiftUI
import MuxiCore

struct OnlineSelection: Identifiable {
    let entry: OnlineItem
    let source: OnlineSource
    var id: String { entry.id }
}

struct OnlineLibraryView: View {
    @Bindable var store: OnlineLibraryStore
    let source: OnlineSource
    let selection: String
    let search: String
    let revision: Int
    let open: (OnlineItem, OnlineSource) -> Void
    var body: some View {
        ScrollView {
            OnlineLibrarySection(store: store, source: source, selection: selection, search: search, revision: revision, open: open).padding(28)
        }
    }
}

struct OnlineLibrarySection: View {
    @Bindable var store: OnlineLibraryStore
    let source: OnlineSource
    let selection: String
    let search: String
    let revision: Int
    let open: (OnlineItem, OnlineSource) -> Void
    @ViewState private var lastRevision = 0
    private var state: OnlineLibraryStore.State { store.state(source, search: search) }
    private var items: [OnlineItem] {
        var items = selection == "favorites" ? store.favorites.filter { $0.sourceID == source.id } : state.items
        if !search.isEmpty, selection == "favorites" { items = items.filter { $0.media.Name.localizedStandardContains(search) } }
        if selection == "series" { items = items.filter { $0.media.Type == "Series" } }
        if selection == "movies" { items = items.filter { $0.media.Type == "Movie" } }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name).font(.title2.weight(.semibold))
                    Text(source.kind == .archive ? "公开影视档案 · 直接播放" : "苹果 CMS · 在线采集接口").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.fromCache { Text("本机缓存").font(.caption).foregroundStyle(.secondary) }
                if state.loading { ProgressView().controlSize(.small) }
                if selection != "favorites", state.error == nil {
                    Button("检查更新") { Task { await store.load(source, search: search, force: true) } }.disabled(state.loading)
                }
            }
            if let error = state.error, selection != "favorites" {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") { Task { await store.load(source, search: search, force: true) } }
                }
            }
            if items.isEmpty, !state.loading, state.error == nil { Text(selection == "favorites" ? "喜欢的影片会保存在这里。" : "这个源暂时没有匹配的影片。").font(.callout).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 185), spacing: 20)], alignment: .leading, spacing: 24) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { open(item, source) } label: {
                            PosterView(item: item.media, client: nil).aspectRatio(2 / 3, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .bottomLeading) {
                                    RatingBadge(item: item.media, fallbackLabel: "片源").padding(5)
                                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5)).padding(7)
                                }
                        }.buttonStyle(.plain).accessibilityLabel(item.media.Name)
                            .overlay(alignment: .topTrailing) {
                                Button { store.toggleFavorite(item) } label: {
                                    Image(systemName: store.isFavorite(item) ? "heart.fill" : "heart")
                                        .foregroundStyle(.white).padding(8).background(.black.opacity(0.65), in: Circle())
                                }.buttonStyle(.plain).padding(7).help(store.isFavorite(item) ? "取消收藏" : "收藏到本机")
                            }
                        Button { open(item, source) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.media.Name).font(.callout.weight(.medium)).lineLimit(1)
                                Text(item.media.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }.help(item.media.Name)
                }
            }
            if selection != "favorites", state.hasMore {
                Button("加载更多") { Task { await store.load(source, search: search, more: true) } }.disabled(state.loading)
            }
            if let date = state.checkedAt, selection != "favorites" {
                Text("本机已有 \(state.items.count) 项 · 同步于 " + date.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: "\(source.id)|\(source.enabled)|\(search)|\(revision)|\(selection)") {
            guard selection != "favorites" else { return }
            do {
                if !search.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                let force = revision != lastRevision
                lastRevision = revision
                await store.load(source, search: search, force: force)
            } catch { }
        }
    }
}

struct OnlineDetailView: View {
    let selected: OnlineSelection
    @Bindable var store: OnlineLibraryStore
    let resume: OnlineResume?
    let play: (Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var routes: [OnlineRoute] = []
    @ViewState private var route = 0
    @ViewState private var episode = 0
    @ViewState private var loading = true
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(selected.source.name).font(.caption).foregroundStyle(.secondary); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            HStack(alignment: .top, spacing: 26) {
                PosterView(item: selected.entry.media, client: nil).frame(width: 180, height: 270).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 16) {
                    Text(selected.entry.media.Name).font(.title2.weight(.semibold))
                    Text(selected.entry.media.subtitle).foregroundStyle(.secondary)
                    RatingBadge(item: selected.entry.media, fallbackLabel: "片源", compact: false)
                    ScrollView { Text(selected.entry.media.Overview ?? "暂无简介").lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                    if loading { ProgressView("正在读取线路与分集…") }
                    if !routes.isEmpty {
                        Picker("线路／文件", selection: Binding(get: { route }, set: { route = $0; episode = 0 })) {
                            ForEach(routes.indices, id: \.self) { Text(routes[$0].name).tag($0) }
                        }
                    }
                    HStack {
                        Button { play(route, episode) } label: { Label("播放", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).disabled(loading || routes.isEmpty).keyboardShortcut(.defaultAction)
                        Button(store.isFavorite(selected.entry) ? "取消收藏" : "收藏") { store.toggleFavorite(selected.entry) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if routes.indices.contains(route), routes[route].episodes.count > 1 {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 8)], spacing: 8) {
                        ForEach(routes[route].episodes.indices, id: \.self) { index in
                            Button(routes[route].episodes[index].name) { episode = index }
                                .tint(episode == index ? Theme.accent : nil)
                                .buttonStyle(.bordered).lineLimit(1)
                        }
                    }
                }.frame(maxHeight: 160)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            Text("libmpv 本机播放 · 音轨与字幕在播放后自动识别 · 收藏与进度保存在本机")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(width: 750)
            .task {
                do {
                    routes = try await OnlineCatalogClient().routes(for: selected.entry, source: selected.source)
                    if let resume, resume.entry.id == selected.entry.id,
                       let routeIndex = routes.firstIndex(where: { $0.name == resume.routeName }) {
                        route = routeIndex
                        episode = routes[routeIndex].episodes.firstIndex { $0.name == resume.episodeName } ?? 0
                    }
                } catch { self.error = "这个源暂未提供可播放的线路，请稍后重试。" }
                loading = false
            }
    }
}
