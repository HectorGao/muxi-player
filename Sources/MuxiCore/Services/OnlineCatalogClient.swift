import Foundation

public struct OnlineSource: Codable, Identifiable, Hashable {
    public enum Kind: String, Codable { case cms, archive }
    public let id: UUID
    public var name: String
    public let url: URL
    public let kind: Kind
    public var enabled: Bool
    public var collection: String?
    public var isDefault: Bool

    public init(id: UUID = UUID(), name: String, url: URL, kind: Kind = .cms,
                enabled: Bool = true, collection: String? = nil, isDefault: Bool = false) {
        self.id = id; self.name = name; self.url = url; self.kind = kind
        self.enabled = enabled; self.collection = collection; self.isDefault = isDefault
    }

    public static let defaults: [OnlineSource] = [
        .init(id: UUID(uuidString: "0FF267EA-B18C-44A7-A93A-9DF594211001")!, name: "Internet Archive · 电影",
              url: URL(string: "https://archive.org")!, kind: .archive, collection: "feature_films", isDefault: true),
        .init(id: UUID(uuidString: "0FF267EA-B18C-44A7-A93A-9DF594211002")!, name: "Prelinger · 纪录影像",
              url: URL(string: "https://archive.org")!, kind: .archive, collection: "prelinger", isDefault: true),
        .init(id: UUID(uuidString: "0FF267EA-B18C-44A7-A93A-9DF594211003")!, name: "360资源", url: URL(string: "https://360zy.com/api.php/provide/vod/")!, isDefault: true),
        .init(id: UUID(uuidString: "0FF267EA-B18C-44A7-A93A-9DF594211004")!, name: "红牛资源", url: URL(string: "https://www.hongniuzy2.com/api.php/provide/vod/")!, isDefault: true),
        .init(id: UUID(uuidString: "0FF267EA-B18C-44A7-A93A-9DF594211005")!, name: "极速资源", url: URL(string: "https://jszyapi.com/api.php/provide/vod/")!, isDefault: true),
        .init(id: UUID(uuidString: "0FF267EA-B18C-44A7-A93A-9DF594211006")!, name: "光速资源", url: URL(string: "https://api.guangsuapi.com/api.php/provide/vod/")!, isDefault: true),
        .init(id: UUID(uuidString: "0FF267EA-B18C-44A7-A93A-9DF594211007")!, name: "无尽资源", url: URL(string: "https://api.wujinapi.com/api.php/provide/vod/")!, isDefault: true),
        .init(id: UUID(uuidString: "0FF267EA-B18C-44A7-A93A-9DF594211008")!, name: "虎牙资源", url: URL(string: "https://www.huyaapi.com/api.php/provide/vod/")!, isDefault: true),
        .init(id: UUID(uuidString: "0FF267EA-B18C-44A7-A93A-9DF594211009")!, name: "火狐资源", url: URL(string: "https://hhzyapi.com/api.php/provide/vod/")!, isDefault: true)
    ]

    public static func mergingDefaults(into saved: [OnlineSource]) -> [OnlineSource] {
        func address(_ source: OnlineSource) -> String {
            var parts = URLComponents(url: source.url, resolvingAgainstBaseURL: false)!
            parts.host = parts.host?.lowercased(); parts.fragment = nil
            while parts.path.hasSuffix("/") { parts.path.removeLast() }
            return parts.string ?? source.url.absoluteString
        }
        return saved + defaults.filter { preset in
            !saved.contains { $0.id == preset.id || ($0.kind == preset.kind && $0.collection == preset.collection && address($0) == address(preset)) }
        }
    }
}

public struct OnlineItem: Codable, Identifiable, Hashable {
    public let sourceID: UUID
    public let remoteID: String
    public var media: MediaItem
    public var id: String { sourceID.uuidString + ":" + remoteID }
    public init(sourceID: UUID, remoteID: String, media: MediaItem) {
        self.sourceID = sourceID; self.remoteID = remoteID; self.media = media
    }
}

public struct OnlinePage {
    public let items: [OnlineItem]
    public let total: Int
    public let hasMore: Bool
}

