import Foundation
import Observation
import MuxiCore

struct LibraryShelf {
    var items: [MediaItem] = []
    var totalCount: Int?
    var loading = false
    var error: String?
}

@MainActor @Observable final class LibraryStore {
    var libraries: [MediaItem] = []
    var items: [MediaItem] = []
    var resume: [MediaItem] = []
    var recommendations: [MediaItem] = []
    var shelves: [String: LibraryShelf] = [:]
    var loading = false
    var loadingMore = false
    var error: String?
    var favoriteError: String?
    var favoritePending: Set<String> = []
    var hasMore = false
    var totalCount: Int?
    var path: [MediaItem] = []
    var refreshID = UUID()
    var filter = LibraryFilter()
    var filterIndex: [MediaItem]?
    var indexing = false
    var indexedCount = 0
    var indexError: String?
    var indexUpdatedAt: Date?
    @ObservationIgnored private let indexCache: LibraryIndexCache

    init(indexCache: LibraryIndexCache? = nil) { self.indexCache = indexCache ?? .shared }
    @ObservationIgnored private var indexScope: String?
    @ObservationIgnored private var indexGeneration = UUID()
    private var favoriteValues: [String: Bool] = [:]
    @ObservationIgnored private var currentSelection = "home"
    @ObservationIgnored private var shelfRequests: [String: UUID] = [:]

    func invalidateIndex() {
        indexGeneration = UUID()
        filterIndex = nil; indexScope = nil; indexing = false; indexedCount = 0; indexError = nil
    }

    func resetBrowsing() { filter = LibraryFilter(); invalidateIndex() }

    static func canFilter(_ selection: String) -> Bool {
        selection == "catalog" || selection == "movies" || selection == "series" || selection.hasPrefix("library:")
    }

    // Incremental server metadata updates; a periodic ID-only pass detects deletions.
    func prepareFilters(client: EmbyClient, selection: String, force: Bool = false, rebuild: Bool = false) async {
        guard Self.canFilter(selection) else { return }
        let scope = "\(client.baseURL)|\(client.connection?.user.Id ?? "")|\(selection)"
        if !force && !rebuild, indexScope == scope, filterIndex != nil,
           let indexUpdatedAt, Date().timeIntervalSince(indexUpdatedAt) < 300 { return }
        let token = UUID()
        indexGeneration = token; indexScope = scope; indexError = nil
        let cached = rebuild ? nil : indexCache.load(client: client, scope: selection)
        filterIndex = cached?.items; indexUpdatedAt = cached?.syncedAt
        indexedCount = cached?.items.count ?? 0
        if !force, let cached, Date().timeIntervalSince(cached.syncedAt) < 300 { return }
        indexing = true
        defer { if indexGeneration == token { indexing = false } }
        let started = Date()
        let parent = selection.hasPrefix("library:") ? String(selection.dropFirst(8)) : nil
        let type = selection == "movies" ? "Movie" : selection == "series" ? "Series" : "Movie,Series,BoxSet"
        func pages(since: Date? = nil, userSince: Date? = nil, idsOnly: Bool = false) async throws -> [MediaItem] {
            var result: [MediaItem] = [], known = Set<String>(), offset = 0
            while true {
                try Task.checkCancellation()
                let page = try await client.items(parent: parent, type: type, start: offset, limit: 500,
                                                  sortBy: "SortName", metadataOnly: true, savedSince: since,
                                                  userSavedSince: userSince, idsOnly: idsOnly)
                guard indexGeneration == token else { throw CancellationError() }
                let fresh = page.Items.filter { known.insert($0.id).inserted }
                result.append(contentsOf: fresh); offset += page.Items.count
                if cached == nil { indexedCount = result.count }
                if let total = page.TotalRecordCount, offset >= total {
                    guard result.count >= total else { throw EmbyError.invalidResponse }
                    break
                }
                if page.Items.isEmpty {
                    guard page.TotalRecordCount == nil else { throw EmbyError.invalidResponse }
                    break
                }
                guard !fresh.isEmpty else { throw EmbyError.invalidResponse }
            }
            return result
        }
        do {
            var collected: [MediaItem]
            var reconciledAt = cached?.reconciledAt ?? started
            if let cached {
                // Overlap avoids missing changes made while the previous paginated pass was running.
                let since = cached.syncedAt.addingTimeInterval(-300)
                var merged = Dictionary(uniqueKeysWithValues: cached.items.map { ($0.id, $0) })
                let changed = try await pages(since: since)
                let userChanged = try await pages(userSince: since)
                for item in changed + userChanged { merged[item.id] = item }
                if started.timeIntervalSince(cached.reconciledAt) > 86_400 || force {
                    let ids = Set(try await pages(idsOnly: true).map(\.id))
                    merged = merged.filter { ids.contains($0.key) }
                    // A new item outside a server's change window still receives full metadata.
                    if !ids.isSubset(of: Set(merged.keys)) { collected = try await pages() }
                    else { collected = Array(merged.values) }
                    reconciledAt = started
                } else { collected = Array(merged.values) }
            } else { collected = try await pages() }
            try Task.checkCancellation()
            guard indexGeneration == token else { return }
            let entry = LibraryIndexCache.Entry(items: collected, syncedAt: started, reconciledAt: reconciledAt)
            try indexCache.save(entry, client: client, scope: selection)
            filterIndex = collected; indexUpdatedAt = started; indexedCount = collected.count
        } catch {
            if indexGeneration == token, !Task.isCancelled {
                indexError = (cached == nil ? "筛选信息读取失败：" : "暂用本机索引，同步失败：") + EmbyError.message(error)
            }
        }
    }

