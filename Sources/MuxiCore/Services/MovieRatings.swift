import Foundation
import CryptoKit

public struct MovieRating: Codable, Equatable, Hashable {
    public let value: Double
    public let source: String
    public let votes: Int?
    public let url: URL
    public let attribution: String?
    public init(value: Double, source: String, votes: Int?, url: URL, attribution: String? = nil) {
        self.value = value; self.source = source; self.votes = votes; self.url = url; self.attribution = attribution
    }
}

public struct MovieRatingSet: Codable, Equatable, Hashable {
    public var imdb: MovieRating?
    public var douban: MovieRating?
    public init(imdb: MovieRating? = nil, douban: MovieRating? = nil) { self.imdb = imdb; self.douban = douban }
    public var hasValues: Bool { imdb != nil || douban != nil }
}
public extension Notification.Name { static let muxiMovieRatingsUpdated = Notification.Name("muxiMovieRatingsUpdated") }
public struct MovieRatingPreparation { public let items: [MediaItem]; public let notice: String }

public actor MovieRatings {
    public static let shared = MovieRatings(charts: .shared)
    private struct CachedRating: Codable { let rating: MovieRating?; let expires: Date }
    private struct Entry: Codable {
        var imdb: CachedRating?
        var douban: CachedRating?
        init() { }
        enum CodingKeys: String, CodingKey { case imdb, douban, rating, expires }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            imdb = try values.decodeIfPresent(CachedRating.self, forKey: .imdb)
            douban = try values.decodeIfPresent(CachedRating.self, forKey: .douban)
            if let rating = try values.decodeIfPresent(MovieRating.self, forKey: .rating),
               let expires = try values.decodeIfPresent(Date.self, forKey: .expires) {
                let old = CachedRating(rating: rating, expires: expires)
                if rating.source == "IMDb" { imdb = old }
                if rating.source == "豆瓣" { douban = old }
            }
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(imdb, forKey: .imdb)
            try values.encodeIfPresent(douban, forKey: .douban)
        }
    }
    private let session: URLSession?
    private let directory: URL
    private let imdbEndpoint: URL
    private let cinemetaEndpoint: URL
    private let doubanEndpoint: URL
    private let charts: MovieCharts?
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<MovieRatingSet, Never>] = [:]
    private var imdbRetryAfter = Date.distantPast
    private var doubanRetryAfter = Date.distantPast
    private var nextDoubanRequest = Date.distantPast

    public init(session: URLSession? = nil,
                directory: URL = URL.applicationSupportDirectory.appendingPathComponent("com.hectorgao.muxi-player/Ratings-v1"),
                imdbEndpoint: URL = URL(string: "https://api.agregarr.org/api/ratings")!,
                cinemetaEndpoint: URL = URL(string: "https://v3-cinemeta.strem.io")!,
                doubanEndpoint: URL = URL(string: "https://movie.douban.com/subject")!, charts: MovieCharts? = nil) {
        self.session = session; self.directory = directory; self.imdbEndpoint = imdbEndpoint
        self.cinemetaEndpoint = cinemetaEndpoint; self.doubanEndpoint = doubanEndpoint; self.charts = charts
    }

    public func rating(for item: MediaItem) async -> MovieRating? {
        let values = await ratings(for: item)
        return values.douban ?? values.imdb
    }

    public func ratings(for item: MediaItem) async -> MovieRatingSet {
        guard item.Type == "Movie" || item.Type == "Series" else { return MovieRatingSet() }
        let key = Self.key(item), entry = load(Self.key(item))
        if (entry.imdb?.expires ?? .distantPast) > Date(), (entry.douban?.expires ?? .distantPast) > Date() { return values(entry, item: item) }
        if let task = pending[key] { return await task.value }
        let task = Task { await self.resolve(item, key: key) }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        return result
    }

    private func resolve(_ item: MediaItem, key: String) async -> MovieRatingSet {
        let before = values(load(key), item: item)
        let ids = Dictionary((item.ProviderIds ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        var doubanID = (ids["douban"] ?? load(key).douban?.rating?.url.lastPathComponent).flatMap { OnlineCatalogClient.isDoubanID($0) ? $0 : nil }
        var imdbID = (ids["imdb"] ?? load(key).imdb?.rating?.url.lastPathComponent).flatMap { OnlineCatalogClient.isIMDbID($0) ? $0 : nil }
        var matched = item
        var identityFailed = false
        if doubanID == nil || imdbID == nil {
            do {
                if let suggestion = try await suggestedDouban(item, knownID: doubanID) {
                    doubanID = suggestion.id
                    if let title = suggestion.sub_title, !title.isEmpty { matched.OriginalTitle = title }
                }
            } catch { identityFailed = true }
        }
        if (load(key).douban?.expires ?? .distantPast) <= Date() {
            do {
                var rating: MovieRating?
                if let doubanID {
                    let url = doubanEndpoint.appendingPathComponent(doubanID).appendingPathComponent("")
                    var parts = URLComponents(url: doubanEndpoint.deletingLastPathComponent().appendingPathComponent("j/subject_abstract"), resolvingAgainstBaseURL: false)!
                    parts.queryItems = [.init(name: "subject_id", value: doubanID)]
                    let data = try await get(parts.url!)
                    guard let value = Self.parseDoubanSummary(data, id: doubanID, year: item.ProductionYear, subjectURL: url) else { throw CatalogError("豆瓣摘要暂不可用。") }
                    rating = value
                }
                store(rating, provider: .douban, key: key, lifetime: rating == nil ? (identityFailed ? 1800 : 86_400) : 7 * 86_400)
            } catch { store(load(key).douban?.rating, provider: .douban, key: key, lifetime: 1800) }
        }
        if (load(key).imdb?.expires ?? .distantPast) <= Date(), imdbRetryAfter <= Date() {
            do {
                if imdbID == nil { imdbID = try await matchedIMDbID(matched) }
                var rating: MovieRating?
                if let id = imdbID { rating = try await imdbRatings([id]).first { $0.imdbId == id }?.ratingValue }
                store(rating, provider: .imdb, key: key, lifetime: rating == nil ? 86_400 : 7 * 86_400)
            } catch {
                imdbRetryAfter = Date().addingTimeInterval(1800)
                store(load(key).imdb?.rating, provider: .imdb, key: key, lifetime: 1800)
            }
        }
        let result = values(load(key), item: item)
        if before != result { NotificationCenter.default.post(name: .muxiMovieRatingsUpdated, object: nil) }
        return result
    }

    // shortcut: sorting uses identified/cached scores, resolve remaining identities as their cards are viewed.
    public func enriched(_ items: [MediaItem], chart: MovieChartKind?, sort: LibrarySort, fetchIMDb: Bool = true) async -> MovieRatingPreparation {
        let kind = chart ?? (sort == .imdbRating ? .imdb : sort == .doubanRating ? .douban : nil)
        var snapshot: MovieChartSnapshot?
        var companion: MovieChartSnapshot?
        if let kind {
            async let primary = charts?.snapshot(kind)
            async let secondary = charts?.snapshot(kind == .imdb ? .douban : .imdb)
            (snapshot, companion) = await (primary, secondary)
        }
        let matches = snapshot?.matches(in: items, companion: companion) ?? [:]
        if sort == .imdbRating, fetchIMDb, imdbRetryAfter <= Date() {
            var identified: [String: [MediaItem]] = [:]
            for item in items where item.Type == "Movie" || item.Type == "Series" {
                if chart != nil, matches[item.id] == nil { continue }
                let id = item.ProviderIds?.first { $0.key.lowercased() == "imdb" }?.value ?? (snapshot?.kind == .imdb ? matches[item.id]?.id : nil)
                if let id, OnlineCatalogClient.isIMDbID(id), (load(Self.key(item)).imdb?.expires ?? .distantPast) <= Date() { identified[id, default: []].append(item) }
            }
            let ids = identified.keys.sorted()
            for start in stride(from: 0, to: ids.count, by: 100) {
                if Task.isCancelled { break }
                let batch = Array(ids[start..<min(start + 100, ids.count)])
                do {
                    let rows = try await imdbRatings(batch)
                    for id in batch {
                        let rating = rows.first { $0.imdbId == id }?.ratingValue
                        for item in identified[id] ?? [] { store(rating, provider: .imdb, key: Self.key(item), lifetime: rating == nil ? 86_400 : 7 * 86_400) }
                    }
                } catch { imdbRetryAfter = Date().addingTimeInterval(1800); break }
            }
        }
        let enriched = items.map { item -> MediaItem in
            var item = item
            var ratings = item.ExternalRatings ?? MovieRatingSet()
            if let row = matches[item.id], let snapshot {
                item.ChartRanks = (item.ChartRanks ?? [:]).merging([snapshot.kind.rawValue: row.rank]) { _, new in new }
                if let value = row.rating, let id = row.id {
                    let source = snapshot.kind == .imdb ? "IMDb" : "豆瓣"
                    let url = URL(string: snapshot.kind == .imdb ? "https://www.imdb.com/title/\(id)/" : "https://movie.douban.com/subject/\(id)/")!
                    let rating = MovieRating(value: value, source: source, votes: row.votes, url: url, attribution: snapshot.status)
                    if snapshot.kind == .imdb { ratings.imdb = rating } else { ratings.douban = rating }
                }
            }
            item.ExternalRatings = ratings
            item.ExternalRatings = values(load(Self.key(item)), item: item)
            return item
        }
        var notice = sort.usesExternalRatings ? "按已取得评分排序，缺失项排最后。" : ""
        if let snapshot { notice += " " + snapshot.status }
        else if let kind { notice += " " + kind.label + " 暂未取得完整榜单，请稍后重试。" }
        return MovieRatingPreparation(items: enriched, notice: notice.trimmingCharacters(in: .whitespaces))
    }

    private struct IMDbRow: Decodable {
        let imdbId: String; let rating: Double?; let votes: Int?
        var ratingValue: MovieRating? {
            guard OnlineCatalogClient.isIMDbID(imdbId), let rating, rating > 0, rating <= 10, rating.isFinite else { return nil }
            return MovieRating(value: rating, source: "IMDb", votes: votes, url: URL(string: "https://www.imdb.com/title/\(imdbId)/")!)
        }
    }
    private func imdbRatings(_ ids: [String]) async throws -> [IMDbRow] {
        var parts = URLComponents(url: imdbEndpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = ids.map { .init(name: "id", value: $0) }
        let rows = try JSONDecoder().decode([IMDbRow].self, from: await get(parts.url!))
        guard Set(rows.map(\.imdbId)) == Set(ids), rows.count == ids.count else { throw CatalogError("IMDb 评分返回不完整。") }
        return rows
    }
    private struct DoubanSuggestion: Decodable { let id: String; let title: String; let year: String; let sub_title: String?; let type: String }
    private func suggestedDouban(_ item: MediaItem, knownID: String?) async throws -> DoubanSuggestion? {
        var parts = URLComponents(url: doubanEndpoint.deletingLastPathComponent().appendingPathComponent("j/subject_suggest"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "q", value: Self.cleanTitle(item.Name))]
        let rows = try JSONDecoder().decode([DoubanSuggestion].self, from: await get(parts.url!))
        let names = Set([item.Name, item.OriginalTitle].compactMap { $0 }.map(Self.normalizedTitle))
        let matches = rows.filter { row in
            guard OnlineCatalogClient.isDoubanID(row.id) else { return false }
            if let knownID { return row.id == knownID }
            return row.type == "movie" && item.ProductionYear != nil && Int(row.year) == item.ProductionYear &&
                (names.contains(Self.normalizedTitle(row.title)) || row.sub_title.map { names.contains(Self.normalizedTitle($0)) } == true)
        }
        return Set(matches.map(\.id)).count == 1 ? matches.first : nil
    }
    public static func parseDoubanSummary(_ data: Data, id: String, year: Int?, subjectURL: URL) -> MovieRating? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["r"] as? Int == 0,
              let subject = object["subject"] as? [String: Any], subject["id"] as? String == id,
              year == nil || Int(subject["release_year"] as? String ?? "") == year,
              let value = Double(subject["rate"] as? String ?? ""), value > 0, value <= 10, value.isFinite else { return nil }
        return MovieRating(value: value, source: "豆瓣", votes: nil, url: subjectURL)
    }
    private func get(_ url: URL) async throws -> Data {
        if url.host == doubanEndpoint.host {
            guard doubanRetryAfter <= Date() else { throw CatalogError("豆瓣评分请求暂缓，请稍后重试。") }
            let scheduled = max(Date(), nextDoubanRequest)
            nextDoubanRequest = scheduled.addingTimeInterval(0.25)
            if scheduled > Date() { try await Task.sleep(for: .seconds(scheduled.timeIntervalSinceNow)) }
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("muxi/0.1 (+https://github.com/HectorGao/muxi-player)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        if let session { (data, response) = try await session.data(for: request) }
        else { (data, response) = try await PublicNetwork.shared.data(for: request) }
        if url.host == doubanEndpoint.host, (response as? HTTPURLResponse)?.statusCode == 429 { doubanRetryAfter = Date().addingTimeInterval(1800) }
        guard let response = response as? HTTPURLResponse, response.url?.host == url.host,
              (200..<300).contains(response.statusCode), data.count < 3_000_000 else { throw CatalogError("评分服务暂不可用。") }
        return data
    }
    private func matchedIMDbID(_ item: MediaItem) async throws -> String? {
        let title = Self.cleanTitle(item.OriginalTitle ?? item.Name)
        let type = item.Type == "Series" ? "series" : "movie"
        var parts = URLComponents(url: cinemetaEndpoint, resolvingAgainstBaseURL: false)!
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
        parts.percentEncodedPath = "/catalog/\(type)/top/search=" + (title.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + ".json"
        let data = try await get(parts.url!)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let metas = object["metas"] as? [[String: Any]] else { return nil }
        return Self.matchIMDbID(item: item, candidates: metas)
    }
    public static func matchIMDbID(item: MediaItem, candidates: [[String: Any]]) -> String? {
        guard let expectedYear = item.ProductionYear else { return nil }
        let names = Set([item.Name, item.OriginalTitle].compactMap { $0 }.map(normalizedTitle))
        let matches = candidates.compactMap { candidate -> String? in
            guard let id = candidate["id"] as? String, OnlineCatalogClient.isIMDbID(id),
                  let name = candidate["name"] as? String, names.contains(normalizedTitle(name)) else { return nil }
            let year = Int(String(describing: candidate["releaseInfo"] ?? candidate["year"] ?? "").prefix(4))
            return year == expectedYear ? id : nil
        }
        let unique = Set(matches)
        return unique.count == 1 ? unique.first : nil
    }
    public static func normalizedTitle(_ title: String) -> String {
        cleanTitle(title).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "\\s*[（(][12][0-9]{3}[)）]\\s*$", with: "", options: .regularExpression)
    }
    private static func key(_ item: MediaItem) -> String {
        let pairs = (item.ProviderIds ?? [:]).sorted { $0.key < $1.key }.map { $0.key.lowercased() + "=" + $0.value }.joined(separator: "&")
        let identity = [pairs, item.OriginalTitle ?? item.Name, item.ProductionYear.map(String.init) ?? "", item.Type ?? ""].joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func load(_ key: String) -> Entry {
        if let entry = entries[key] { return entry }
        let file = directory.appendingPathComponent(key + ".json")
        let entry = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) } ?? Entry()
        entries[key] = entry
        return entry
    }
    private func values(_ entry: Entry, item: MediaItem) -> MovieRatingSet {
        MovieRatingSet(imdb: entry.imdb?.rating ?? item.ExternalRatings?.imdb, douban: entry.douban?.rating ?? item.ExternalRatings?.douban)
    }
    private func store(_ rating: MovieRating?, provider: MovieChartKind, key: String, lifetime: TimeInterval) {
        var entry = load(key)
        let value = CachedRating(rating: rating, expires: Date().addingTimeInterval(lifetime))
        if provider == .imdb { entry.imdb = value } else { entry.douban = value }
        entries[key] = entry
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(key + ".json")
            try JSONEncoder().encode(entry).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* A full disk keeps verified scores available in memory. */ }
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

}
