import SwiftUI
import MuxiCore

struct ViewingSitesView: View {
    @Bindable var store: ViewingSiteStore
    let open: (ViewingSite) -> Void
    let manageSources: () -> Void
    @ViewState private var adding = false
    @ViewState private var editing: ViewingSite?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("优选站点").font(.title2.weight(.semibold))
                    Spacer()
                    Button("添加站点") { store.error = nil; adding = true }.disabled(!store.ready)
                    Button("管理媒体源", action: manageSources)
                    Button(store.checking ? "正在检测…" : "立即检测") { Task { await store.check() } }.disabled(store.checking)
                }
                Toggle("启动时自动打开最快观影网站", isOn: $store.autoOpenFastest).toggleStyle(.checkbox)
                Text("每次启动检测一次，也可手动检查。测速包含页面或接口响应，实际播放速度取决于媒体线路。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = store.error { Text(error).font(.callout).foregroundStyle(.red) }
                if !store.ready { Button("重新读取站点配置") { Task { await store.restore() } } }
                ForEach(store.sortedSites.filter { $0.kind != .reference }) { site in siteRow(site) }
                Text("公益服与项目入口").font(.headline).padding(.top, 10)
                ForEach(store.savedSites.filter { $0.kind == .reference }) { site in siteRow(site) }
                HStack {
                    Button(store.clearingCache ? "正在清理…" : "清理网页缓存") { Task { await store.clearCache() } }.disabled(store.clearingCache)
                    if let date = store.lastCacheClear { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                }.padding(.top, 10)
                Text("每三次启动自动清理网页磁盘与内存缓存。站点登录、收藏和观影记录继续保存在本机。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }
        .sheet(isPresented: $adding) { SiteEditorView(store: store) }
        .sheet(item: $editing) { SiteEditorView(store: store, existing: $0) }
    }

    private func siteRow(_ site: ViewingSite) -> some View {
        let result = store.health[site.id] ?? SiteHealth()
        let saved = store.savedSites.contains { $0.id == site.id }
        return HStack(spacing: 14) {
            Image(systemName: site.kind == .web ? "play.rectangle" : "network").font(.title2).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(site.name).font(.headline)
                    Text(site.kind.label).font(.caption).foregroundStyle(.secondary)
                    if !site.enabled { Text("已关闭").font(.caption).foregroundStyle(.secondary) }
                }
                Text(site.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                if !site.note.isEmpty { Text(site.note).font(.caption).foregroundStyle(.secondary) }
                if site.kind != .reference {
                    HStack(spacing: 8) {
                        Text(result.status.label).foregroundStyle(result.status == .online ? Color.green : Color.secondary)
                        if let ms = result.milliseconds, result.status == .online { Text("\(ms) ms").monospacedDigit() }
                        if result.failures > 0 { Text("连续失败 \(result.failures) 次") }
                        if let date = result.checkedAt { Text(date, style: .time) }
                    }.font(.caption)
                    if let message = result.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 8)
            Button(site.kind == .cms || site.kind == .archive ? "浏览" : "打开") { open(site) }.disabled(!site.enabled)
            Menu {
                if site.monitored { Button("检测此站") { Task { await store.check(site) } }.disabled(store.checking) }
                if site.kind == .emby || site.kind == .jellyfin {
                    Button("网页访问") { open(ViewingSite(name: site.name, url: site.url)) }
                }
                if saved {
                    Button(site.enabled ? "关闭" : "启用") {
                        var updated = store.savedSites
                        if let index = updated.firstIndex(where: { $0.id == site.id }) { updated[index].enabled.toggle() }
                        Task { await store.save(updated) }
                    }
                    Button("编辑") { store.error = nil; editing = site }
                    if !site.isDefault {
                        Button("移除", role: .destructive) { Task { await store.save(store.savedSites.filter { $0.id != site.id }) } }
                    }
                }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).help("站点操作")
                .disabled(store.saving || (saved && !store.ready))
        }.padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)).opacity(site.enabled ? 1 : 0.6)
    }
}

private struct SiteEditorView: View {
    @Bindable var store: ViewingSiteStore
    var existing: ViewingSite?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var address = ""
    @ViewState private var kind = ViewingSite.Kind.web

    var body: some View {
        Form {
            Text(existing == nil ? "添加观影站点" : "编辑站点").font(.title2)
            TextField("名称", text: $name)
            TextField("HTTP / HTTPS 地址", text: $address)
            Picker("类型", selection: $kind) {
                ForEach([ViewingSite.Kind.web, .emby, .jellyfin, .reference], id: \.self) { Text($0.label).tag($0) }
            }
            Text("LibreTV、MoonTV 和其他影视网页使用“观影网站”。资讯与开通入口独立显示。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { Task {
                    if await store.upsert(existing, name: name, address: address, kind: kind) { dismiss() }
                } }.keyboardShortcut(.defaultAction).disabled(address.isEmpty || store.saving)
            }
        }.formStyle(.grouped).frame(width: 520, height: 340)
            .onAppear { if let existing { name = existing.name; address = existing.url.absoluteString; kind = existing.kind } }
    }
}
