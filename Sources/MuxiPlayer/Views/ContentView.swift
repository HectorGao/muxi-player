import SwiftUI
import MuxiCore

private struct MediaSelection: Identifiable {
    let id = UUID()
    let item: MediaItem
    let client: EmbyClient
    let library: LibraryStore
}

struct ContentView: View {
    @Bindable var connection: ConnectionStore
    @Bindable var playback: PlaybackController
    @ViewState private var library = LibraryStore()
    @ViewState private var selection = "home"
    @ViewState private var search = ""
    @ViewState private var sidebarVisible = true
    @ViewState private var playerWindow = PlayerWindow()
    @ViewState private var detail: MediaSelection?
    @ViewState private var onlineDetail: OnlineSelection?
    @ViewState private var online = OnlineLibraryStore.shared
    @ViewState private var sites = ViewingSiteStore.shared
    @ViewState private var websiteURL: URL?
    @ViewState private var connectingSite: ViewingSite?
    @ViewState private var startupOpenPending = true
    @ViewState private var sourcePosters: [UUID: [MediaItem]] = [:]
    @ViewState private var managingSources = false
    @ViewState private var refreshRevision = 0
    @ViewState private var pendingFolder: MediaItem?
    @ViewState private var pendingSelection = "home"
    @ViewState private var returnSelection = "home"
    @FocusState private var searchFocused: Bool
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.dark.rawValue
    @AppStorage("ambientMotion") private var ambientMotion = true
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var immersive: Bool { selection == "playing" && playback.item != nil && playerWindow.isImmersive }

    private var title: String {
        if selection == "sites" { return "观影站点" }
        if selection == "history" { return "观影记录" }
        if selection == "website" { return "网页观影" }
        if selection == "playing" { return playback.item?.Name ?? "现在观看" }
        if !query.isEmpty { return "搜索结果" }
        if let folder = library.path.last { return folder.Name }
        switch selection {
        case "playing": return playback.item?.Name ?? "现在观看"
        case "catalog": return "全部内容"
        case "movies": return "电影"
        case "series": return "剧集"
        case "home": return "媒体墙"
        case "search": return "搜索"
        case "favorites": return "我的收藏"
        case "recommendations": return "为你推荐"
        default: return library.libraries.first { "library:" + $0.id == selection }?.Name ?? "媒体库"
        }
    }

