import SwiftUI
import MuxiCore

struct SourceManagerView: View {
    @Bindable var connection: ConnectionStore
    let playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @ViewState private var adding = false
    @ViewState private var editing: SavedMediaSource?
    @ViewState private var removing: SavedMediaSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("媒体源").font(.title2.weight(.semibold))
                Spacer()
                Button("添加媒体源") { connection.error = nil; adding = true }.buttonStyle(.borderedProminent)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("保存一次，下次自动连接。全部媒体源可以一起浏览、搜索和查看收藏。")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(connection.sources) { source in
                        HStack(spacing: 14) {
                            Image(systemName: "externaldrive.connected.to.line.below").font(.title2).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.name).font(.headline)
                                Text("\((source.connection.serverKind ?? .emby).label) · \(source.connection.user.Name)").font(.caption)
                                Text(source.connection.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("更新登录") { connection.error = nil; editing = source }
                            Button("移除", role: .destructive) { removing = source }
                        }.padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            if connection.sources.isEmpty { Text("还没有媒体源，添加后即可建立私人影视库。").foregroundStyle(.secondary) }
            if let error = connection.error { Text(error).foregroundStyle(.red).font(.callout) }
        }.padding(26).frame(width: 660, height: 480).disabled(connection.connecting)
            .sheet(isPresented: $adding) {
                ConnectView(connection: connection, saved: { adding = false }, cancel: { adding = false }).frame(width: 960, height: 760)
            }
            .sheet(item: $editing) { source in
                ConnectView(connection: connection, source: source, saved: { editing = nil }, cancel: { editing = nil }).frame(width: 960, height: 760)
            }
            .alert("移除媒体源？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("取消", role: .cancel) { removing = nil }
                Button("移除", role: .destructive) {
                    guard let source = removing else { return }
                    removing = nil
                    Task { await playback.stop(); await connection.remove(source) }
                }
            } message: { Text("只移除本机保存的连接，不删除服务器上的影片、收藏或播放记录。") }
    }
}
