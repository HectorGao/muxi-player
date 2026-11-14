import Foundation
import CryptoKit
import MuxiCore

// Cache metadata only. Tokens and stream URLs stay out of the on-disk index.
@MainActor final class LibraryIndexCache {
    static let shared = LibraryIndexCache()
    struct Entry: Codable {
        var items: [MediaItem]
        var syncedAt: Date
        var reconciledAt: Date
    }
    private let directory: URL
    private var entries: [String: Entry] = [:]

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("com.hectorgao.muxi-player/LibraryIndex-v1")) {
        self.directory = directory
    }

    private func key(_ client: EmbyClient, _ scope: String) -> String {
        let identity = [client.baseURL.absoluteString, client.connection?.serverID ?? "", client.connection?.user.Id ?? "",
                        client.serverKind.rawValue, scope].joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load(client: EmbyClient, scope: String) -> Entry? {
        let key = key(client, scope)
        if let entry = entries[key] { return entry }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              Set(entry.items.map(\.id)).count == entry.items.count else { return nil }
        entries[key] = entry
        return entry
    }

    func save(_ entry: Entry, client: EmbyClient, scope: String) throws {
        var sanitized = entry
        sanitized.items = entry.items.map { item in
            var item = item
            item.MediaStreams = item.MediaStreams?.map { stream in
                var stream = stream; stream.DeliveryUrl = nil; return stream
            }
            return item
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(key(client, scope) + ".json")
        try JSONEncoder().encode(sanitized).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        entries[key(client, scope)] = sanitized
    }
}