    func refresh(client: EmbyClient, selection: String, search: String) async {
        let token = UUID()
        refreshID = token
        currentSelection = selection
        loading = true
        loadingMore = false
        error = nil
        favoriteValues = favoriteValues.filter { favoritePending.contains($0.key) }
        items = []
        hasMore = false
        totalCount = nil
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { if refreshID == token { loading = false } }
        do {
            if !query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            if libraries.isEmpty {
                let result = try await client.libraries()
                guard refreshID == token, !Task.isCancelled else { return }
                libraries = result
            }
            if selection == "home", query.isEmpty, path.isEmpty {
                shelves = [:]
                resume = []
                recommendations = []
                async let resumed = captured { try await client.resume() }
                async let suggested = captured {
                    try await client.items(type: "Movie,Series", limit: 18, sortBy: "CommunityRating,DateCreated", descending: true, unplayedOnly: true)
                }
                let (resumeResult, recommendedResult) = await (resumed, suggested)
                guard refreshID == token, !Task.isCancelled else { return }
                switch resumeResult {
                case .success(let values): resume = values
                case .failure(let failure): error = "继续观看暂不可用：" + EmbyError.message(failure)
                }
                switch recommendedResult {
                case .success(let page): recommendations = page.Items
                case .failure(let failure): error = "推荐暂不可用：" + EmbyError.message(failure)
                }
                return
            }
            if selection == "search", query.isEmpty, path.isEmpty { return }
            let page = try await fetch(client: client, selection: selection, search: query, start: 0)
            guard refreshID == token, !Task.isCancelled else { return }
            items = page.Items
            totalCount = page.TotalRecordCount
            hasMore = page.TotalRecordCount.map { items.count < $0 } ?? (page.Items.count == 60)
        } catch {
            guard refreshID == token, !Task.isCancelled else { return }
            self.error = EmbyError.message(error)
        }
    }

    func loadShelf(_ library: MediaItem, client: EmbyClient) async {
        guard shelves[library.id] == nil || shelves[library.id]?.loading == true else { return }
        let token = refreshID
        let requestID = UUID()
        shelfRequests[library.id] = requestID
        shelves[library.id] = LibraryShelf(loading: true)
        defer {
            if refreshID == token, shelfRequests[library.id] == requestID {
                if Task.isCancelled { shelves[library.id] = nil }
                shelfRequests[library.id] = nil
            }
        }
        do {
            let page = try await client.items(parent: library.id, type: "Movie,Series,BoxSet", limit: 18, sortBy: "DateCreated", descending: true)
            guard refreshID == token, shelfRequests[library.id] == requestID, !Task.isCancelled else { return }
            shelves[library.id] = LibraryShelf(items: page.Items, totalCount: page.TotalRecordCount)
        } catch {
            guard refreshID == token, shelfRequests[library.id] == requestID else { return }
            if Task.isCancelled { shelves[library.id] = nil }
            else { shelves[library.id] = LibraryShelf(error: EmbyError.message(error)) }
        }
    }

