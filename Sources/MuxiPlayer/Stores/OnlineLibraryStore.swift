import Foundation
import Observation
import CryptoKit
import MuxiCore

@MainActor @Observable final class OnlineLibraryStore {
    struct State {
        var items: [OnlineItem] = []
        var loading = false
        var error: String?
        var total = 0
        var page = 0
        var hasMore = false
        var fromCache = false
        var checkedAt: Date?
    }
    private struct Entry: Codable {
        var items: [OnlineItem]
        var total: Int
        var page: Int
        var hasMore: Bool
        var checkedAt: Date
        var reconciledAt: Date?
    }
    struct Health {
        var failures = 0
        var retryAt = Date.distantPast
        var milliseconds: Int?
        var error: String?
    }

    static let shared = OnlineLibraryStore()
    private(set) var sources = OnlineSource.defaults
    private(set) var states: [String: State] = [:]
    private(set) var health: [UUID: Health] = [:]
    private(set) var favorites: [OnlineItem]
    private(set) var ready = false
    var selectedID: UUID?
    var error: String?
    var saving = false
    @ObservationIgnored private let client: OnlineCatalogClient
    @ObservationIgnored private let credentials: CredentialStore
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var requests = Set<String>()

    init(client: OnlineCatalogClient = OnlineCatalogClient(), credentials: CredentialStore = CredentialStore(),
         directory: URL = URL.applicationSupportDirectory.appendingPathComponent("com.hectorgao.muxi-player/OnlineSearch-v1"),
         defaults: UserDefaults = .standard) {
        self.client = client; self.credentials = credentials; self.directory = directory; self.defaults = defaults
        favorites = defaults.data(forKey: "onlineFavorites").flatMap { try? JSONDecoder().decode([OnlineItem].self, from: $0) } ?? []
    }

    var enabledSources: [OnlineSource] { sources.filter(\.enabled) }
    var selectedSource: OnlineSource? { sources.first { $0.id == selectedID } }
    var backdropItems: [MediaItem] {
        let visible = selectedSource.map { [$0] } ?? enabledSources
        return visible.flatMap { state($0, search: "").items }.prefix(10).map(\.media)
    }

    func restore() async {
        guard !ready, !restoring else { return }
        restoring = true
        defer { restoring = false }
        do {
            if let saved = try await credentials.loadOnlineSources() {
                sources = OnlineSource.mergingDefaults(into: saved)
            }
            ready = true; error = nil
        } catch { self.error = "在线源配置暂未读取，原记录已保留。可继续浏览默认公开源。" }
    }

