import Foundation
import Security
import MuxiCore

@main @MainActor struct SourceCheck {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "SourceCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() async {
        let service = "com.hectorgao.muxi-player.tests.\(UUID())"
        let domain = service + ".defaults"
        let defaults = UserDefaults(suiteName: domain)!
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        defer { SecItemDelete(query as CFDictionary); defaults.removePersistentDomain(forName: domain) }
        do {
            let a = "http://127.0.0.1:18796/emby"
            let b = "http://127.0.0.1:18797/emby"
            let legacy = try await EmbyClient(baseURL: URL(string: a)!, deviceID: "source-check").authenticate(username: "demo", password: "demo")
            var old = query
            old[kSecAttrAccount as String] = "emby-connection"
            old[kSecValueData as String] = try JSONEncoder().encode(legacy)
            try check(SecItemAdd(old as CFDictionary, nil) == errSecSuccess, "create isolated legacy Keychain record")
            let vault = CredentialStore(service: service)
            let store = ConnectionStore(credentials: vault, defaults: defaults)
            await store.restore()
            try check(store.sources.count == 1 && store.storageReady, "legacy record migration")
            let originalID = store.sources[0].id
            let added = await store.connect(address: b, username: "demo", password: "demo", name: "Jellyfin fixture", serverKind: .jellyfin)
            try check(added && store.sources.count == 2, "save second source without replacing first")
            let secondID = store.sources[1].id
            let updated = await store.connect(address: a, username: "demo", password: "demo", name: "Emby fixture")
            try check(updated && store.sources.count == 2 && store.sources[0].id == originalID, "relogin keeps source identity")
            store.selectSource(secondID)
            let reopened = ConnectionStore(credentials: CredentialStore(service: service), defaults: defaults)
            await reopened.restore()
            try check(reopened.sources.count == 2 && reopened.selectedSourceID == secondID && reopened.client?.serverKind == .jellyfin,
                      "new store restores both tokens and selected source without authentication")
            try check(reopened.sources.map(\.name) == ["Emby fixture", "Jellyfin fixture"], "source names persist")
            let clientA = reopened.clients[originalID]!, clientB = reopened.clients[secondID]!
            _ = try await clientA.setFavorite(itemID: "movie", isFavorite: false)
            _ = try await clientB.setFavorite(itemID: "movie", isFavorite: false)
            _ = try await clientA.setFavorite(itemID: "movie", isFavorite: true)
            let itemA = try await clientA.item(id: "movie"), itemB = try await clientB.item(id: "movie")
            try check(itemA.isFavorite && !itemB.isFavorite, "same item ID remains isolated between sources")
            _ = try await clientA.setFavorite(itemID: "movie", isFavorite: false)
            let libraryA = LibraryStore(), libraryB = LibraryStore()
            async let loadA: Void = libraryA.refresh(client: clientA, selection: "search", search: "mkv")
            async let loadB: Void = libraryB.refresh(client: clientB, selection: "search", search: "mkv")
            _ = await (loadA, loadB)
            try check(libraryA.items.first?.id == "mkv" && libraryB.items.first?.id == "mkv", "parallel search uses separate library stores")
            let failed = await reopened.connect(address: "ftp://invalid.example", username: "demo", password: "demo")
            try check(!failed && reopened.sources.count == 2, "failed add preserves saved sources")
            await reopened.remove(reopened.sources[1])
            try check(reopened.sources.count == 1 && reopened.sources[0].id == originalID && reopened.selectedSourceID == nil,
                      "removal preserves other source and returns to all sources")
            await reopened.remove(reopened.sources[0])
            let empty = try await vault.load()
            try check(empty.isEmpty, "removed sources are not resurrected by legacy migration")
            var record = query
            record[kSecAttrAccount as String] = "media-sources-v1"
            try check(SecItemUpdate(record as CFDictionary, [kSecValueData as String: Data("invalid".utf8)] as CFDictionary) == errSecSuccess,
                      "prepare corrupt isolated vault")
            let corrupted = ConnectionStore(credentials: vault, defaults: defaults)
            await corrupted.restore()
            try check(!corrupted.storageReady && corrupted.error != nil, "corrupt vault is preserved, not replaced with legacy or empty data")
            let refused = await corrupted.connect(address: a, username: "demo", password: "demo")
            try check(!refused, "failed restoration blocks destructive overwrite")
            print("PASS: Keychain migration, multi-source persistence, relogin, restoration, cross-source search/favorites, removal and corrupt-vault protection")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }
}