    var body: some View {
        Group {
            if connection.restoring {
                VStack(spacing: 16) {
                    ProgressView("正在恢复媒体源…")
                    Text("如 macOS 询问钥匙串权限，请允许 muxi 读取已保存的连接。")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    if sidebarVisible && !immersive { sidebar.frame(width: 210) }
                    VStack(spacing: 0) {
                        if !immersive { toolbar }
                        if !["playing", "sites", "history", "website"].contains(selection) {
                            if playback.onlineMostRecent, let recent = playback.onlineRecent,
                               let source = online.sources.first(where: { $0.id == recent.entry.sourceID }) {
                                returnToOnlinePlayback(recent, source: source)
                            } else if let recent = playback.recent, let client = recentClient {
                                returnToPlayback(recent, client: client)
                            }
                        }
                        if selection == "sites" {
                            ViewingSitesView(store: sites, open: openSite, manageSources: { managingSources = true })
                        } else if selection == "history" {
                            ViewingHistoryView(sites: sites, playback: playback, connection: connection, online: online,
                                               openWebsite: openWebsite, resume: resumeHistory)
                        } else if selection == "website", let url = websiteURL {
                            WebsiteView(url: url, store: sites) { navigate("sites") }
                        } else if selection == "playing" {
                            PlayerView(playback: playback, window: playerWindow, exit: exitPlayback)
                        } else if let source = online.selectedSource {
                            OnlineLibraryView(store: online, source: source, selection: selection, search: query,
                                              revision: refreshRevision, open: openOnline)
                        } else if let client = connection.client {
                            LibraryView(library: library, client: client, title: title, selection: selection, searching: !query.isEmpty,
                                        showHome: selection == "home" && library.path.isEmpty && query.isEmpty,
                                        open: openItem, navigate: navigate, more: { Task { await library.more(client: client, selection: selection, search: search) } },
                                        retry: { Task { await refresh() } })
                                .id("\(selection)|\(library.path.last?.id ?? "")")
                        } else {
                            AggregatedLibraryView(connection: connection, selection: selection, search: query,
                                                  playbackRevision: playback.revision + refreshRevision, online: online,
                                                  onlineRevision: refreshRevision, open: openAggregated, browse: browseSource, openOnline: openOnline,
                                                  posters: { sourcePosters[$0] = $1 })
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background { backdrop }
                .task(id: [AnyHashable(selection), AnyHashable(search), AnyHashable(library.path.last?.id), AnyHashable(playback.revision), AnyHashable(library.filter), AnyHashable(connection.selectedSourceID), AnyHashable(connection.revision)]) {
                    if !["playing", "sites", "history", "website"].contains(selection) { await refresh() }
                }
            }
        }
        .background(PlayerWindowReader(state: playerWindow).frame(width: 0, height: 0))
        .focusedSceneValue(\.playerWindow, playerWindow)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $managingSources) { SourceManagerView(connection: connection, playback: playback) }
        .sheet(item: $connectingSite) { site in
            ConnectView(connection: connection, preset: site, saved: { connectingSite = nil }, cancel: { connectingSite = nil })
                .frame(width: 960, height: 760)
        }
        .sheet(item: $onlineDetail) { selected in
            OnlineDetailView(selected: selected, store: online, resume: playback.onlineRecent) { route, episode in
                playback.playOnline(selected.entry, source: selected.source, route: route, episode: episode)
                onlineDetail = nil; returnSelection = selection; selection = "playing"
            }
        }
        .sheet(item: $detail) { selected in
            MediaDetailView(item: selected.item, client: selected.client, library: selected.library) { fresh, fromStart, sourceID in
                playback.play(fresh, client: selected.client, queue: selected.library.items.filter { !$0.isContainer }, fromStart: fromStart, sourceID: sourceID)
                detail = nil
                returnSelection = selection
                selection = "playing"
            }
        }
        .onChange(of: connection.selectedSourceID) { _, _ in
            stopPlayback()
            detail = nil
            library = LibraryStore()
            library.path = pendingFolder.map { [$0] } ?? []
            selection = pendingSelection
            pendingFolder = nil; pendingSelection = "home"
            search = ""
        }
        .onChange(of: online.selectedID) { _, _ in
            stopPlayback(); onlineDetail = nil; detail = nil
            library = LibraryStore(); selection = "home"; search = ""
        }
        .onChange(of: connection.revision) { _, _ in
            stopPlayback(); detail = nil; sourcePosters = [:]; library = LibraryStore(); selection = "home"; search = ""
            sites.synchronize(online: online.sources, servers: connection.sources)
        }
        .onChange(of: online.sources) { _, _ in sites.synchronize(online: online.sources, servers: connection.sources) }
        .onChange(of: search) { _, _ in startupOpenPending = false }
        .onChange(of: managingSources) { _, visible in if visible { startupOpenPending = false } }
        .onChange(of: sites.startupSite) { _, site in
            if startupOpenPending, let site, selection == "home", playback.item == nil, query.isEmpty,
               detail == nil, onlineDetail == nil, connectingSite == nil, !managingSources {
                openSite(site)
            }
            startupOpenPending = false
        }

        .onChange(of: playback.item?.id) { _, id in
            if id == nil, selection == "playing" {
                playerWindow.showingOptions = false
                playerWindow.isWindowFullScreen = false
                playerWindow.exitFullScreen()
                selection = returnSelection
            }
        }
        .task { await online.restore() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("muxi").font(.system(size: 32, weight: .semibold, design: .rounded)).tracking(-1.5)
                Text("幕汐").font(.caption).tracking(4).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.top, 46).padding(.bottom, 20)
            Menu {
                Button("全部媒体源") { startupOpenPending = false; online.selectedID = nil; connection.selectSource(nil) }
                Divider()
                ForEach(connection.sources) { source in Button(source.name) { startupOpenPending = false; online.selectedID = nil; connection.selectSource(source.id) } }
                Divider()
                ForEach(online.enabledSources) { source in Button(source.name) { startupOpenPending = false; connection.selectSource(nil); online.selectedID = source.id } }
            } label: {
                HStack {
                    Image(systemName: "externaldrive")
                    Text(online.selectedSource?.name ?? connection.selectedSource?.name ?? "全部媒体源").lineLimit(1)
                    Spacer()
                }.padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }.menuStyle(.borderlessButton).padding(.horizontal, 16).padding(.bottom, 18).accessibilityLabel("切换媒体源")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    navigationRow("媒体墙", icon: "square.grid.2x2", value: "home")
                    navigationRow("为你推荐", icon: "sparkles", value: "recommendations")
                    navigationRow("我的收藏", icon: "heart", value: "favorites")
                    navigationRow("观影站点", icon: "network", value: "sites")
                    navigationRow("观影记录", icon: "clock", value: "history")
                    Text("媒体库").font(.caption).foregroundStyle(.secondary).padding(.leading, 12).padding(.top, 22).padding(.bottom, 6)
                    navigationRow("全部内容", icon: "square.stack", value: "catalog")
                    if connection.client == nil || online.selectedSource != nil {
                        navigationRow("电影", icon: "film", value: "movies")
                        navigationRow("剧集", icon: "tv", value: "series")
                    } else {
                        ForEach(library.libraries) { item in
                            navigationRow(item.Name, icon: item.Name.contains("剧") ? "tv" : "folder", value: "library:" + item.id)
                        }
                    }
                }.padding(.horizontal, 10)
            }
            Divider().padding(.horizontal, 20)
            HStack {
                Button { managingSources = true } label: { Label("管理媒体源", systemImage: "externaldrive.badge.plus") }
                    .buttonStyle(.plain)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).help("设置")
            }.padding(20)
        }.background(.ultraThinMaterial)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 0.5) }
    }

    private var recentClient: EmbyClient? {
        guard let recent = playback.recent else { return nil }
        return connection.sources.compactMap { connection.clients[$0.id] }.first { recent.belongs(to: $0) }
    }

    @ViewBuilder private var backdrop: some View {
        let active = selection != "playing" && !playback.isPlaying
        if let client = connection.client, online.selectedID == nil {
            let shelves = library.libraries.flatMap { library.shelves[$0.id]?.items ?? [] }
            let items = library.items.isEmpty ? (library.recommendations.isEmpty ? shelves : library.recommendations) : library.items
            TidalBackdrop(items: items.filter { $0.ImageTags?["Primary"] != nil }, client: client, active: active)
        } else if online.selectedID == nil, let source = connection.sources.first(where: { !(sourcePosters[$0.id] ?? []).isEmpty }),
                  let client = connection.clients[source.id] {
            TidalBackdrop(items: sourcePosters[source.id] ?? [], client: client, active: active)
        } else { TidalBackdrop(items: online.backdropItems, client: nil, active: active) }
    }

    private func openOnline(_ entry: OnlineItem, source: OnlineSource) {
        startupOpenPending = false; onlineDetail = OnlineSelection(entry: entry, source: source)
    }

    private func openSite(_ site: ViewingSite) {
        if let source = online.sources.first(where: { $0.id == site.id && $0.enabled }) {
            online.selectedID = source.id; connection.selectSource(nil); navigate("home")
        } else if connection.sources.contains(where: { $0.id == site.id }) {
            online.selectedID = nil; connection.selectSource(site.id); navigate("home")
        } else if site.kind == .emby || site.kind == .jellyfin {
            connectingSite = site
        } else { openWebsite(site.url) }
    }

    private func openWebsite(_ url: URL) { navigate("website"); websiteURL = url }

    private func resumeHistory(_ entry: PlaybackHistoryEntry) {
        let client = entry.recent.flatMap { recent in connection.clients.values.first { recent.belongs(to: $0) } }
        let source = online.enabledSources.first { $0.id == entry.online?.entry.sourceID }
        guard client != nil || source != nil else { return }
        returnSelection = "history"
        playback.resumeHistory(entry, client: client, source: source)
        selection = "playing"
    }

    private func returnToOnlinePlayback(_ recent: OnlineResume, source: OnlineSource) -> some View {
        HStack(spacing: 14) {
            Button {
                returnSelection = selection
                playback.resumeOnline(source: source)
                selection = "playing"
            } label: {
                HStack(spacing: 14) {
                    PosterView(item: recent.entry.media, client: nil).frame(width: 88, height: 50).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recent.entry.media.Name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text("上次看到 " + PlaybackTime.label(recent.position)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("继续观看", systemImage: "play.fill").foregroundStyle(Theme.accent)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { playback.clearRecent() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起续播卡片")
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 24).padding(.top, 14)
    }

    private func returnToPlayback(_ recent: RecentPlayback, client: EmbyClient) -> some View {
        HStack(spacing: 14) {
            Button {
                returnSelection = selection
                playback.resumeRecent(client: client)
                selection = "playing"
            } label: {
                HStack(spacing: 14) {
                    PosterView(item: recent.item, client: client, backdrop: true)
                        .frame(width: 88, height: 50).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recent.item.Name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text("上次看到 " + PlaybackTime.label(recent.position) + " / " + PlaybackTime.label(recent.duration))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("继续观看", systemImage: "play.fill").font(.callout.weight(.medium)).foregroundStyle(Theme.accent)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("继续观看：" + recent.item.Name)
            Button { playback.clearRecent() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("收起续播卡片")
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 0.5) }
            .padding(.horizontal, 24).padding(.top, 14)
    }

    private func browseSource(_ source: SavedMediaSource, destination: String) {
        online.selectedID = nil
        pendingSelection = destination
        connection.selectSource(source.id)
    }

    private func openAggregated(_ item: MediaItem, source: SavedMediaSource, library: LibraryStore, client: EmbyClient) {
        startupOpenPending = false
        if item.isContainer {
            pendingFolder = item
            browseSource(source, destination: "home")
        } else { detail = MediaSelection(item: item, client: client, library: library) }
    }

    private func navigationRow(_ title: String, icon: String, value: String) -> some View {
        Button { navigate(value) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 19)).frame(width: 24)
                Text(title).font(.system(size: 14)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selection == value ? Theme.accent : Color.primary)
            .padding(.horizontal, 12).frame(height: 44)
            .background(selection == value ? Theme.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).stroke(selection == value ? Theme.accent.opacity(0.18) : .clear, lineWidth: 0.5) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selection == value ? .isSelected : [])
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            if !sidebarVisible { Button { sidebarVisible = true } label: { Image(systemName: "sidebar.left") }.help("显示侧栏") }
            if !library.path.isEmpty, selection != "playing" {
                Button { library.path.removeLast() } label: { Image(systemName: "chevron.left") }.help("返回上一级")
            }
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            Text(online.selectedSource?.name ?? connection.selectedSource?.name ?? "全部媒体源").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let error = connection.error {
                Label("媒体源提示", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.accent).help(error)
            }
            if selection != "playing", let error = playback.syncError {
                Label("进度待同步", systemImage: "exclamationmark.icloud").font(.caption).help(error)
            }
            if !["playing", "sites", "history", "website"].contains(selection) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(selection == "favorites" ? "搜索收藏" : "搜索电影、剧集", text: $search).textFieldStyle(.plain).focused($searchFocused)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.help("清除搜索") }
                }.padding(9).frame(width: 220).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                Button { refreshRevision += 1; Task {
                    if library.filterIndex != nil, let client = connection.client { await library.prepareFilters(client: client, selection: selection, force: true, search: query) }
                    await refresh()
                } } label: { Image(systemName: "arrow.clockwise") }.help("刷新媒体库")
            }
            Menu {
                Picker("外观", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode.rawValue) }
                }
                Divider()
                Toggle("动态毛玻璃背景", isOn: $ambientMotion)
            } label: {
                Image(systemName: "circle.lefthalf.filled").frame(width: 28, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("外观与动态背景").accessibilityLabel("外观与动态背景")
            if sidebarVisible {
                Button { sidebarVisible = false } label: { Label("收起侧栏", systemImage: "sidebar.left") }
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain).padding(.horizontal, 22).frame(height: 58).padding(.leading, sidebarVisible ? 0 : 70)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }

    private func openItem(_ item: MediaItem) {
        startupOpenPending = false
        if item.isContainer {
            if !search.isEmpty { library.path = [] }
            search = ""
            library.path.append(item)
        }
        else if let client = connection.client { detail = MediaSelection(item: item, client: client, library: library) }
    }

    private func navigate(_ destination: String) {
        startupOpenPending = false
        if selection == "playing", destination != "playing" { stopPlayback() }
        if destination != selection, destination != "playing" { library.resetBrowsing() }
        library.path = []
        search = ""
        selection = destination
        searchFocused = destination == "search"
    }

    private func stopPlayback() {
        playback.endPlayback()
        playerWindow.showingOptions = false
        playerWindow.isWindowFullScreen = false
        playerWindow.exitFullScreen()
    }

    private func exitPlayback() {
        stopPlayback()
        selection = returnSelection
    }

    private func refresh() async {
        guard let client = connection.client else { return }
        await library.refresh(client: client, selection: selection, search: search)
    }
}
