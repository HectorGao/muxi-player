import Foundation
import Observation
import WebKit
import MuxiCore

struct WebsiteVisit: Codable, Identifiable {
    let id: UUID
    var title: String
    let url: URL
    var visitedAt: Date
}

@MainActor @Observable final class ViewingSiteStore {
    static let shared = ViewingSiteStore()
    private(set) var savedSites = ViewingSite.defaults
    private(set) var health: [UUID: SiteHealth]
    private(set) var visits: [WebsiteVisit]
    private(set) var ready = false
    private(set) var checking = false
    private(set) var saving = false
    private(set) var clearingCache = false
    private(set) var lastCacheClear: Date?
    private(set) var startupSite: ViewingSite?
    private(set) var syncedSites: [ViewingSite] = []
    var error: String?
    var autoOpenFastest: Bool { didSet { defaults.set(autoOpenFastest, forKey: "autoOpenFastestSite") } }
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let probe: SiteProbe
    @ObservationIgnored private var started = false
    @ObservationIgnored private var restoring = false

    init(credentials: CredentialStore = CredentialStore(), defaults: UserDefaults = .standard, probe: SiteProbe = SiteProbe()) {
        self.credentials = credentials; self.defaults = defaults; self.probe = probe
        health = defaults.data(forKey: "viewingSiteHealth").flatMap { try? JSONDecoder().decode([UUID: SiteHealth].self, from: $0) } ?? [:]
        visits = defaults.data(forKey: "websiteVisits").flatMap { try? JSONDecoder().decode([WebsiteVisit].self, from: $0) } ?? []
        autoOpenFastest = defaults.bool(forKey: "autoOpenFastestSite")
        lastCacheClear = defaults.object(forKey: "websiteCacheClearedAt") as? Date
    }

    var allSites: [ViewingSite] { savedSites + syncedSites }
    var sortedSites: [ViewingSite] { SiteHealth.sorted(allSites, health: health) }

    func restore() async {
        guard !ready, !restoring else { return }
        restoring = true
        defer { restoring = false }
        do {
            if let saved = try await credentials.loadViewingSites() { savedSites = ViewingSite.mergingDefaults(into: saved) }
            ready = true; error = nil
        } catch { self.error = "站点配置暂未读取，原记录已保留。请允许钥匙串访问后重试。" }
    }

