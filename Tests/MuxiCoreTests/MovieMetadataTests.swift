import Foundation
import Testing
@testable import MuxiCore

@Suite(.serialized) struct MovieMetadataTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetadataProtocol.self]
        return URLSession(configuration: config)
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("muxi-metadata-" + UUID().uuidString) }
    private func movie(_ id: String = "film") -> MediaItem {
        var item = MediaItem(id: id, name: "肖申克的救赎")
        item.ProductionYear = 1994; item.ProviderIds = ["Douban": "1292052", "Imdb": "tt0111161"]
        return item
    }
    private func service(_ directory: URL) -> MovieRatings {
        MovieRatings(session: session(), directory: directory, imdbEndpoint: URL(string: "https://metadata.test/ratings")!,
                     cinemetaEndpoint: URL(string: "https://metadata.test")!, doubanEndpoint: URL(string: "https://metadata.test/subject")!)
    }
    private func reply(_ request: URLRequest) -> (Int, Data) {
        let object: Any
        if request.url!.path == "/ratings" {
            let ids = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.compactMap(\.value)
            object = ids.map { ["imdbId": $0, "rating": 9.3, "votes": 1234] as [String: Any] }
        } else {
            object = ["r": 0, "subject": ["id": "1292052", "rate": "9.7", "release_year": "1994"]]
        }
        return (200, try! JSONSerialization.data(withJSONObject: object))
    }

    @Test func bothRatingsPersistIndependentlyAndLegacyCacheAddsMissingProvider() async throws {
        MetadataProtocol.requests = []; MetadataProtocol.reply = reply
        let folder = directory(), item = movie()
        let ratings = service(folder)
        let pair = await ratings.ratings(for: item)
        #expect(pair.imdb?.value == 9.3 && pair.douban?.value == 9.7)
        #expect(MetadataProtocol.requests.count == 2)
        #expect(await service(folder).ratings(for: item) == pair)
        #expect(MetadataProtocol.requests.count == 2)
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        struct Legacy: Codable { let rating: MovieRating; let expires: Date }
        try JSONEncoder().encode(Legacy(rating: pair.imdb!, expires: Date().addingTimeInterval(86_400))).write(to: file)
        let upgraded = await service(folder).ratings(for: item)
        #expect(upgraded == pair)
        #expect(MetadataProtocol.requests.count == 3)
        #expect(MetadataProtocol.requests.last?.url?.path == "/j/subject_abstract")
    }

    @Test func providerFailurePreservesTheOtherScoreAndStaleScore() async throws {
        MetadataProtocol.requests = []; MetadataProtocol.reply = reply
        let folder = directory(), item = movie()
        let pair = await service(folder).ratings(for: item)
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var slot = json["douban"] as! [String: Any]; slot["expires"] = 0; json["douban"] = slot
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        MetadataProtocol.requests = []; MetadataProtocol.reply = { _ in (503, Data()) }
        #expect(await service(folder).ratings(for: item) == pair)
        #expect(MetadataProtocol.requests.count == 1)
        #expect(MetadataProtocol.requests[0].url?.path == "/j/subject_abstract")
    }

    @Test func summaryRequiresMatchingIdentityYearAndValidScore() throws {
        let url = URL(string: "https://movie.douban.com/subject/1292052/")!
        let data = reply(URLRequest(url: url)).1
        #expect(MovieRatings.parseDoubanSummary(data, id: "1292052", year: 1994, subjectURL: url)?.value == 9.7)
        #expect(MovieRatings.parseDoubanSummary(data, id: "9999", year: 1994, subjectURL: url) == nil)
        #expect(MovieRatings.parseDoubanSummary(data, id: "1292052", year: 2024, subjectURL: url) == nil)
        #expect(MovieRatings.parseDoubanSummary(Data("<html>challenge</html>".utf8), id: "1292052", year: nil, subjectURL: url) == nil)
    }

    @Test func titleLookupUsesYearAndEnglishAliasAndRejectsAmbiguity() async {
        var item = movie(); item.ProviderIds = nil
        MetadataProtocol.requests = []
        MetadataProtocol.reply = { request in
            if request.url!.path == "/j/subject_suggest" {
                #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value == "肖申克的救赎")
                return (200, Data(#"[{"id":"1292052","title":"肖申克的救赎","sub_title":"The Shawshank Redemption","year":"1994","type":"movie"}]"#.utf8))
            }
            if request.url!.path.hasPrefix("/catalog/") {
                #expect(request.url!.path.contains("The Shawshank Redemption"))
                return (200, Data(#"{"metas":[{"id":"tt0111161","name":"The Shawshank Redemption","releaseInfo":"1994"}]}"#.utf8))
            }
            return reply(request)
        }
        let pair = await service(directory()).ratings(for: item)
        #expect(pair.imdb?.value == 9.3 && pair.douban?.value == 9.7)
        MetadataProtocol.reply = { request in
            if request.url!.path == "/j/subject_suggest" {
                return (200, Data(#"[{"id":"1","title":"肖申克的救赎","year":"1994","type":"movie"},{"id":"2","title":"肖申克的救赎","year":"1994","type":"movie"}]"#.utf8))
            }
            return (200, Data(#"{"metas":[]}"#.utf8))
        }
        let missing = await service(directory()).ratings(for: item)
        #expect(!missing.hasValues)
    }

    @Test func bulkIMDbUsesAtMost100IDsAndReusesCache() async {
        MetadataProtocol.requests = []; MetadataProtocol.reply = reply
        let ratings = service(directory())
        let items = (1...201).map { number -> MediaItem in
            var item = MediaItem(id: String(number), name: "Film \(number)")
            item.ProviderIds = ["Imdb": String(format: "tt%07d", number)]
            return item
        }
        let result = await ratings.enriched(items, chart: nil, sort: .imdbRating)
        #expect(result.items.allSatisfy { $0.ExternalRatings?.imdb?.value == 9.3 })
        #expect(MetadataProtocol.requests.count == 3)
        #expect(MetadataProtocol.requests.allSatisfy { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.count <= 100 })
        _ = await ratings.enriched(items, chart: nil, sort: .imdbRating)
        #expect(MetadataProtocol.requests.count == 3)
    }

    @Test func incompleteIMDbReplyKeepsVerifiedScore() async throws {
        MetadataProtocol.requests = []; MetadataProtocol.reply = reply
        let folder = directory(), item = movie()
        let pair = await service(folder).ratings(for: item)
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var slot = json["imdb"] as! [String: Any]; slot["expires"] = 0; json["imdb"] = slot
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        MetadataProtocol.reply = { _ in (200, Data("[]".utf8)) }
        #expect(await service(folder).ratings(for: item) == pair)
    }

    @Test func sortingAndTop250MembershipUseSeparateVerifiedFields() {
        var a = movie("a"), b = movie("b"), c = movie("c")
        let url = URL(string: "https://www.imdb.com/title/tt0111161/")!
        a.ExternalRatings = MovieRatingSet(imdb: MovieRating(value: 9.0, source: "IMDb", votes: nil, url: url), douban: MovieRating(value: 8.0, source: "豆瓣", votes: nil, url: url))
        b.ExternalRatings = MovieRatingSet(imdb: MovieRating(value: 8.0, source: "IMDb", votes: nil, url: url), douban: MovieRating(value: 9.0, source: "豆瓣", votes: nil, url: url))
        c.CommunityRating = 10; b.ChartRanks = ["douban": 250]
        var filter = LibraryFilter(); filter.sort = .imdbRating
        #expect(filter.apply(to: [c, b, a]).map(\.id) == ["a", "b", "c"])
        filter.sort = .doubanRating
        #expect(filter.apply(to: [c, a, b]).map(\.id) == ["b", "a", "c"])
        filter.chart = .douban
        #expect(filter.apply(to: [a, b, c]).map(\.id) == ["b"])
        b.Type = "Series"
        #expect(filter.apply(to: [a, b, c]).isEmpty)
    }

    @Test func cmsClassifiesDramaAndAttributesExplicitScoresAndDirectRoutes() throws {
        let source = OnlineSource(name: "CMS", url: URL(string: "https://catalog.test")!)
        let page = try OnlineCatalogClient.parseCMSPage(["list": [
            ["vod_id": 1, "vod_name": "Film", "type_name": "剧情片", "vod_score": 1, "vod_douban_score": 9.7, "vod_douban_id": "1292052"],
            ["vod_id": 2, "vod_name": "Show", "type_name": "国产剧", "vod_score": 9.9],
            ["vod_id": 3, "vod_name": "Commentary", "type_name": "电影解说", "type_id_1": 1]
        ]], source: source)
        #expect(page.items.map { $0.media.Type } == ["Movie", "Series", "Video"])
        #expect(page.items[0].media.CommunityRating == 1)
        #expect(page.items[0].media.ExternalRatings?.douban?.value == 9.7)
        #expect(page.items[0].media.ExternalRatings?.douban?.attribution == "片源提供")
        #expect(page.items[1].media.ExternalRatings == nil)
        let routes = OnlineCatalogClient.parseRoutes(from: "网页$$$直链", urls: "正片$https://cdn.test/share/film$$$正片$https://cdn.test/film.m3u8?x=a$b")
        #expect(routes[0].name == "直链 · 2" && routes[0].episodes[0].url.query == "x=a$b")
    }

    @Test func presetsPreserveCustomSourcesAndDisabledChoiceWithoutDuplicateURLs() {
        var saved = OnlineSource.defaults[2]; saved.enabled = false
        let custom = OnlineSource(name: "My name", url: URL(string: OnlineSource.defaults[3].url.absoluteString.dropLast().description)!, enabled: false)
        let result = OnlineSource.mergingDefaults(into: [saved, custom])
        #expect(result.count == OnlineSource.defaults.count)
        #expect(result.prefix(2).allSatisfy { !$0.enabled })
        #expect(result[1].name == "My name")
        #expect(Set(result.map(\.id)).count == result.count)
    }

    private func doubanPage(start: Int) -> Data {
        Data((start + 1...start + 25).map { rank in
            "<li><div class=\"item\"><em class=\"\">\(rank)</em><a href=\"https://movie.douban.com/subject/\(rank)/\"><span class=\"title\">Film \(rank)</span></a><p>Director<br>1994 &nbsp;/ Country</p><span class=\"rating_num\" property=\"v:average\">9.1</span><span>1234人评价</span></div></li>"
        }.joined().utf8)
    }

    @Test func completeChartIsAtomicAndFailureKeepsPreviousSnapshot() async throws {
        let invalidScores = Data(String(data: doubanPage(start: 0), encoding: .utf8)!.replacingOccurrences(of: ">9.1<", with: ">99.1<").utf8)
        #expect(MovieCharts.parseDoubanPage(invalidScores).allSatisfy { $0.rating == nil })
        MetadataProtocol.requests = []
        MetadataProtocol.reply = { request in
            let start = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!)!
            return (200, doubanPage(start: start))
        }
        let folder = directory()
        let charts = MovieCharts(session: session(), directory: folder, doubanURL: URL(string: "https://metadata.test/top250")!)
        let snapshot = try #require(await charts.snapshot(.douban))
        #expect(snapshot.records.count == 250 && MetadataProtocol.requests.count == 10)
        _ = await charts.snapshot(.douban)
        #expect(MetadataProtocol.requests.count == 10)
        let old = MovieChartSnapshot(kind: .douban, records: snapshot.records, updatedAt: snapshot.updatedAt, fetchedAt: .distantPast, stale: false)
        try JSONEncoder().encode(old).write(to: folder.appendingPathComponent("douban.json"))
        MetadataProtocol.reply = { _ in (200, Data("<html>challenge</html>".utf8)) }
        let reopened = MovieCharts(session: session(), directory: folder, doubanURL: URL(string: "https://metadata.test/top250")!)
        let retained = try #require(await reopened.snapshot(.douban))
        #expect(retained.records == snapshot.records && retained.stale)
    }

    @Test func imdbSnapshotValidatesAll250RanksAndMatchesPartialIDsByTitleAndYear() throws {
        let rows = (1...250).map { rank -> [String: Any] in
            ["rank": rank, "id": rank == 1 ? "tt0111161" : NSNull(), "title": "Film \(rank)", "year": 1994, "rating": 9.0, "votes": 1234]
        }
        let object: [String: Any] = ["updatedAt": "2026-09-01T00:00:00.000Z", "stale": true, "total": 250, "data": rows]
        let snapshot = try MovieCharts.parseIMDb(JSONSerialization.data(withJSONObject: object))
        #expect(snapshot.stale && snapshot.records.count == 250)
        var item = MediaItem(id: "film", name: "Film 2"); item.ProductionYear = 1994
        #expect(snapshot.matches(in: [item])[item.id]?.rank == 2)
        let douban = MovieChartSnapshot(kind: .douban, records: [MovieChartRecord(rank: 1, id: "1292052", titles: ["中文片名", "Film 2"], year: 1994, rating: 9.7, votes: nil)], updatedAt: Date(), fetchedAt: Date(), stale: false)
        var chinese = MediaItem(id: "chinese", name: "中文片名"); chinese.ProductionYear = 1994; chinese.ProviderIds = ["Douban": "1292052"]
        #expect(snapshot.matches(in: [chinese], companion: douban)[chinese.id]?.rank == 2)
        item.ProductionYear = 2024
        #expect(snapshot.matches(in: [item]).isEmpty)
        var invalid = object; invalid["data"] = Array(rows.dropLast())
        #expect(throws: (any Error).self) { _ = try MovieCharts.parseIMDb(JSONSerialization.data(withJSONObject: invalid)) }
    }
}

private final class MetadataProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var reply: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        Self.requests.append(request)
        let (status, data) = Self.reply(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
