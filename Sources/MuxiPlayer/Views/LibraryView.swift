import SwiftUI
import MuxiCore

struct LibraryView: View {
    @Bindable var library: LibraryStore
    let client: EmbyClient
    let title: String
    let selection: String
    let searching: Bool
    let showHome: Bool
    let open: (MediaItem) -> Void
    let navigate: (String) -> Void
    let more: () -> Void
    let retry: () -> Void
    @ViewState private var showingFilters = false
    private var filtering: Bool { library.path.isEmpty && LibraryStore.canFilter(selection) && library.filter.isActive }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.system(size: 32, weight: .medium, design: .serif)).tracking(1)
                        if showHome { Text("你的私人影视库").font(.callout).foregroundStyle(.secondary) }
                        if selection == "recommendations", !searching { Text("从你的媒体库中，按评分优先挑选未看过的影片与剧集。").font(.callout).foregroundStyle(.secondary) }
                        if selection == "favorites", !searching, library.path.isEmpty { Text("收藏同步到当前服务器，喜欢的影片随时再见。").font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if !library.loading {
                        Text(showHome ? "\(library.libraries.count) 个媒体库" : library.totalCount.map { "\($0) 个项目" } ?? "")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if LibraryStore.canFilter(selection), library.path.isEmpty { browseControls }
                if let error = library.error { errorNotice(error, retry: retry) }
                if let error = library.favoriteError {
                    errorNotice(error) { library.favoriteError = nil }
                }
                if library.loading {
                    ProgressView("正在读取媒体库…").frame(maxWidth: .infinity).padding(60)
                } else if showHome {
                    homeWall
                } else if selection == "search", !searching, library.path.isEmpty {
                    ContentUnavailableView("搜索你的媒体库", systemImage: "magnifyingglass", description: Text("在上方输入片名、剧名或关键词。"))
                } else if library.items.isEmpty, library.error == nil {
                    ContentUnavailableView(searching || filtering ? "没有找到影片" : selection == "favorites" ? "把喜欢的影片留在这里" : "这里还没有影片",
                                           systemImage: searching ? "magnifyingglass" : selection == "favorites" ? "heart" : "film",
                                           description: Text(filtering ? "试试调整年份、类型、国家或观看状态。" : searching ? "试试其他片名或关键词。" : selection == "favorites" ? "点击海报或详情中的爱心，收藏会同步到服务器。" : "请检查媒体库和账号访问权限。"))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 185), spacing: 20)], alignment: .leading, spacing: 26) {
                        ForEach(library.items) { item in card(item) }
                    }
                }
                if library.hasMore {
                    HStack { Spacer(); Button(library.loadingMore ? "正在加载…" : "加载更多", action: more).disabled(library.loadingMore); Spacer() }.padding()
                }
            }.padding(30)
        }
    }

    private var browseControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Picker("排序", selection: $library.filter.sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.label).tag($0) }
                }.frame(width: 205)
                Button { showingFilters.toggle() } label: {
                    Label(library.filter.isActive ? "筛选 · 已启用" : "筛选", systemImage: "line.3.horizontal.decrease")
                }.tint(library.filter.isActive ? Theme.accent : nil)
                if library.filter.isActive {
                    Button("清除筛选") {
                        let sort = library.filter.sort
                        library.filter = LibraryFilter(); library.filter.sort = sort
                    }
                }
                Spacer()
            }
            if showingFilters {
                VStack(alignment: .leading, spacing: 14) {
                    if library.indexing {
                        HStack { ProgressView().controlSize(.small); Text("正在整理整个分类的筛选信息… 已读取 \(library.indexedCount) 项") }
                            .font(.callout)
                    } else if let error = library.indexError {
                        errorNotice(error) { Task { await library.prepareFilters(client: client, selection: selection) } }
                    } else if let index = library.filterIndex {
                        HStack(spacing: 16) {
                            Picker("年份", selection: $library.filter.year) {
                                Text("全部年份").tag(Int?.none)
                                ForEach(Array(Set(index.compactMap(\.ProductionYear))).sorted(by: >), id: \.self) { Text(String($0)).tag(Optional($0)) }
                            }
                            Picker("类型", selection: $library.filter.genre) {
                                Text("全部类型").tag(String?.none)
                                ForEach(Array(Set(index.flatMap { $0.Genres ?? [] })).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
                            }
                        }
                        HStack(spacing: 16) {
                            Picker("国家 / 地区", selection: $library.filter.country) {
                                Text("全部国家 / 地区").tag(String?.none)
                                ForEach(Array(Set(index.flatMap { $0.ProductionLocations ?? [] })).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
                                if index.contains(where: { ($0.ProductionLocations ?? []).isEmpty }) { Text("未标注").tag(Optional("")) }
                            }
                            Picker("观看状态", selection: $library.filter.played) {
                                Text("全部").tag(Bool?.none)
                                Text("未观看").tag(Optional(false))
                                Text("已观看").tag(Optional(true))
                            }
                        }
                        Text("已整理 \(index.count) 项。按服务器提供的年份、类型与国家筛选；缺失信息列为未标注，不推测影片产地。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("重新读取筛选信息") { Task { await library.prepareFilters(client: client, selection: selection) } }
                    }
                }.padding(18).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .task { await library.prepareFilters(client: client, selection: selection) }
            }
        }
    }

    private var homeWall: some View {
        Group {
            if !library.libraries.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("我的媒体库").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 14) {
                            ForEach(library.libraries) { item in
                                Button { navigate("library:" + item.id) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        PosterView(item: item, client: client, backdrop: true)
                                            .frame(width: 164, height: 86).clipShape(RoundedRectangle(cornerRadius: 13))
                                            .overlay { RoundedRectangle(cornerRadius: 13).stroke(Theme.border, lineWidth: 0.5) }
                                        Text(item.Name).font(.callout.weight(.medium)).lineLimit(1)
                                    }.frame(width: 164, alignment: .leading)
                                }.buttonStyle(.plain).accessibilityLabel("打开媒体库：" + item.Name)
                            }
                        }.padding(.bottom, 8)
                    }.scrollIndicators(.hidden)
                }
            }
            if !library.resume.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeading("继续观看", subtitle: "接着上次的故事")
                    if library.resume.count == 1, let item = library.resume.first {
                        resumeFeature(item)
                    } else { mediaRow(library.resume, landscape: true) }
                }.padding(20).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                    .overlay { RoundedRectangle(cornerRadius: 22).stroke(Theme.border, lineWidth: 0.5) }
            }
            if !library.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeading("为你推荐", subtitle: "未看过的高分影片与剧集", destination: "recommendations")
                    mediaRow(library.recommendations)
                }
            }
            ForEach(library.libraries) { collection in
                VStack(alignment: .leading, spacing: 16) {
                    sectionHeading(collection.Name, subtitle: "最近入库", destination: "library:" + collection.id,
                                   count: library.shelves[collection.id]?.totalCount)
                    if let shelf = library.shelves[collection.id] {
                        if let error = shelf.error {
                            errorNotice(error) { Task { await library.retryShelf(collection, client: client) } }
                        } else if shelf.loading { ProgressView().frame(height: 160, alignment: .center) }
                        else if shelf.items.isEmpty { Text("这个媒体库还没有项目。").foregroundStyle(.secondary).padding(.vertical, 20) }
                        else { mediaRow(shelf.items) }
                    } else { ProgressView().frame(height: 160) }
                }.task(id: library.refreshID) { await library.loadShelf(collection, client: client) }
            }
        }.scrollIndicators(.hidden)
    }

    private func sectionHeading(_ title: String, subtitle: String, destination: String? = nil, count: Int? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let destination {
                Button { navigate(destination) } label: {
                    HStack(spacing: 5) { Text(count.map { "查看全部 \($0)" } ?? "查看全部"); Image(systemName: "chevron.right") }
                        .font(.callout).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain).accessibilityLabel("查看全部" + title)
            }
        }
    }

    private func resumeFeature(_ item: MediaItem) -> some View {
        HStack(spacing: 24) {
            Button { open(item) } label: {
                PosterView(item: item, client: client, backdrop: true)
                    .frame(width: 240, height: 135).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottom) {
                        ProgressView(value: min(item.UserData?.PlayedPercentage ?? 0, 100), total: 100)
                            .tint(.white).padding(10).background(.black.opacity(0.4))
                            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
                    }
            }.buttonStyle(.plain).accessibilityLabel("打开影片：" + item.Name)
            VStack(alignment: .leading, spacing: 10) {
                Text(item.Name).font(.title2.weight(.medium)).lineLimit(1)
                Text(item.subtitle + " · 已看 " + PlaybackTime.label(Double(item.resumeTicks) / 10_000_000))
                    .font(.caption).foregroundStyle(.secondary)
                if let overview = item.Overview, !overview.isEmpty {
                    Text(overview).font(.callout).foregroundStyle(.secondary).lineLimit(2).lineSpacing(3)
                }
                HStack(spacing: 18) {
                    Button { open(item) } label: { Label("打开影片", systemImage: "play.fill") }.buttonStyle(.bordered)
                    FavoriteButton(item: item, client: client, library: library)
                }
            }.frame(maxWidth: 660, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private func mediaRow(_ items: [MediaItem], landscape: Bool = false) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 18) {
                ForEach(items) { item in card(item, landscape: landscape).frame(width: landscape ? 256 : 154) }
            }.padding(3).padding(.bottom, 8)
        }
    }

    private func card(_ item: MediaItem, landscape: Bool = false) -> some View {
        MediaCard(item: item, client: client, library: library, landscape: landscape, open: open)
    }

    private func errorNotice(_ text: String, retry: @escaping () -> Void) -> some View {
        HStack { Label(text, systemImage: "exclamationmark.triangle"); Spacer(); Button(library.favoriteError == text ? "关闭" : "重试", action: retry) }
            .font(.callout).padding().background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
