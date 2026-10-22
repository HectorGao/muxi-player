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
        selection == "movies" || selection == "series" || selection.hasPrefix("library:")
    }

    // Country filtering is not shared by the two server APIs; index metadata, never video files.
    func prepareFilters(client: EmbyClient, selection: String) async {
        guard Self.canFilter(selection) else { return }
        if indexScope == selection, filterIndex != nil { return }
        let token = UUID()
        indexGeneration = token; indexScope = selection
        indexing = true; indexedCount = 0; indexError = nil; filterIndex = nil
        defer { if indexGeneration == token { indexing = false } }
        do {
            var collected: [MediaItem] = []
            var known = Set<String>()
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page = try await client.items(parent: selection.hasPrefix("library:") ? String(selection.dropFirst(8)) : nil,
                                                  type: selection == "movies" ? "Movie" : selection == "series" ? "Series" : "Movie,Series,BoxSet",
                                                  start: offset, limit: 500, sortBy: "SortName", metadataOnly: true)
                guard indexGeneration == token, !Task.isCancelled else { return }
                let fresh = page.Items.filter { known.insert($0.id).inserted }
                collected.append(contentsOf: fresh)
                offset += page.Items.count
                indexedCount = collected.count
                if let total = page.TotalRecordCount, offset >= total {
                    guard collected.count >= total else { throw EmbyError.invalidResponse }
                    break
                }
                if page.Items.isEmpty {
                    guard page.TotalRecordCount == nil else { throw EmbyError.invalidResponse }
                    break
                }
                guard !fresh.isEmpty else { throw EmbyError.invalidResponse }
            }
            filterIndex = collected
        } catch {
            if indexGeneration == token, !Task.isCancelled { indexError = "筛选信息读取失败，请重试：" + EmbyError.message(error) }
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
                if filterIndex == nil || indexScope != selection { await prepareFilters(client: client, selection: selection) }
                try Task.checkCancellation()
                guard let filterIndex, indexScope == selection else { throw EmbyError.invalidResponse }
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
        return try await client.items(type: selection == "series" ? "Series" : "Movie", start: start)
    }

    private func captured<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}
