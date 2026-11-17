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
        var totalIsExact = true
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
        var partitions: [String: Partition]?
        var categories: [OnlineCategory]?
        var categoriesCheckedAt: Date?
        var totalIsExact: Bool?
    }
    private struct Partition: Codable {
        var page = 0
        var hasMore = true
        var total: Int?
        var checkedAt: Date?
        var reconciledAt: Date?
        var error: String?
        var itemIDs: [String]?
        var failedPage: Int?
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

    private func key(_ source: OnlineSource, search: String, scope: OnlineCatalogScope) -> String {
        var value = [source.id.uuidString, source.url.absoluteString, source.collection ?? "", search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()].joined(separator: "\n")
        if scope != .all { value += "\n" + scope.rawValue }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func state(_ source: OnlineSource, search: String, scope: OnlineCatalogScope = .all) -> State {
        states[key(source, search: search, scope: scope)] ?? State()
    }

    func load(_ source: OnlineSource, search: String, scope: OnlineCatalogScope = .all, force: Bool = false, more: Bool = false) async {
        let key = key(source, search: search, scope: scope)
        guard requests.insert(key).inserted else { return }
        var state = states[key] ?? State()
        var cached: Entry?
        if let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")) {
            cached = try? JSONDecoder().decode(Entry.self, from: data)
        }
        if let cached, state.items.isEmpty {
            state.items = cached.items; state.total = cached.total; state.page = cached.page
            state.hasMore = cached.hasMore; state.fromCache = true; state.checkedAt = cached.checkedAt
            state.totalIsExact = cached.totalIsExact ?? true
            if cached.partitions?.values.contains(where: { $0.error != nil }) == true { state.error = "部分分类尚未同步，可重试。" }
        }
        states[key] = state
        defer { requests.remove(key); states[key]?.loading = false }
        if !force, !more, state.error == nil, let checked = state.checkedAt, Date().timeIntervalSince(checked) < 300 { return }
        if more, !state.hasMore { return }
        if !force, let health = health[source.id], health.retryAt > Date() {
            states[key]?.error = "此源暂时休息，稍后自动恢复。可点击重试。"; return
        }
        states[key]?.loading = true; states[key]?.error = nil
        let start = Date()
        do {
            var categories = cached?.categories ?? []
            var categoriesCheckedAt = cached?.categoriesCheckedAt
            var categoryError: String?
            if source.kind == .cms, scope != .all,
               categories.isEmpty || start.timeIntervalSince(categoriesCheckedAt ?? .distantPast) >= 86_400 {
                do {
                    categories = try await client.categories(source: source)
                    categoriesCheckedAt = start
                } catch {
                    guard !categories.isEmpty else { throw error }
                    categoryError = "分类暂未更新，正在使用本机分类。可重试。"
                }
            }
            var ids = source.kind == .cms && scope != .all ? OnlineCategory.ids(for: scope, in: categories) : [""]
            if source.kind == .archive, scope == .series { ids = [] }
            if let restricted = URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value,
               scope != .all, !restricted.isEmpty {
                let allowed = Set(restricted.split(separator: ",").map(String.init))
                ids = ids.filter { allowed.contains($0) }
            }
            var partitions = cached?.partitions ?? [:]
            if scope == .all, let cached, partitions.isEmpty {
                partitions[""] = Partition(page: cached.page, hasMore: cached.hasMore, total: cached.total,
                                            checkedAt: cached.checkedAt, reconciledAt: cached.reconciledAt)
            }
            let failed = ids.filter { partitions[$0]?.error != nil }
            let requested = more ? ids.filter { partitions[$0]?.hasMore ?? true } : failed.isEmpty ? ids : failed
            let client = client
            var incoming: [OnlineItem] = []
            var reconciledAll = false
            // Each category owns a cursor; an incremental h query never advances it.
            await withTaskGroup(of: (String, Partition?, [OnlineItem], Bool, String?).self) { group in
                var remaining = requested.makeIterator()
                func enqueue(_ id: String) {
                    let previous = partitions[id] ?? Partition()
                    group.addTask {
                        do {
                            let paging = more || previous.failedPage != nil
                            let reconciling = !paging && start.timeIntervalSince(previous.reconciledAt ?? .distantPast) >= 86_400
                            let incremental = !paging && previous.checkedAt != nil && !reconciling
                            let since = incremental ? previous.checkedAt!.addingTimeInterval(-300) : nil
                            var number = paging ? previous.failedPage ?? previous.page + 1 : 1
                            var items: [OnlineItem] = []
                            var page: OnlinePage
                            repeat {
                                page = try await client.page(source: source, search: search, page: number, since: since,
                                                             categoryID: id.isEmpty ? nil : id, categories: categories)
                                try Task.checkCancellation()
                                items += page.items
                                number += 1
                                if incremental, page.hasMore, Date().timeIntervalSince(start) > 20 {
                                    throw CatalogError("更新条目较多，已保留本机结果，请稍后继续同步。")
                                }
                            } while page.hasMore && (incremental || (reconciling && number <= max(1, previous.page)))
                            var fullPage = page
                            if incremental {
                                fullPage = try await client.page(source: source, search: search, categoryID: id.isEmpty ? nil : id, categories: categories)
                                items += fullPage.items
                            }
                            let itemIDs = Set(items.map(\.id))
                            let partition = Partition(page: incremental ? previous.page : number - 1,
                                hasMore: incremental ? previous.hasMore : page.hasMore,
                                total: fullPage.totalIsExact ? fullPage.total : nil,
                                checkedAt: paging ? previous.checkedAt ?? start : start,
                                reconciledAt: reconciling || previous.checkedAt == nil ? start : previous.reconciledAt,
                                itemIDs: Array(reconciling ? itemIDs : Set(previous.itemIDs ?? []).union(itemIDs)))
                            return (id, partition, items, reconciling, nil)
                        } catch { return (id, nil, [], false, Self.message(error)) }
                    }
                }
                for _ in 0..<4 { if let id = remaining.next() { enqueue(id) } }
                for await (id, partition, items, reconciling, error) in group {
                    if let partition {
                        partitions[id] = partition; incoming += items
                        if reconciling, id.isEmpty { reconciledAll = true }
                    } else {
                        var partition = partitions[id] ?? Partition()
                        if more { partition.failedPage = partition.page + 1 }
                        partition.error = error; partitions[id] = partition
                    }
                    if let next = remaining.next() { enqueue(next) }
                }
            }
            try Task.checkCancellation()
            let errors = ids.compactMap { partitions[$0]?.error }
            let loadedIDs = ids.flatMap { partitions[$0]?.itemIDs ?? [] }
            let retained = Set(loadedIDs)
            let exact = categoryError == nil && ids.allSatisfy { partitions[$0]?.total != nil && partitions[$0]?.error == nil } && loadedIDs.count == retained.count
            let total = ids.reduce(0) { $0 + (partitions[$1]?.total ?? 0) }
            var previousItems = state.items
            if reconciledAll { previousItems = [] }
            else if scope != .all { previousItems.removeAll { !retained.contains($0.id) } }
            var merged = Dictionary(state.items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for item in incoming { merged[item.id] = item }
            let ordered = more ? previousItems + incoming : incoming + previousItems
            var seen = Set<String>()
            let unique = ordered.filter { seen.insert($0.id).inserted }.compactMap { merged[$0.id] }
                .filter { scope.mediaType == nil || $0.media.Type == scope.mediaType }
            let entry = Entry(items: unique, total: total, page: ids.reduce(0) { $0 + (partitions[$1]?.page ?? 0) },
                              hasMore: ids.contains { partitions[$0]?.hasMore ?? true }, checkedAt: more ? state.checkedAt ?? start : start,
                              partitions: partitions, categories: categories, categoriesCheckedAt: categoriesCheckedAt, totalIsExact: exact)
            var cacheError = categoryError ?? (errors.isEmpty ? nil : "部分分类读取失败（\(errors.count)），已有结果已保留。可重试。")
            if ids.count == 1, let error = errors.first { cacheError = error }
            do { try save(entry, key: key) } catch { cacheError = "本次结果已读取，本机缓存暂未写入。" }
            states[key] = State(items: entry.items, error: cacheError, total: entry.total, totalIsExact: exact, page: entry.page, hasMore: entry.hasMore,
                                fromCache: false, checkedAt: entry.checkedAt)
            if errors.isEmpty { health[source.id] = Health(milliseconds: Int(Date().timeIntervalSince(start) * 1000)) }
            else if errors.count == ids.count { recordFailure(source.id) }
        } catch {
            guard !Task.isCancelled else { return }
            states[key]?.error = Self.message(error)
            recordFailure(source.id)
        }
    }

    private nonisolated static func message(_ error: Error) -> String {
        if let catalog = error as? CatalogError { return catalog.localizedDescription }
        let failure = error as NSError
        if failure.domain == "kCFErrorDomainCFNetwork" { return "系统代理连接失败，请检查代理连接后重试。" }
        if failure.domain == NSURLErrorDomain { return "连接超时或网络暂不可用，已保留本机结果。" }
        return "接口数据暂时无法读取，已保留本机结果。"
    }

    private func recordFailure(_ id: UUID) {
        var value = health[id] ?? Health()
        value.failures += 1; value.error = "连接或数据格式异常"
        value.retryAt = Date().addingTimeInterval(min(1800, pow(2, Double(min(value.failures, 6))) * 15))
        health[id] = value
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
