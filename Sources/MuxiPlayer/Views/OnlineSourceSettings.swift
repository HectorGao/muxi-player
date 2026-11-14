import SwiftUI
import MuxiCore

struct OnlineSourceSettings: View {
    @Bindable var store: OnlineLibraryStore
    @ViewState private var name = ""
    @ViewState private var address = ""
    @ViewState private var subscription = ""
    @ViewState private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("公开与采集源").font(.headline)
            ForEach(store.sources) { source in
                HStack(spacing: 12) {
                    Toggle(source.name, isOn: Binding(get: { source.enabled }, set: { enabled in
                        var updated = store.sources
                        guard let index = updated.firstIndex(where: { $0.id == source.id }) else { return }
                        updated[index].enabled = enabled
                        Task { await store.saveSources(updated) }
                    })).toggleStyle(.checkbox)
                    Spacer()
                    if let health = store.health[source.id] {
                        Text(health.error ?? health.milliseconds.map { "\($0) ms" } ?? "")
                            .font(.caption).foregroundStyle(health.error == nil ? Color.secondary : Theme.accent)
                    }
                    Button("测活") { Task { await store.probe(source) } }
                    if !source.isDefault {
                        Button("移除", role: .destructive) { Task { await store.saveSources(store.sources.filter { $0.id != source.id }) } }
                    }
                }.padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            Divider()
            Text("添加苹果 CMS 接口").font(.callout.weight(.medium))
            HStack {
                TextField("名称", text: $name).frame(width: 140)
                TextField("https://…/api.php/provide/vod", text: $address)
                Button("添加") {
                    Task { await store.add(name: name, address: address); if store.error == nil { name = ""; address = "" } }
                }.disabled(address.isEmpty)
            }.textFieldStyle(.roundedBorder)
            HStack {
                TextField("LibreTV 源列表或 TVBox JSON 订阅地址", text: $subscription).textFieldStyle(.roundedBorder)
                Button(importing ? "正在导入…" : "导入订阅") {
                    importing = true
                    Task { await store.importSubscription(subscription); importing = false }
                }.disabled(subscription.isEmpty || importing)
            }
            Text("默认公开源可随时关闭。采集接口独立测活，失败后暂缓搜索并自动恢复。接口配置保存在钥匙串。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.disabled(store.saving || !store.ready)
            .task { await store.restore() }
    }
}
