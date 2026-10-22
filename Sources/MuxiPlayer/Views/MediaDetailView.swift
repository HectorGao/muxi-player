import SwiftUI
import MuxiCore

struct MediaDetailView: View {
    let item: MediaItem
    let client: EmbyClient
    let library: LibraryStore
    let play: (MediaItem, Bool, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var sources: [MediaSource] = []
    @ViewState private var selectedSource: String?
    @ViewState private var detecting = true
    @ViewState private var fresh: MediaItem?
    @ViewState private var error: String?

    var body: some View {
        let shown = fresh ?? item
        VStack(alignment: .leading, spacing: 22) {
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            HStack(alignment: .top, spacing: 28) {
                PosterView(item: shown, client: client).frame(width: 180, height: 270).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 16) {
                    Text(shown.Name).font(.title.weight(.semibold))
                    Text(shown.subtitle).foregroundStyle(.secondary)
                    if let rating = shown.CommunityRating { Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(Theme.accent) }
                    ScrollView { Text(shown.Overview ?? "暂无简介").frame(maxWidth: .infinity, alignment: .leading).lineSpacing(5) }.frame(maxHeight: 150)
                    if detecting { ProgressView("正在识别片源、编码和轨道…").font(.caption) }
                    if !sources.isEmpty {
                        Picker("片源版本", selection: $selectedSource) {
                            ForEach(sources) { source in Text(source.playbackLabel).tag(Optional(source.Id)) }
                        }
                        if let source = sources.first(where: { $0.Id == selectedSource }) {
                            let streams = source.MediaStreams ?? []
                            let video = streams.first { $0.Type == "Video" }
                            Text([source.Container?.uppercased(), video?.Codec?.uppercased(), video?.Height.map { "\($0)p" },
                                  "\(streams.filter { $0.Type == "Audio" }.count) 条音轨", "\(streams.filter { $0.Type == "Subtitle" }.count) 条字幕"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("播放内核：libmpv · 本机解码").font(.caption).foregroundStyle(Theme.accent)
                        }
                    }
                    HStack {
                        Button { play(shown, false, selectedSource) } label: { Label(shown.resumeTicks > 0 ? "继续播放" : "播放", systemImage: "play.fill") }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        if shown.resumeTicks > 0 { Button("从头播放") { play(shown, true, selectedSource) } }
                        FavoriteButton(item: shown, client: client, library: library).padding(.leading, 8)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if let error = library.favoriteError { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(28).frame(width: 740).tint(Theme.accent)
            .task {
                do { fresh = try await client.item(id: item.id) } catch { self.error = "详情更新失败，将使用媒体库中已加载的信息。" }
                do { sources = try await client.mediaSources(itemID: item.id, engine: .mpv); selectedSource = sources.first?.Id }
                catch { self.error = "片源信息暂不可用，播放时将重新获取：" + EmbyError.message(error) }
                detecting = false
            }
    }
}