    private func key(_ source: OnlineSource, search: String) -> String {
        let value = [source.id.uuidString, source.url.absoluteString, source.collection ?? "", search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()].joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func state(_ source: OnlineSource, search: String) -> State { states[key(source, search: search)] ?? State() }

    func load(_ source: OnlineSource, search: String, force: Bool = false, more: Bool = false) async {
        let key = key(source, search: search)
        guard requests.insert(key).inserted else { return }
        var state = states[key] ?? State()
        var cached: Entry?
        if let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")) {
            cached = try? JSONDecoder().decode(Entry.self, from: data)
        }
        if let cached, state.items.isEmpty {
            state.items = cached.items; state.total = cached.total; state.page = cached.page
            state.hasMore = cached.hasMore; state.fromCache = true; state.checkedAt = cached.checkedAt
        }
        states[key] = state
        defer { requests.remove(key); states[key]?.loading = false }
        if !force, !more, let checked = state.checkedAt, Date().timeIntervalSince(checked) < 300 { return }
        if !force, let health = health[source.id], health.retryAt > Date() {
            states[key]?.error = "此源暂时休息，稍后自动恢复。可点击重试。"; return
        }
        states[key]?.loading = true; states[key]?.error = nil
        let start = Date()
        do {
            let reconciling = !more && cached != nil && start.timeIntervalSince(cached?.reconciledAt ?? .distantPast) >= 86_400
            let incremental = !more && cached != nil && !reconciling
            let since = incremental ? cached!.checkedAt.addingTimeInterval(-300) : nil
            var pageNumber = more ? state.page + 1 : 1
            var incoming: [OnlineItem] = []
            var page: OnlinePage
            repeat {
                page = try await client.page(source: source, search: search, page: pageNumber, since: since)
                try Task.checkCancellation()
                incoming.append(contentsOf: page.items)
                pageNumber += 1
                if incremental, page.hasMore, Date().timeIntervalSince(start) > 20 {
                    throw CatalogError("更新条目较多，已保留本机结果，请稍后继续同步。")
                }
            } while page.hasMore && (incremental || (reconciling && pageNumber <= max(1, state.page)))
            var merged = Dictionary(state.items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for item in incoming { merged[item.id] = item }
            let ordered = reconciling ? incoming : more ? state.items + incoming : incoming + state.items
            var seen = Set<String>()
            let unique = ordered.filter { seen.insert($0.id).inserted }.compactMap { merged[$0.id] }
            let entry = Entry(items: unique, total: incremental ? max(state.total, unique.count) : page.total,
                              page: more ? pageNumber - 1 : max(1, state.page),
                              hasMore: incremental ? state.hasMore : page.hasMore, checkedAt: more ? state.checkedAt ?? start : start,
                              reconciledAt: reconciling || cached == nil ? start : cached?.reconciledAt)
            var cacheError: String?
            do { try save(entry, key: key) } catch { cacheError = "本次结果已读取，本机缓存暂未写入。" }
            states[key] = State(items: entry.items, error: cacheError, total: entry.total, page: entry.page, hasMore: entry.hasMore,
                                fromCache: false, checkedAt: entry.checkedAt)
            health[source.id] = Health(milliseconds: Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            guard !Task.isCancelled else { return }
            let failure = error as NSError
            let message: String
            if let catalog = error as? CatalogError { message = catalog.localizedDescription }
            else if failure.domain == "kCFErrorDomainCFNetwork" {
                message = "系统代理连接失败，请检查代理连接后重试。"
            } else if failure.domain == NSURLErrorDomain {
                message = "连接超时或网络暂不可用，已保留本机结果。"
            } else { message = "接口数据暂时无法读取，已保留本机结果。" }
            states[key]?.error = message
            var health = health[source.id] ?? Health()
            health.failures += 1; health.error = "连接或数据格式异常"
            health.retryAt = Date().addingTimeInterval(min(1800, pow(2, Double(min(health.failures, 6))) * 15))
            self.health[source.id] = health
        }
    }

    func probe(_ source: OnlineSource) async {
        let start = Date()
        do {
            _ = try await client.page(source: source)
            health[source.id] = Health(milliseconds: Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            guard !Task.isCancelled else { return }
            health[source.id] = Health(failures: 1, retryAt: Date().addingTimeInterval(30), error: "接口测试失败")
        }
    }

    func saveSources(_ updated: [OnlineSource]) async {
        guard ready, !saving else { error = "请先允许读取媒体源配置，再重试保存。"; return }
        saving = true
        defer { saving = false }
        do {
            try await credentials.saveOnlineSources(updated)
            sources = updated; error = nil
            if !sources.contains(where: { $0.id == selectedID && $0.enabled }) { selectedID = nil }
        } catch { self.error = "媒体源修改未保存，已有配置已保留。" }
    }

    func add(name: String, address: String) async {
        do {
            let url = try OnlineCatalogClient.checkedURL(address)
            guard !sources.contains(where: { $0.url == url && $0.kind == .cms }) else { error = "这个接口已经添加。"; return }
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            await saveSources(sources + [OnlineSource(name: title.isEmpty ? url.host ?? "采集接口" : title, url: url)])
        } catch { self.error = error.localizedDescription }
    }

    func importSubscription(_ address: String) async {
        do {
            let incoming = try await client.subscription(address)
            let added = incoming.filter { candidate in !sources.contains { $0.url == candidate.url && $0.kind == .cms } }
            guard !added.isEmpty else { error = "订阅中的接口已全部添加。"; return }
            await saveSources(sources + added)
        } catch { self.error = "订阅导入失败，请检查地址和 JSON 格式。" }
    }

    func isFavorite(_ item: OnlineItem) -> Bool { favorites.contains { $0.id == item.id } }
    func toggleFavorite(_ item: OnlineItem) {
        if isFavorite(item) { favorites.removeAll { $0.id == item.id } }
        else { favorites.append(item) }
        if let data = try? JSONEncoder().encode(favorites) { defaults.set(data, forKey: "onlineFavorites") }
    }

    private func save(_ entry: Entry, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(key + ".json")
        try JSONEncoder().encode(entry).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
