import SwiftUI
import MuxiCore

struct ViewingHistoryView: View {
    @Bindable var sites: ViewingSiteStore
    @Bindable var playback: PlaybackController
    let connection: ConnectionStore
    let online: OnlineLibraryStore
    let openWebsite: (URL) -> Void
    let resume: (PlaybackHistoryEntry) -> Void
    @ViewState private var clearing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("观影记录").font(.title2.weight(.semibold))
                    Spacer()
                    Button("清空记录", role: .destructive) { clearing = true }.disabled(playback.history.isEmpty && sites.visits.isEmpty)
                }
                if playback.history.isEmpty && sites.visits.isEmpty {
                    ContentUnavailableView("还没有观影记录", systemImage: "clock", description: Text("打开观影网站或播放影片后，记录会保存在这里。"))
                }
                if !playback.history.isEmpty {
                    Text("影片与分集").font(.headline)
                    ForEach(playback.history) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.title).font(.headline)
                                Text((entry.online?.episodeName.map { $0 + " · " } ?? "") + "看到 " + PlaybackTime.label(entry.position))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(entry.watchedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if available(entry) { Button("继续观看") { resume(entry) } }
                            else { Text("媒体源待连接").font(.caption).foregroundStyle(.secondary) }
                            Button { playback.removeHistory(entry.id) } label: { Image(systemName: "xmark") }.help("移除此记录")
                        }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                if !sites.visits.isEmpty {
                    Text("网页浏览").font(.headline)
                    ForEach(sites.visits) { visit in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(visit.title).font(.headline).lineLimit(2)
                                Text(visit.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(visit.visitedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("重新打开") { openWebsite(visit.url) }
                            Button { sites.removeVisit(visit.id) } label: { Image(systemName: "xmark") }.help("移除此记录")
                        }.padding(14).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.padding(26)
        }.alert("清空本机观影记录？", isPresented: $clearing) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { playback.clearHistory(); sites.clearVisits() }
        } message: { Text("将清空此列表中的影片和网页记录。") }
    }

    private func available(_ entry: PlaybackHistoryEntry) -> Bool {
        if let recent = entry.recent { return connection.clients.values.contains { recent.belongs(to: $0) } }
        return online.enabledSources.contains { $0.id == entry.online?.entry.sourceID }
    }
}
