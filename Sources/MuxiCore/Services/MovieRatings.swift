import Foundation
import CryptoKit

public struct MovieRating: Codable, Equatable {
    public let value: Double
    public let source: String
    public let votes: Int?
    public let url: URL
    public init(value: Double, source: String, votes: Int?, url: URL) {
        self.value = value; self.source = source; self.votes = votes; self.url = url
    }
}

public actor MovieRatings {
    public static let shared = MovieRatings()
    private struct Entry: Codable { let rating: MovieRating?; let expires: Date }
    private let session: URLSession?
    private let directory: URL
    private let imdbEndpoint: URL
    private let cinemetaEndpoint: URL
    private let doubanEndpoint: URL
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<MovieRating?, Never>] = [:]

    public init(session: URLSession? = nil,
                directory: URL = URL.applicationSupportDirectory.appendingPathComponent("com.hectorgao.muxi-player/Ratings-v1"),
                imdbEndpoint: URL = URL(string: "https://api.agregarr.org/api/ratings")!,
                cinemetaEndpoint: URL = URL(string: "https://v3-cinemeta.strem.io")!,
                doubanEndpoint: URL = URL(string: "https://movie.douban.com/subject")!) {
        self.session = session; self.directory = directory; self.imdbEndpoint = imdbEndpoint
        self.cinemetaEndpoint = cinemetaEndpoint; self.doubanEndpoint = doubanEndpoint
    }

    public func rating(for item: MediaItem) async -> MovieRating? {
        guard item.Type == "Movie" || item.Type == "Series" else { return nil }
        let providers = item.ProviderIds ?? [:]
        let sortedProviders = providers.sorted { $0.key < $1.key }
        let providerPairs: [String] = sortedProviders.map { $0.key.lowercased() + "=" + $0.value }
        let providerIdentity = providerPairs.joined(separator: "&")
        let year = item.ProductionYear.map { String($0) } ?? ""
        let identityParts: [String] = [providerIdentity, item.OriginalTitle ?? item.Name, year, item.Type ?? ""]
        let identity = identityParts.joined(separator: "\n")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if entries[key] == nil, let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")) {
            entries[key] = try? JSONDecoder().decode(Entry.self, from: data)
        }
        if let entry = entries[key], entry.expires > Date() { return entry.rating }
        if let task = pending[key] { return await task.value }
        let task = Task { await self.resolve(item, key: key) }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        return result
    }

    private func resolve(_ item: MediaItem, key: String) async -> MovieRating? {
        let stale = entries[key]?.rating
        var failed = false
        let ids = Dictionary((item.ProviderIds ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        if let douban = ids["douban"], !douban.isEmpty, douban != "0", douban.allSatisfy(\.isNumber) {
            do {
                let expected = doubanEndpoint.appendingPathComponent(douban).appendingPathComponent("")
                let (data, response) = try await get(expected, accept: "text/html")
                if response.url?.host == expected.host, response.url?.path == expected.path,
                   let rating = Self.parseDouban(data, subjectURL: expected) {
                    store(rating, key: key, lifetime: 7 * 86_400)
                    return rating
                }
                failed = true
            } catch { failed = true }
        }
        do {
            let imdb: String?
            if let existing = ids["imdb"], OnlineCatalogClient.isIMDbID(existing) { imdb = existing }
            else { imdb = try await matchedIMDbID(item) }
            if let imdb {
                var parts = URLComponents(url: imdbEndpoint, resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "id", value: imdb)]
                let (data, _) = try await get(parts.url!)
                let rows = try JSONDecoder().decode([IMDbRow].self, from: data)
                if let row = rows.first(where: { $0.imdbId == imdb }), let value = row.rating,
                   value > 0, value <= 10, value.isFinite {
                    let rating = MovieRating(value: value, source: "IMDb", votes: row.votes,
                                             url: URL(string: "https://www.imdb.com/title/\(imdb)/")!)
                    store(rating, key: key, lifetime: 7 * 86_400)
                    return rating
                }
            }
        } catch { failed = true }
        // A transient outage preserves the last verified score and retries later.
        store(stale, key: key, lifetime: failed ? 1800 : 86_400)
        return stale
    }

    private struct IMDbRow: Decodable { let imdbId: String; let rating: Double?; let votes: Int? }

    private func get(_ url: URL, accept: String = "application/json") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("muxi/0.1 (+https://github.com/HectorGao/muxi-player)", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let result: (Data, URLResponse)
        if let session { result = try await session.data(for: request) }
        else { result = try await PublicNetwork.shared.data(for: request) }
        let (data, response) = result
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count < 3_000_000 else {
            throw CatalogError("评分服务暂不可用。")
        }
        return (data, response)
    }

    private func matchedIMDbID(_ item: MediaItem) async throws -> String? {
        let title = Self.cleanTitle(item.OriginalTitle ?? item.Name)
        let type = item.Type == "Series" ? "series" : "movie"
        var parts = URLComponents(url: cinemetaEndpoint, resolvingAgainstBaseURL: false)!
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        parts.percentEncodedPath = "/catalog/\(type)/top/search=" + (title.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + ".json"
        let (data, _) = try await get(parts.url!)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metas = object["metas"] as? [[String: Any]] else { return nil }
        return Self.matchIMDbID(item: item, candidates: metas)
    }

    public static func matchIMDbID(item: MediaItem, candidates: [[String: Any]]) -> String? {
        guard let expectedYear = item.ProductionYear else { return nil }
        func normalized(_ value: String) -> String { value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined() }
        let names = Set([item.Name, item.OriginalTitle].compactMap { $0 }.map { normalized(cleanTitle($0)) })
        let matches = candidates.compactMap { candidate -> String? in
            guard let id = candidate["id"] as? String, OnlineCatalogClient.isIMDbID(id),
                  let name = candidate["name"] as? String, names.contains(normalized(name)) else { return nil }
            let year = Int(String(describing: candidate["releaseInfo"] ?? candidate["year"] ?? "").prefix(4))
            guard year == expectedYear else { return nil }
            return id
        }
        let unique = Set(matches)
        return unique.count == 1 ? unique.first : nil
    }

    private static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "\\s*[（(][12][0-9]{3}[)）]\\s*$", with: "", options: .regularExpression)
    }

    public static func parseDouban(_ data: Data, subjectURL: URL) -> MovieRating? {
        guard let html = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: "<script[^>]*type=[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html), let json = String(html[range]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let aggregate = object["aggregateRating"] as? [String: Any],
                  let value = Double(String(describing: aggregate["ratingValue"] ?? "")), value.isFinite, value > 0, value <= 10 else { continue }
            let votes = Int(String(describing: aggregate["ratingCount"] ?? ""))
            return MovieRating(value: value, source: "豆瓣", votes: votes, url: subjectURL)
        }
        return nil
    }

    private func store(_ rating: MovieRating?, key: String, lifetime: TimeInterval) {
        let entry = Entry(rating: rating, expires: Date().addingTimeInterval(lifetime))
        entries[key] = entry
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(key + ".json")
            try JSONEncoder().encode(entry).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* A full disk keeps the verified result available in memory. */ }
    }
}
