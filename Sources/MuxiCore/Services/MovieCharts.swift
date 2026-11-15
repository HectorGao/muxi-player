import Foundation

public enum MovieChartKind: String, CaseIterable, Codable {
    case douban, imdb
    public var label: String { self == .douban ? "豆瓣 Top 250" : "IMDb Top 250" }
}

public struct MovieChartRecord: Codable, Equatable {
    public let rank: Int
    public let id: String?
    public let titles: [String]
    public let year: Int
    public let rating: Double?
    public let votes: Int?
}

public struct MovieChartSnapshot: Codable {
    public let kind: MovieChartKind
    public let records: [MovieChartRecord]
    public let updatedAt: Date
    public let fetchedAt: Date
    public var stale: Bool

    public var status: String {
        let date = updatedAt.formatted(.dateTime.year().month().day())
        return kind.label + " · " + date + (stale ? " · 缓存快照" : "")
    }

    public func matches(in items: [MediaItem], companion: MovieChartSnapshot? = nil) -> [String: MovieChartRecord] {
        let byID = Dictionary(records.compactMap { row in row.id.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        var byTitle: [String: [MovieChartRecord]] = [:]
        for row in records {
            for title in Set(row.titles.map(MovieRatings.normalizedTitle)) {
                byTitle[title + "|\(row.year)", default: []].append(row)
            }
        }
        var result: [String: MovieChartRecord] = [:]
        let companionMatches = companion?.matches(in: items) ?? [:]
        for item in items where item.Type == "Movie" {
            let id = item.ProviderIds?.first { $0.key.lowercased() == kind.rawValue }?.value
            if let id, let row = byID[id] { result[item.id] = row; continue }
            guard let year = item.ProductionYear else { continue }
            let aliases = companionMatches[item.id]?.titles ?? []
            let names = Set(([item.Name, item.OriginalTitle].compactMap { $0 } + aliases).map(MovieRatings.normalizedTitle))
            let candidates = names.flatMap { byTitle[$0 + "|\(year)"] ?? [] }
                .filter { id == nil || $0.id == nil || $0.id == id }
            if Set(candidates.map(\.rank)).count == 1 { result[item.id] = candidates.first }
        }
        return result
    }
}

public actor MovieCharts {
    public static let shared = MovieCharts()
    private let session: URLSession?
    private let directory: URL
    private let doubanURL: URL
    private let imdbURL: URL
    private var cached: [MovieChartKind: MovieChartSnapshot] = [:]
    private var pending: [MovieChartKind: Task<MovieChartSnapshot?, Never>] = [:]
    private var retryAfter: [MovieChartKind: Date] = [:]

    public init(session: URLSession? = nil,
                directory: URL = URL.applicationSupportDirectory.appendingPathComponent("com.hectorgao.muxi-player/Charts-v1"),
                doubanURL: URL = URL(string: "https://movie.douban.com/top250")!,
                imdbURL: URL = URL(string: "https://imdb-top250.mmdju.workers.dev/top250")!) {
        self.session = session; self.directory = directory; self.doubanURL = doubanURL; self.imdbURL = imdbURL
    }

    public func snapshot(_ kind: MovieChartKind) async -> MovieChartSnapshot? {
        if cached[kind] == nil, let data = try? Data(contentsOf: file(kind)),
           let value = try? JSONDecoder().decode(MovieChartSnapshot.self, from: data),
           value.kind == kind, Self.valid(value.records) { cached[kind] = value }
        if let value = cached[kind], Date().timeIntervalSince(value.fetchedAt) < 86_400 { return value }
        if (retryAfter[kind] ?? .distantPast) > Date() { return cached[kind] }
        if let task = pending[kind] { return await task.value }
        let task = Task { await self.fetch(kind) }
        pending[kind] = task
        let value = await task.value
        pending[kind] = nil
        return value
    }

    private func fetch(_ kind: MovieChartKind) async -> MovieChartSnapshot? {
        do {
            let value: MovieChartSnapshot
            if kind == .imdb { value = try Self.parseIMDb(await get(imdbURL)) }
            else {
                var records: [MovieChartRecord] = []
                for start in stride(from: 0, to: 250, by: 25) {
                    if start > 0 { try await Task.sleep(for: .milliseconds(350)) }
                    var parts = URLComponents(url: doubanURL, resolvingAgainstBaseURL: false)!
                    parts.queryItems = [.init(name: "start", value: String(start))]
                    let page = Self.parseDoubanPage(try await get(parts.url!))
                    guard page.count == 25 else { throw CatalogError("豆瓣榜单暂未完整返回。") }
                    records += page
                }
                value = MovieChartSnapshot(kind: kind, records: records, updatedAt: Date(), fetchedAt: Date(), stale: false)
            }
            guard Self.valid(value.records) else { throw CatalogError("榜单数据不完整。") }
            cached[kind] = value
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(value).write(to: file(kind), options: .atomic)
            return value
        } catch {
            retryAfter[kind] = Date().addingTimeInterval(1800)
            if var previous = cached[kind] { previous.stale = true; cached[kind] = previous }
            return cached[kind]
        }
    }

    private func file(_ kind: MovieChartKind) -> URL { directory.appendingPathComponent(kind.rawValue + ".json") }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("muxi/0.1 (+https://github.com/HectorGao/muxi-player)", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        if let session { (data, response) = try await session.data(for: request) }
        else { (data, response) = try await PublicNetwork.shared.data(for: request) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 3_000_000 else {
            throw CatalogError("榜单服务暂不可用。")
        }
        return data
    }

    static func valid(_ records: [MovieChartRecord]) -> Bool {
        let ids = records.compactMap(\.id)
        return records.count == 250 && Set(records.map(\.rank)) == Set(1...250) && Set(ids).count == ids.count &&
            records.allSatisfy { !$0.titles.isEmpty && $0.titles.allSatisfy { !$0.isEmpty } && (1880...2200).contains($0.year) }
    }

    public static func parseIMDb(_ data: Data) throws -> MovieChartSnapshot {
        struct Row: Decodable { let rank: Int; let id: String?; let title: String; let year: Int; let rating: Double?; let votes: Int? }
        struct Payload: Decodable { let updatedAt: String; let stale: Bool; let total: Int; let data: [Row] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let date = ISO8601DateFormatter().date(from: payload.updatedAt) ?? {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: payload.updatedAt)
        }(), payload.total == 250 else { throw CatalogError("IMDb 榜单日期或数量无效。") }
        let records = payload.data.map { row in
            MovieChartRecord(rank: row.rank, id: row.id, titles: [row.title], year: row.year,
                             rating: row.rating.flatMap { $0 > 0 && $0 <= 10 && $0.isFinite ? $0 : nil }, votes: row.votes)
        }
        guard valid(records), records.compactMap(\.id).allSatisfy(OnlineCatalogClient.isIMDbID) else {
            throw CatalogError("IMDb 榜单数据不完整。")
        }
        return MovieChartSnapshot(kind: .imdb, records: records, updatedAt: date, fetchedAt: Date(),
                                  stale: payload.stale || Date().timeIntervalSince(date) > 7 * 86_400)
    }

    public static func parseDoubanPage(_ data: Data) -> [MovieChartRecord] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        return captures("<li>\\s*<div class=\"item\">(.*?)</li>", in: html).compactMap { block in
            guard let rank = captures("<em[^>]*>([0-9]+)</em>", in: block).first.flatMap(Int.init),
                  let id = captures("https://movie\\.douban\\.com/subject/([0-9]+)/", in: block).first,
                  OnlineCatalogClient.isDoubanID(id),
                  let year = captures("<br\\s*/?>\\s*([0-9]{4})", in: block).first.flatMap(Int.init) else { return nil }
            let titles = captures("<span class=\"(?:title|other)\">(.*?)</span>", in: block)
                .flatMap { decoded($0).components(separatedBy: "/") }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let score = captures("<span class=\"rating_num\"[^>]*>([0-9.]+)</span>", in: block).first.flatMap(Double.init)
            let rating = score.flatMap { $0 > 0 && $0 <= 10 && $0.isFinite ? $0 : nil }
            let votes = captures("([0-9]+)人评价", in: block).first.flatMap(Int.init)
            return MovieChartRecord(rank: rank, id: id, titles: titles, year: year, rating: rating, votes: votes)
        }
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func decoded(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }
}
