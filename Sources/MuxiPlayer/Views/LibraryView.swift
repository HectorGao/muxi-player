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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.system(size: 32, weight: .medium, design: .serif)).tracking(1)
                        if showHome { Text("光影有幕，故事如汐。").font(.callout).foregroundStyle(.secondary) }
                        if selection == "recommendations", !searching { Text("从你的媒体库中，按评分优先挑选未看过的影片与剧集。").font(.callout).foregroundStyle(.secondary) }
                        if selection == "favorites", !searching, library.path.isEmpty { Text("收藏同步到当前服务器，喜欢的影片随时再见。").font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if !library.loading {
                        Text(showHome ? "\(library.libraries.count) 个媒体库" : library.totalCount.map { "\($0) 个项目" } ?? "")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
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
                    ContentUnavailableView(searching ? "没有找到影片" : selection == "favorites" ? "把喜欢的影片留在这里" : "这里还没有影片",
                                           systemImage: searching ? "magnifyingglass" : selection == "favorites" ? "heart" : "film",
                                           description: Text(searching ? "试试其他片名或关键词。" : selection == "favorites" ? "点击海报或详情中的爱心，收藏会同步到服务器。" : "请检查媒体库和账号访问权限。"))
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
