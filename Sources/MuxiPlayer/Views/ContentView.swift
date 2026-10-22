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
        if selection == "playing" { return playback.item?.Name ?? "现在观看" }
        if !query.isEmpty { return "搜索结果" }
        if let folder = library.path.last { return folder.Name }
        switch selection {
        case "playing": return playback.item?.Name ?? "现在观看"
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
            } else if !connection.sources.isEmpty {
                HStack(spacing: 0) {
                    if sidebarVisible && !immersive { sidebar.frame(width: 210) }
                    VStack(spacing: 0) {
                        if !immersive { toolbar }
                        if selection == "playing" {
                            PlayerView(playback: playback, window: playerWindow, exit: exitPlayback)
                        } else if let client = connection.client {
                            LibraryView(library: library, client: client, title: title, selection: selection, searching: !query.isEmpty,
                                        showHome: selection == "home" && library.path.isEmpty && query.isEmpty,
                                        open: openItem, navigate: navigate, more: { Task { await library.more(client: client, selection: selection, search: search) } },
                                        retry: { Task { await refresh() } })
                                .id("\(selection)|\(library.path.last?.id ?? "")")
                        } else {
                            AggregatedLibraryView(connection: connection, selection: selection, search: query,
                                                  playbackRevision: playback.revision + refreshRevision, open: openAggregated, browse: browseSource)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background {
                    if let client = connection.client {
                    TidalBackdrop(items: Array((library.recommendations.isEmpty ? library.libraries : library.recommendations).prefix(8)),
                                  client: client, active: selection != "playing" && !playback.isPlaying)
                    } else { Theme.canvas }
                }
                .task(id: [AnyHashable(selection), AnyHashable(search), AnyHashable(library.path.last?.id), AnyHashable(playback.revision), AnyHashable(library.filter), AnyHashable(connection.selectedSourceID), AnyHashable(connection.revision)]) {
                    if selection != "playing" { await refresh() }
                }
            } else {
                ConnectView(connection: connection)
            }
        }
        .background(PlayerWindowReader(state: playerWindow).frame(width: 0, height: 0))
        .focusedSceneValue(\.playerWindow, playerWindow)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $managingSources) { SourceManagerView(connection: connection, playback: playback) }
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
        .onChange(of: connection.revision) { _, _ in
            stopPlayback(); detail = nil; library = LibraryStore(); selection = "home"; search = ""
        }
        .onChange(of: playback.revision) { _, _ in library.invalidateIndex() }
        .onChange(of: playback.item?.id) { _, id in
            if id == nil, selection == "playing" {
                playerWindow.showingOptions = false
                playerWindow.isWindowFullScreen = false
                playerWindow.exitFullScreen()
                selection = returnSelection
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("muxi").font(.system(size: 36, weight: .semibold, design: .rounded)).tracking(-1.5)
                Text("幕汐").font(.caption).tracking(4).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.top, 48).padding(.bottom, 28)
            VStack(spacing: 4) {
                navigationRow("媒体墙", icon: "square.grid.2x2", value: "home")
                navigationRow("搜索", icon: "magnifyingglass", value: "search")
                navigationRow("为你推荐", icon: "sparkles", value: "recommendations")
                navigationRow("我的收藏", icon: "heart", value: "favorites")
                navigationRow("现在观看", icon: "play.fill", value: "playing")
                navigationRow("电影", icon: "film", value: "movies")
                navigationRow("剧集", icon: "tv", value: "series")
            }.padding(.horizontal, 10)
            Text("媒体源").font(.caption).foregroundStyle(.secondary).padding(.leading, 22).padding(.top, 22).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 4) {
                    sourceRow("全部媒体源", icon: "square.stack.3d.up", id: nil)
                    ForEach(connection.sources) { source in sourceRow(source.name, icon: "externaldrive", id: source.id) }
                }.padding(.horizontal, 10)
            }.frame(maxHeight: 150)
            if connection.client != nil, !library.libraries.isEmpty {
                Text("我的媒体库").font(.caption).foregroundStyle(.secondary).padding(.leading, 22).padding(.top, 30).padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(library.libraries) { item in
                            navigationRow(item.Name, icon: "folder", value: "library:" + item.id)
                        }
                    }.padding(.horizontal, 10)
                }
            }
            Spacer(minLength: 20)
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

    private func sourceRow(_ name: String, icon: String, id: UUID?) -> some View {
        Button { connection.selectSource(id) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 22)
                Text(name).lineLimit(1)
                Spacer()
                if connection.selectedSourceID == id { Image(systemName: "checkmark").font(.caption) }
            }.font(.callout).padding(10).contentShape(Rectangle())
                .foregroundStyle(connection.selectedSourceID == id ? Theme.accent : .primary)
                .background(connection.selectedSourceID == id ? Theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private func browseSource(_ source: SavedMediaSource, destination: String) {
        pendingSelection = destination
        connection.selectSource(source.id)
    }

    private func openAggregated(_ item: MediaItem, source: SavedMediaSource, library: LibraryStore, client: EmbyClient) {
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
            Text(connection.selectedSource?.name ?? "全部媒体源").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if let error = connection.error {
                Label("媒体源提示", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.accent).help(error)
            }
            if selection != "playing", let error = playback.syncError {
                Label("进度待同步", systemImage: "exclamationmark.icloud").font(.caption).help(error)
            }
            if selection != "playing" {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(selection == "favorites" ? "搜索收藏" : "搜索电影、剧集", text: $search).textFieldStyle(.plain).focused($searchFocused)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.help("清除搜索") }
                }.padding(9).frame(width: 220).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                Button { refreshRevision += 1; library.invalidateIndex(); Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("刷新媒体库")
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
        if item.isContainer {
            if !search.isEmpty { library.path = [] }
            search = ""
            library.path.append(item)
        }
        else if let client = connection.client { detail = MediaSelection(item: item, client: client, library: library) }
    }

    private func navigate(_ destination: String) {
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