    func retryShelf(_ library: MediaItem, client: EmbyClient) async {
        shelves[library.id] = nil
        await loadShelf(library, client: client)
    }

    func more(client: EmbyClient, selection: String, search: String) async {
        guard !loading, !loadingMore, hasMore else { return }
        let token = refreshID
        loadingMore = true
        defer { if refreshID == token { loadingMore = false } }
        do {
            let page = try await fetch(client: client, selection: selection, search: search.trimmingCharacters(in: .whitespacesAndNewlines), start: items.count)
            guard refreshID == token, !Task.isCancelled else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.Items.filter { !known.contains($0.id) })
            totalCount = page.TotalRecordCount
            hasMore = !page.Items.isEmpty && (page.TotalRecordCount.map { items.count < $0 } ?? (page.Items.count == 60))
        } catch { if refreshID == token, !Task.isCancelled { self.error = EmbyError.message(error) } }
    }

    func isFavorite(_ item: MediaItem) -> Bool { favoriteValues[item.id] ?? item.isFavorite }

    func toggleFavorite(_ item: MediaItem, client: EmbyClient) async {
        guard !favoritePending.contains(item.id) else { return }
        let desired = !isFavorite(item)
        favoritePending.insert(item.id)
        favoriteError = nil
        defer { favoritePending.remove(item.id) }
        do {
            let data = try await client.setFavorite(itemID: item.id, isFavorite: desired)
            let saved = data.IsFavorite ?? desired
            favoriteValues[item.id] = saved
            if currentSelection == "favorites", path.isEmpty, !saved {
                let removed = items.contains { $0.id == item.id }
                items.removeAll { $0.id == item.id }
                if removed, let totalCount { self.totalCount = max(0, totalCount - 1) }
            }
        } catch { favoriteError = "收藏未更新：" + EmbyError.message(error) }
    }

    private func fetch(client: EmbyClient, selection: String, search: String, start: Int) async throws -> ItemPage {
        if Self.canFilter(selection), path.isEmpty {
            let requested = filter
            if requested.isActive {
                if filterIndex == nil || indexScope != "\(client.baseURL)|\(client.connection?.user.Id ?? "")|\(selection)" { await prepareFilters(client: client, selection: selection) }
                try Task.checkCancellation()
                guard let filterIndex, indexScope == "\(client.baseURL)|\(client.connection?.user.Id ?? "")|\(selection)" else { throw EmbyError.invalidResponse }
                let matches = requested.apply(to: filterIndex, search: search)
                return ItemPage(Items: Array(matches.dropFirst(start).prefix(60)), TotalRecordCount: matches.count)
            }
            return try await client.items(parent: selection.hasPrefix("library:") ? String(selection.dropFirst(8)) : nil,
                                          type: selection == "movies" ? "Movie" : selection == "series" ? "Series" : "Movie,Series,BoxSet",
                                          search: search, start: start, sortBy: requested.sort.field, descending: requested.sort.descending)
        }
        if !search.isEmpty {
            return try await client.items(type: "Movie,Series,Episode,BoxSet", search: search, start: start, favoritesOnly: selection == "favorites")
        }
        if let parent = path.last { return try await client.items(parent: parent.id, start: start, recursive: false) }
        if selection == "favorites" { return try await client.items(type: "Movie,Series,Episode,BoxSet", start: start, favoritesOnly: true) }
        if selection == "recommendations" {
            return try await client.items(type: "Movie,Series", start: start, sortBy: "CommunityRating,DateCreated", descending: true, unplayedOnly: true)
        }
        return try await client.items(type: selection == "catalog" ? "Movie,Series,BoxSet" : selection == "series" ? "Series" : "Movie", start: start)
    }

    private func captured<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}
