import Foundation
import Testing
@testable import MuxiCore

@Suite(.serialized) struct OnlineCatalogTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnlineFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    private var source: OnlineSource { OnlineSource(name: "Test source", url: URL(string: "https://catalog.test/cms")!) }

    @Test func cmsParsingHandlesNumbersAndNullWithoutInventingScores() throws {
        let object: [String: Any] = ["list": [["vod_id": 7, "vod_name": "海洋", "vod_year": 2024, "vod_score": "8.2", "vod_imdb_id": "tt1856101", "vod_douban_id": 12345]], "total": "1"]
        let page = try OnlineCatalogClient.parseCMSPage(object, source: source)
        #expect(page.items.first?.remoteID == "7")
        #expect(page.items.first?.media.ProductionYear == 2024)
        #expect(page.items.first?.media.ProviderIds?["Imdb"] == "tt1856101")
        #expect(page.items.first?.media.CommunityRating == 8.2)
        #expect(try OnlineCatalogClient.parseCMSPage(["list": NSNull()], source: source).items.isEmpty)
        #expect(throws: (any Error).self) { _ = try OnlineCatalogClient.parseCMSPage(["list": "bad"], source: source) }
        #expect(throws: (any Error).self) { _ = try OnlineCatalogClient.parseCMSPage(["list": [["unknown": "x"]]], source: source) }
        #expect(try !OnlineCatalogClient.parseCMSPage(["list": [["vod_id": 1, "vod_name": "Unknown total"]]], source: source).totalIsExact)
    }

    @Test func routesKeepLinesEpisodesAndQuerySignatures() throws {
        let routes = OnlineCatalogClient.parseRoutes(from: "原画$$$备用$$$无效", urls: "第1集$https://cdn.test/a.m3u8?signature=x$y#第2集$https://cdn.test/b.mp4$$$正片$https://cdn.test/c.mkv$$$坏链接$file:///etc/passwd")
        #expect(routes.count == 2)
        #expect(routes[0].episodes.count == 2)
        #expect(routes[0].episodes[0].name == "第1集")
        #expect(routes[0].episodes[0].url.query == "signature=x$y")
        for value in ["file:///tmp/a", "javascript:alert(1)", "https://user:password@test/a", "ftp://test/a", ""] {
            #expect(throws: (any Error).self) { _ = try OnlineCatalogClient.checkedURL(value) }
        }
        #expect(try OnlineCatalogClient.checkedURL("http://127.0.0.1:8765/api").port == 8765)
    }

    @Test func categoriesUseNamesAndParentsInsteadOfFixedMovieAndSeriesIDs() throws {
        let categories = [OnlineCategory(id: "1", name: "电视剧"), OnlineCategory(id: "2", name: "电影"),
                          OnlineCategory(id: "6", name: "动作片", parentID: "2"), OnlineCategory(id: "9", name: "国产剧", parentID: "1"),
                          OnlineCategory(id: "5", name: "动漫电影"), OnlineCategory(id: "10", name: "其他", parentID: "6"),
                          OnlineCategory(id: "11", name: "电影解说"), OnlineCategory(id: "12", name: "体育赛事")]
        #expect(OnlineCategory.ids(for: .movies, in: categories) == ["2", "6", "5", "10"])
        #expect(OnlineCategory.ids(for: .series, in: categories) == ["1", "9"])
        let rows = [["vod_id": "tv", "vod_name": "剧", "type_id": "9", "type_id_1": "1"],
                    ["vod_id": "movie", "vod_name": "片", "type_id": "10", "type_id_1": "2"]]
        let page = try OnlineCatalogClient.parseCMSPage(["list": rows], source: source, categories: categories)
        #expect(page.items.map { $0.media.Type } == ["Series", "Movie"])
        #expect(OnlineCategory.ids(for: .movies, in: [OnlineCategory(id: "7", name: "电影"), OnlineCategory(id: "8", name: "连续剧")]) == ["7"])
        #expect(OnlineCategory.ids(for: .movies, in: [OnlineCategory(id: "50", name: "剧情片"), OnlineCategory(id: "51", name: "国产剧")]) == ["50"])
        #expect(OnlineCategory.mediaType(id: "a", in: [OnlineCategory(id: "a", name: "未知", parentID: "b"), OnlineCategory(id: "b", name: "未知", parentID: "a")]) == nil)
    }

    @Test func incrementalCMSRequestPreservesAuthenticationParameters() async throws {
        let client = OnlineCatalogClient(session: session())
        let source = OnlineSource(name: "Fixture", url: URL(string: "https://catalog.test/cms?token=example")!)
        let page = try await client.page(source: source, search: "海洋 & moon", since: Date().addingTimeInterval(-7200))
        #expect(page.items.count == 1)
        let request = try #require(OnlineFixtureProtocol.requests.last)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "wd" }?.value == "海洋 & moon")
        #expect(query.first { $0.name == "ac" }?.value == "videolist")
        #expect(query.first { $0.name == "token" }?.value == "example")
        #expect(Int(query.first { $0.name == "h" }!.value!)! >= 3)
        let scoped = try await client.page(source: source, categoryID: "2")
        #expect(!scoped.totalIsExact)
        #expect(URLComponents(url: OnlineFixtureProtocol.requests.last!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "t" }?.value == "2")
    }

    @Test func archiveFilesAreAlternativeRoutesAndPrivateFilesAreExcluded() async throws {
        let client = OnlineCatalogClient(session: session())
        let source = OnlineSource(name: "Archive", url: URL(string: "https://catalog.test")!, kind: .archive, collection: "feature_films")
        let page = try await client.page(source: source, search: "Night \"Film\"")
        #expect(page.items.count == 1)
        let routes = try await client.routes(for: page.items[0], source: source)
        #expect(routes.count == 2)
        #expect(routes.allSatisfy { $0.episodes.count == 1 })
        #expect(routes.flatMap(\.episodes).allSatisfy { !$0.url.absoluteString.contains("private") })
    }

    @Test func subscriptionsImportJSONSourcesAndSkipExecutableEntries() async throws {
        let client = OnlineCatalogClient(session: session())
        for path in ["subscription", "subscription-array"] {
            let sources = try await client.subscription("https://catalog.test/" + path)
            #expect(sources.count == 1)
            #expect(sources[0].name == "JSON source")
        }
    }

    @Test func ratingsRequireExactTitleAndYearAndRejectAmbiguity() throws {
        var item = MediaItem(id: "dune", name: "Dune (2021)")
        item.ProductionYear = 2021
        let candidates: [[String: Any]] = [["id": "tt0087182", "name": "Dune", "releaseInfo": "1984"], ["id": "tt1160419", "name": "Dune", "releaseInfo": "2021"]]
        #expect(MovieRatings.matchIMDbID(item: item, candidates: candidates) == "tt1160419")
        #expect(MovieRatings.matchIMDbID(item: item, candidates: candidates + [["id": "tt9999999", "name": "Dune", "releaseInfo": "2021"]]) == nil)
        #expect(MovieRatings.matchIMDbID(item: item, candidates: [["id": "tt1234567", "name": "Dune Part Two", "releaseInfo": "2021"]]) == nil)
        item.ProductionYear = nil
        #expect(MovieRatings.matchIMDbID(item: item, candidates: candidates) == nil)
    }

    @Test func verifiedRatingIsCachedAcrossRestartsAndNoEmbyHeadersLeak() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muxi-rating-" + UUID().uuidString)
        var item = MediaItem(id: "film", name: "Dune")
        item.ProviderIds = ["Imdb": "tt1160419", "Douban": "12345"]
        let before = OnlineFixtureProtocol.requests.count
        let ratings = MovieRatings(session: session(), directory: directory, imdbEndpoint: URL(string: "https://catalog.test/ratings")!,
                                   doubanEndpoint: URL(string: "https://catalog.test/subject")!)
        let first = await ratings.rating(for: item)
        #expect(first?.source == "IMDb" && first?.value == 8.0)
        let after = OnlineFixtureProtocol.requests.count
        #expect(after == before + 2)
        #expect(await ratings.rating(for: item) == first)
        let restored = MovieRatings(session: session(), directory: directory, imdbEndpoint: URL(string: "https://catalog.test/ratings")!)
        #expect(await restored.rating(for: item) == first)
        #expect(OnlineFixtureProtocol.requests.count == after)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(try String(contentsOf: files[0], encoding: .utf8).contains("IMDb"))
    }

    @Test func doubanStructuredRatingAndChallengeAreDistinguished() {
        let html = #"<script type="application/ld+json">{"aggregateRating":{"ratingValue":"9.2","ratingCount":123}}</script>"#
        let url = URL(string: "https://movie.douban.com/subject/12345/")!
        let rating = MovieRatings.parseDouban(Data(html.utf8), subjectURL: url)
        #expect(rating?.value == 9.2 && rating?.votes == 123 && rating?.source == "豆瓣")
        #expect(MovieRatings.parseDouban(Data("<html>载入中</html>".utf8), subjectURL: url) == nil)
    }

    @Test func networkFailureRetriesConfiguredProxyAndReusesIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimeoutFixtureProtocol.self]
        let network = PublicNetwork(primary: URLSession(configuration: configuration), fallback: session())
        let request = URLRequest(url: URL(string: "https://catalog.test/ratings")!)
        let first = try await network.data(for: request)
        #expect((first.1 as? HTTPURLResponse)?.statusCode == 200)
        let attempts = TimeoutFixtureProtocol.attempts
        _ = try await network.data(for: request)
        #expect(TimeoutFixtureProtocol.attempts == attempts)
        var post = request; post.httpMethod = "POST"
        let isolated = PublicNetwork(primary: URLSession(configuration: configuration), fallback: session())
        do { _ = try await isolated.data(for: post); Issue.record("A failed POST was replayed") }
        catch { #expect((error as NSError).code == NSURLErrorTimedOut) }
    }

    @Test func boundedWebsiteRequestsReuseThePublicNetworkRetryPolicy() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimeoutFixtureProtocol.self]
        let network = PublicNetwork(primary: URLSession(configuration: configuration), fallback: session())
        let (bytes, response) = try await network.bytes(for: URLRequest(url: URL(string: "https://catalog.test/ratings")!))
        defer { bytes.task.cancel() }
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && !data.isEmpty)
        let attempts = TimeoutFixtureProtocol.attempts
        let (again, _) = try await network.bytes(for: URLRequest(url: URL(string: "https://catalog.test/ratings")!))
        again.task.cancel()
        #expect(TimeoutFixtureProtocol.attempts == attempts)
    }
}

