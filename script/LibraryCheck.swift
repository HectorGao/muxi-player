import Foundation
import MuxiCore

@main @MainActor struct LibraryCheck {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "LibraryCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func main() async {
        do {
            for kind in MediaServerKind.allCases { try await run(kind: kind) }
            print("PASS: media wall store checks complete")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run(kind: MediaServerKind) async throws {
        let base = URL(string: "http://127.0.0.1:18796/emby")!
        let login = EmbyClient(baseURL: base, deviceID: "automated-library-check", serverKind: kind)
        let connection = try await login.authenticate(username: "demo", password: "demo")
        let client = EmbyClient(baseURL: base, deviceID: "automated-library-check", connection: connection)
        _ = try await client.setFavorite(itemID: "movie", isFavorite: false)
        do {
            try await verify(client: client, kind: kind)
        } catch {
            _ = try? await client.setFavorite(itemID: "movie", isFavorite: false)
            try? await client.logout()
            throw error
        }
        _ = try await client.setFavorite(itemID: "movie", isFavorite: false)
        try await client.logout()
    }

    static func verify(client: EmbyClient, kind: MediaServerKind) async throws {
        let store = LibraryStore()
        await store.refresh(client: client, selection: "home", search: "")
        try check(store.error == nil && !store.loading, "\(kind.label): home failed to finish")
        try check(store.libraries.count == 2 && store.resume.first?.id == "movie", "\(kind.label): libraries/resume missing")
        try check(!store.recommendations.isEmpty && store.recommendations.allSatisfy { $0.UserData?.Played != true },
                  "\(kind.label): recommendations must exclude watched items")
        let ratings = store.recommendations.compactMap(\.CommunityRating)
        try check(ratings == ratings.sorted(by: >), "\(kind.label): recommendation ranking lost")
        let films = store.libraries.first { $0.id == "films" }!
        let cancelledShelf = Task { await store.loadShelf(films, client: client) }
        for _ in 0..<100 where store.shelves[films.id]?.loading != true { await Task.yield() }
        try check(store.shelves[films.id]?.loading == true, "\(kind.label): cancellation check did not intercept a loading shelf")
        cancelledShelf.cancel()
        // Reenter before the cancelled request can run its actor-isolated cleanup.
        await store.loadShelf(films, client: client)
        await cancelledShelf.value
        try check(store.shelves[films.id]?.loading == false && store.shelves[films.id]?.items.count == 18,
                  "\(kind.label): cancelled shelf cleared or stranded its replacement")
        for library in store.libraries {
            await store.loadShelf(library, client: client)
            let shelf = store.shelves[library.id]
            try check(shelf != nil && shelf?.loading == false && shelf?.error == nil && shelf?.items.isEmpty == false,
                      "\(kind.label): library shelf did not load")
        }
        try check(store.shelves["films"]?.items.count == 18 && store.shelves["films"]?.totalCount == 70,
                  "\(kind.label): shelf must be bounded without losing total count")
        print("PASS: \(kind.label) home, lazy library rows, cancelled shelf reentry, resume and unwatched high-rating recommendations")

        await store.refresh(client: client, selection: "movies", search: "")
        try check(store.items.count == 60 && store.hasMore && store.totalCount == 70, "\(kind.label): first movie page invalid")
        await store.more(client: client, selection: "movies", search: "")
        try check(store.items.count == 70 && Set(store.items.map(\.id)).count == 70 && !store.hasMore,
                  "\(kind.label): pagination lost or duplicated items")
        await store.refresh(client: client, selection: "search", search: "mkv")
        try check(store.items.map(\.id) == ["mkv"], "\(kind.label): search did not reach server")
        await store.refresh(client: client, selection: "search", search: "nothing-matches-this")
        try check(store.items.isEmpty && store.error == nil && !store.hasMore, "\(kind.label): empty search state invalid")
        await store.refresh(client: client, selection: "search", search: "")
        try check(store.items.isEmpty && !store.loading, "\(kind.label): empty search must not fetch entire catalog")
        print("PASS: \(kind.label) pagination, search and empty states")

        let stale = Task { await store.refresh(client: client, selection: "search", search: "mkv") }
        try await Task.sleep(for: .milliseconds(50))
        await store.refresh(client: client, selection: "movies", search: "")
        await stale.value
        try check(store.items.count == 60 && store.hasMore && !store.loading, "\(kind.label): stale search replaced newer navigation")

        let movie = try await client.item(id: "movie")
        await store.toggleFavorite(movie, client: client)
        try check(store.favoriteError == nil && store.isFavorite(movie) && store.favoritePending.isEmpty,
                  "\(kind.label): favorite add failed")
        let saved = try await client.item(id: movie.id)
        try check(saved.isFavorite, "\(kind.label): favorite was not saved on server")
        let reopened = LibraryStore()
        await reopened.refresh(client: client, selection: "favorites", search: "")
        try check(reopened.items.map(\.id) == [movie.id] && reopened.isFavorite(reopened.items[0]),
                  "\(kind.label): favorites did not survive new store")
        let favorite = reopened.items[0]

        let invalidAuth = try JSONDecoder().decode(Authentication.self, from: Data("""
        {"AccessToken":"invalid-fixture-token","User":{"Id":"user","Name":"Test"}}
        """.utf8))
        let badConnection = Connection(baseURL: client.baseURL, authentication: invalidAuth, serverKind: kind)
        let rejected = EmbyClient(baseURL: client.baseURL, deviceID: "automated-library-check", connection: badConnection)
        await reopened.toggleFavorite(favorite, client: rejected)
        try check(reopened.favoriteError != nil && reopened.isFavorite(favorite) && reopened.favoritePending.isEmpty,
                  "\(kind.label): rejected favorite write changed local state")

        await reopened.toggleFavorite(favorite, client: client)
        try check(reopened.favoriteError == nil && !reopened.isFavorite(favorite), "\(kind.label): favorite removal failed")
        await reopened.refresh(client: client, selection: "favorites", search: "")
        try check(reopened.items.isEmpty && reopened.error == nil, "\(kind.label): removed favorite remains in collection")
        let removed = try await client.item(id: movie.id)
        try check(!removed.isFavorite, "\(kind.label): favorite removal was not saved on server")
        print("PASS: \(kind.label) stale-request isolation, favorite persistence, removal and failed-write recovery")
    }
}