    func synchronize(online: [OnlineSource], servers: [SavedMediaSource]) {
        let previous = Dictionary(allSites.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        syncedSites = online.map {
            ViewingSite(id: $0.id, name: $0.name, url: $0.url, kind: $0.kind == .cms ? .cms : .archive,
                        enabled: $0.enabled, isDefault: $0.isDefault, note: "在管理媒体源中编辑", collection: $0.collection)
        } + servers.map {
            ViewingSite(id: $0.id, name: $0.name, url: $0.connection.baseURL,
                        kind: ($0.connection.serverKind ?? .emby) == .emby ? .emby : .jellyfin, note: "已保存的媒体库")
        }
        for site in allSites where previous[site.id]?.url != site.url || previous[site.id]?.kind != site.kind { health[site.id] = nil }
    }

    func start(online: [OnlineSource], servers: [SavedMediaSource]) async {
        guard !started else { return }
        started = true
        let shouldAutoOpen = autoOpenFastest
        await restore()
        synchronize(online: online, servers: servers)
        let launches = defaults.integer(forKey: "viewingSiteLaunches") + 1
        defaults.set(launches, forKey: "viewingSiteLaunches")
        if launches % 3 == 0 { await clearCache() }
        let startedChecking = Date()
        await check()
        if shouldAutoOpen && autoOpenFastest {
            startupSite = sortedSites.first {
                $0.canAutoOpen && health[$0.id]?.status == .online && (health[$0.id]?.checkedAt ?? .distantPast) >= startedChecking
            }
        }
    }

    func check(_ selected: ViewingSite? = nil) async {
        guard !checking else { return }
        let targets = (selected.map { [$0] } ?? allSites).filter(\.monitored)
        checking = true
        defer { checking = false }
        let probe = probe
        await withTaskGroup(of: (ViewingSite, SiteHealth?).self) { group in
            var iterator = targets.makeIterator()
            for _ in 0..<min(4, targets.count) {
                if let site = iterator.next() { group.addTask { (site, try? await probe.check(site)) } }
            }
            for await (site, result) in group {
                if let result, !Task.isCancelled, allSites.contains(where: { $0.id == site.id && $0.url == site.url && $0.kind == site.kind && $0.monitored }) {
                    health[site.id] = result.following(health[site.id])
                }
                if !Task.isCancelled, let next = iterator.next() { group.addTask { (next, try? await probe.check(next)) } }
            }
        }
        if let data = try? JSONEncoder().encode(health) { defaults.set(data, forKey: "viewingSiteHealth") }
    }

    func save(_ updated: [ViewingSite]) async {
        guard ready, !saving else { error = "请先读取站点配置，再重试保存。"; return }
        saving = true
        defer { saving = false }
        do {
            try await credentials.saveViewingSites(updated)
            for site in updated {
                let previous = savedSites.first { $0.id == site.id }
                if previous?.url != site.url || previous?.kind != site.kind { health[site.id] = nil }
            }
            savedSites = updated; error = nil
        } catch { self.error = "站点修改未保存，已有配置已保留。" }
    }

    func upsert(_ existing: ViewingSite?, name: String, address: String, kind: ViewingSite.Kind) async -> Bool {
        do {
            let url = try ViewingSite.checkedURL(address)
            if kind == .emby || kind == .jellyfin { _ = try ServerAddress.normalize(address) }
            guard !savedSites.contains(where: { $0.id != existing?.id && ViewingSite.addressKey($0.url) == ViewingSite.addressKey(url) }) else {
                error = "这个站点已经添加。"; return false
            }
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            var updated = savedSites
            let site = ViewingSite(id: existing?.id ?? UUID(), name: title.isEmpty ? url.host ?? "观影站点" : title, url: url,
                                   kind: kind, enabled: existing?.enabled ?? true, isDefault: existing?.isDefault ?? false, note: existing?.note ?? "")
            if let index = updated.firstIndex(where: { $0.id == site.id }) { updated[index] = site }
            else { updated.append(site) }
            await save(updated)
            return error == nil
        } catch { self.error = "请输入有效的 HTTP / HTTPS 站点地址，服务器地址须包含完整路径。"; return false }
    }

    func recordVisit(url: URL, title: String) {
        guard (try? ViewingSite.checkedURL(url.absoluteString)) != nil else { return }
        // Skip login redirects and signed URLs so browsing history cannot retain credentials.
        let keys = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
        guard !keys.contains(where: { ["token", "api_key", "apikey", "access_token", "password", "code", "signature", "auth", "key"].contains($0) }) else { return }
        let previous = visits.first { $0.url == url }
        visits.removeAll { $0.url == url }
        visits.insert(WebsiteVisit(id: previous?.id ?? UUID(), title: title.isEmpty ? url.host ?? "观影网页" : title,
                                   url: url, visitedAt: Date()), at: 0)
        visits = Array(visits.prefix(200))
        persistVisits()
    }

    func removeVisit(_ id: UUID) { visits.removeAll { $0.id == id }; persistVisits() }
    func clearVisits() { visits = []; persistVisits() }
    private func persistVisits() {
        if let data = try? JSONEncoder().encode(visits) { defaults.set(data, forKey: "websiteVisits") }
    }

    func clearCache() async {
        guard !clearingCache else { return }
        clearingCache = true
        await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast)
        URLCache.shared.removeAllCachedResponses()
        lastCacheClear = Date(); defaults.set(lastCacheClear, forKey: "websiteCacheClearedAt")
        clearingCache = false
    }
}