private final class TimeoutFixtureProtocol: URLProtocol {
    static var attempts = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.attempts += 1
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() { }
}

private final class OnlineFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.recorded.append(request); Self.lock.unlock()
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        let path = request.url!.path
        let rows: [[String: Any]] = [["name": "Skip spider", "api": "https://cms.test/api", "type": "3"],
                                   ["name": "JSON source", "api": "https://cms.test/api", "type": 1],
                                   ["name": "Duplicate", "url": "https://cms.test/api"],
                                   ["name": "Script", "api": "https://cms.test/spider.js?token=example"]]
        let object: Any
        if path == "/subscription-array" { object = rows }
        else if path == "/subscription" { object = ["sites": rows] }
        else if path == "/ratings" { object = [["imdbId": "tt1160419", "rating": 8.0, "votes": 1234]] }
        else if path.hasPrefix("/subject/") { object = ["challenge": true] }
        else if path == "/advancedsearch.php" { object = ["response": ["numFound": 1, "docs": [["identifier": "film", "title": "Night Film", "year": 1968]]]] }
        else if path == "/metadata/film" { object = ["files": [["name": "film 720p.mp4"], ["name": "film.webm"], ["name": "private.mp4", "private": true], ["name": "readme.txt"]]] }
        else { object = ["list": [["vod_id": 1, "vod_name": "海洋 & moon"]], "total": 1] }
        let data = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