public struct OnlineEpisode: Identifiable {
    public let name: String
    public let url: URL
    public var id: String { url.absoluteString }
    public init(name: String, url: URL) { self.name = name; self.url = url }
}

public struct OnlineRoute: Identifiable {
    public let name: String
    public let episodes: [OnlineEpisode]
    public var id: String { name }
    public init(name: String, episodes: [OnlineEpisode]) { self.name = name; self.episodes = episodes }
}

public struct OnlineCatalogClient {
    private let session: URLSession?
    public init(session: URLSession? = nil) { self.session = session }

    public static func checkedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw CatalogError("请输入有效的 HTTP 或 HTTPS 接口地址。")
        }
        return url
    }

    private func json(_ url: URL, allowArray: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("muxi/0.1 (+https://github.com/HectorGao/muxi-player)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: (Data, URLResponse)
        if let session { result = try await session.data(for: request) }
        else { result = try await PublicNetwork.shared.data(for: request) }
        let (data, response) = result
        guard let response = response as? HTTPURLResponse else {
            throw CatalogError("接口暂不可用，请检查地址与网络。")
        }
        guard (200..<300).contains(response.statusCode) else { throw CatalogError("接口返回 HTTP \(response.statusCode)，请稍后重试。") }
        guard data.count <= 8_000_000 else { throw CatalogError("接口返回的数据过大，请换用分页接口。") }
        let parsed = try JSONSerialization.jsonObject(with: data)
        if allowArray, let rows = parsed as? [[String: Any]] { return ["sources": rows] }
        guard let object = parsed as? [String: Any] else {
            throw CatalogError("接口未返回有效的 JSON 数据。")
        }
        return object
    }

    private func url(_ base: URL, query: [URLQueryItem]) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let names = Set(query.map(\.name))
        parts.queryItems = (parts.queryItems ?? []).filter { !names.contains($0.name) } + query
        return parts.url!
    }

    public func page(source: OnlineSource, search: String = "", page: Int = 1, since: Date? = nil) async throws -> OnlinePage {
        if source.kind == .archive {
            var query = "collection:\(source.collection ?? "feature_films") AND mediatype:movies AND NOT access-restricted-item:true"
            if !search.isEmpty {
                let terms = search.split(whereSeparator: \.isWhitespace).map { term in
                    let escaped = String(term).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    return "title:\"\(escaped)\""
                }
                query += " AND (" + terms.joined(separator: " AND ") + ")"
            }
            if let since { query += " AND publicdate:[\(ISO8601DateFormatter().string(from: since)) TO *]" }
            let object = try await json(url(source.url.appendingPathComponent("advancedsearch.php"), query: [
                .init(name: "q", value: query), .init(name: "output", value: "json"), .init(name: "rows", value: "24"),
                .init(name: "page", value: String(page)), .init(name: "sort[]", value: since == nil ? "downloads desc" : "publicdate desc"),
                .init(name: "fl[]", value: "identifier,title,description,year,publicdate,imdb-id")
            ]))
            guard let result = object["response"] as? [String: Any], let docs = result["docs"] as? [[String: Any]] else {
                throw CatalogError("公开片库返回了无法识别的数据。")
            }
            let items = docs.compactMap { record -> OnlineItem? in
                guard let id = record["identifier"] as? String, !id.isEmpty, let title = record["title"] as? String else { return nil }
                var media = MediaItem(id: source.id.uuidString + ":" + id, name: title)
                media.Overview = Self.text(record["description"])
                media.ProductionYear = Int(Self.text(record["year"]).prefix(4))
                media.DateCreated = record["publicdate"] as? String
                media.RemoteImageURL = source.url.appendingPathComponent("services/img").appendingPathComponent(id)
                if let imdb = record["imdb-id"] as? String, Self.isIMDbID(imdb) { media.ProviderIds = ["Imdb": imdb] }
                return OnlineItem(sourceID: source.id, remoteID: id, media: media)
            }
            let total = (result["numFound"] as? Int) ?? items.count
            return OnlinePage(items: items, total: total, hasMore: page * 24 < total && !docs.isEmpty)
        }
        var query = [URLQueryItem(name: "ac", value: "videolist"), .init(name: "pg", value: String(page))]
        if !search.isEmpty { query.append(.init(name: "wd", value: search)) }
        if let since { query.append(.init(name: "h", value: String(max(1, Int(ceil(Date().timeIntervalSince(since) / 3600)) + 1)))) }
        return try Self.parseCMSPage(await json(url(source.url, query: query)), source: source, page: page)
    }

    public static func parseCMSPage(_ object: [String: Any], source: OnlineSource, page: Int = 1) throws -> OnlinePage {
        if let list = object["list"], !(list is NSNull), !(list is [[String: Any]]) { throw CatalogError("采集接口的 list 字段格式无效。") }
        guard object.keys.contains("list") else { throw CatalogError("此地址不是苹果 CMS 采集接口。") }
        let rows = object["list"] as? [[String: Any]] ?? []
        let items = rows.compactMap { record -> OnlineItem? in
            let id = text(record["vod_id"]), name = text(record["vod_name"])
            guard !id.isEmpty, !name.isEmpty else { return nil }
            var media = MediaItem(id: source.id.uuidString + ":" + id, name: name, type: mediaType(record))
            media.Overview = text(record["vod_content"]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            media.ProductionYear = Int(text(record["vod_year"]).prefix(4))
            media.ProductionLocations = text(record["vod_area"]).components(separatedBy: CharacterSet(charactersIn: "/,、" )).filter { !$0.isEmpty }
            media.Genres = text(record["vod_class"]).components(separatedBy: CharacterSet(charactersIn: "/,、")).filter { !$0.isEmpty }
            media.RemoteImageURL = try? checkedURL(text(record["vod_pic"]))
            if let score = Double(text(record["vod_score"])), score.isFinite, score > 0, score <= 10 { media.CommunityRating = score }
            media.DateCreated = text(record["vod_time"])
            var ids: [String: String] = [:]
            let imdb = text(record["vod_imdb_id"])
            if isIMDbID(imdb) { ids["Imdb"] = imdb }
            let douban = text(record["vod_douban_id"])
            if isDoubanID(douban) { ids["Douban"] = douban }
            media.ProviderIds = ids
            var ratings = MovieRatingSet()
            if isDoubanID(douban), let score = validScore(record["vod_douban_score"]) {
                ratings.douban = MovieRating(value: score, source: "豆瓣", votes: nil,
                                             url: URL(string: "https://movie.douban.com/subject/\(douban)/")!, attribution: "片源提供")
            }
            if isIMDbID(imdb), let score = validScore(record["vod_imdb_score"]) {
                ratings.imdb = MovieRating(value: score, source: "IMDb", votes: nil,
                                           url: URL(string: "https://www.imdb.com/title/\(imdb)/")!, attribution: "片源提供")
            }
            if ratings.hasValues { media.ExternalRatings = ratings }
            return OnlineItem(sourceID: source.id, remoteID: id, media: media)
        }
        let total = Int(text(object["total"])) ?? items.count
        guard rows.isEmpty || !items.isEmpty else { throw CatalogError("接口中的影片字段无法识别。") }
        let pageCount = Int(text(object["pagecount"])) ?? max(1, Int(ceil(Double(total) / Double(max(1, items.count)))))
        return OnlinePage(items: items, total: total, hasMore: page < pageCount && !rows.isEmpty)
    }

    public func routes(for item: OnlineItem, source: OnlineSource) async throws -> [OnlineRoute] {
        if source.kind == .archive {
            let object = try await json(source.url.appendingPathComponent("metadata").appendingPathComponent(item.remoteID))
            guard let files = object["files"] as? [[String: Any]] else { throw CatalogError("此条目暂未提供媒体文件。") }
            let episodes = files.compactMap { file -> OnlineEpisode? in
                guard file["private"] as? String != "true", file["private"] as? Bool != true,
                      let name = file["name"] as? String,
                      ["mp4", "webm", "mkv", "ogv"].contains((name as NSString).pathExtension.lowercased()) else { return nil }
                let url = source.url.appendingPathComponent("download").appendingPathComponent(item.remoteID).appendingPathComponent(name)
                return OnlineEpisode(name: name, url: url)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !episodes.isEmpty else { throw CatalogError("此条目没有可直接播放的公开视频文件。") }
            return episodes.map { OnlineRoute(name: $0.name, episodes: [$0]) }
        }
        let object = try await json(url(source.url, query: [.init(name: "ac", value: "videolist"), .init(name: "ids", value: item.remoteID)]))
        guard let rows = object["list"] as? [[String: Any]], let record = rows.first else { throw CatalogError("影片详情暂不可用。") }
        let routes = Self.parseRoutes(from: Self.text(record["vod_play_from"]), urls: Self.text(record["vod_play_url"]))
        guard !routes.isEmpty else { throw CatalogError("接口没有提供可播放的 HTTP 媒体地址。") }
        return routes
    }

    public static func parseRoutes(from: String, urls: String) -> [OnlineRoute] {
        let names = from.components(separatedBy: "$$$")
        let routes = urls.components(separatedBy: "$$$").enumerated().compactMap { index, group -> OnlineRoute? in
            let episodes = group.components(separatedBy: "#").enumerated().compactMap { offset, value -> OnlineEpisode? in
                let parts = value.split(separator: "$", maxSplits: 1).map(String.init)
                guard let raw = parts.last, let url = try? checkedURL(raw) else { return nil }
                return OnlineEpisode(name: parts.count == 2 ? parts[0] : "第 \(offset + 1) 集", url: url)
            }
            guard !episodes.isEmpty else { return nil }
            let name = names.indices.contains(index) && !names[index].isEmpty ? names[index] : "线路 \(index + 1)"
            return OnlineRoute(name: "\(name) · \(index + 1)", episodes: episodes)
        }
        let files: Set<String> = ["m3u8", "mp4", "mkv", "webm", "mpd", "mov", "avi", "ts", "flv", "m4v"]
        func direct(_ route: OnlineRoute) -> Bool { route.episodes.allSatisfy { files.contains($0.url.pathExtension.lowercased()) } }
        return routes.filter(direct) + routes.filter { !direct($0) }
    }

    public func subscription(_ address: String) async throws -> [OnlineSource] {
        let object = try await json(Self.checkedURL(address), allowArray: true)
        let rows = object["vodSources"] as? [[String: Any]] ?? object["sources"] as? [[String: Any]] ?? object["sites"] as? [[String: Any]] ?? []
        var known = Set<URL>()
        let sources = rows.prefix(100).compactMap { row -> OnlineSource? in
            let raw = Self.text(row["url"] ?? row["api"])
            guard let url = try? Self.checkedURL(raw), !["js", "jar", "py"].contains(url.pathExtension.lowercased()),
                  let rawName = row["name"] as? String else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            if let type = Int(Self.text(row["type"])), type != 1 { return nil }
            guard known.insert(url).inserted else { return nil }
            return OnlineSource(name: name, url: url)
        }
        guard !sources.isEmpty else { throw CatalogError("订阅中没有可导入的苹果 CMS JSON 接口。") }
        return sources
    }

    public static func isIMDbID(_ value: String) -> Bool { value.range(of: "^tt[0-9]{7,12}$", options: .regularExpression) != nil }
    public static func isDoubanID(_ value: String) -> Bool { value.range(of: "^[1-9][0-9]{0,11}$", options: .regularExpression) != nil }
    private static func validScore(_ value: Any?) -> Double? {
        guard let score = Double(text(value)), score.isFinite, score > 0, score <= 10 else { return nil }
        return score
    }
    private static func mediaType(_ record: [String: Any]) -> String {
        let name = text(record["type_name"])
        if name.contains("解说") || name.contains("预告") { return "Video" }
        let parent = Int(text(record["type_id_1"] ?? record["type_pid"]))
        if parent == 1 { return "Movie" }
        if parent == 2 || name.hasSuffix("剧") || name.contains("连续剧") || name.contains("剧集") || name.contains("综艺") || name.hasSuffix("动漫") { return "Series" }
        return "Movie"
    }
    private static func text(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        if let values = value as? [String] { return values.joined(separator: " · ") }
        return ""
    }
}

public struct CatalogError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
