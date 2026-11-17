import Foundation
import CryptoKit
import MuxiCore

@MainActor func checkCatalogPaging() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CatalogFixtureProtocol.self]
    let client = OnlineCatalogClient(session: URLSession(configuration: configuration))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muxi-catalog-" + UUID().uuidString)
    let source = OnlineSource(name: "Large fixture", url: URL(string: "https://catalog.fixture/api")!)
    let store = OnlineLibraryStore(client: client, directory: directory)
    let require = OnlineCheck.require

    struct Legacy: Encodable {
        var items: [OnlineItem]; var total: Int; var page: Int; var hasMore: Bool; var checkedAt: Date; var reconciledAt: Date
    }
    let oldItems = (1...67).map { OnlineItem(sourceID: source.id, remoteID: "old-\($0)", media: MediaItem(id: source.id.uuidString + ":old-\($0)", name: "Cached \($0)")) }
    let legacy = Legacy(items: oldItems, total: 118_596, page: 2, hasMore: true, checkedAt: Date(), reconciledAt: Date())
    let key = SHA256.hash(data: Data([source.id.uuidString, source.url.absoluteString, "", ""].joined(separator: "\n").utf8))
        .map { String(format: "%02x", $0) }.joined()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent(key + ".json"))
    let before = CatalogFixtureProtocol.queries.count
    await store.load(source, search: "")
    try require(store.state(source, search: "").items.count == 67 && store.state(source, search: "").total == 118_596, "Legacy 67-row cache lost its catalog total")
    try require(CatalogFixtureProtocol.queries.count == before && store.state(source, search: "").fromCache, "A fresh legacy cache queried the network")
    await store.load(source, search: "", force: true)
    try require(store.state(source, search: "").page == 2 && store.state(source, search: "").total == 118_596, "Incremental count replaced the full catalog total or advanced its cursor")
    await store.load(source, search: "", more: true)
    try require(CatalogFixtureProtocol.queries.last?["pg"] == "3" && CatalogFixtureProtocol.queries.last?["h"] == nil, "Normal paging reused the incremental cursor")

    CatalogFixtureProtocol.failDrama = true
    await store.load(source, search: "", scope: .movies)
    var state = store.state(source, search: "", scope: .movies)
    try require(state.items.count == 3 && state.error != nil && !state.totalIsExact && state.hasMore, "Partial category failure hid good results or claimed a complete total")
    try require(state.items.allSatisfy { $0.media.Type == "Movie" } && !state.items.contains { $0.remoteID.hasPrefix("old-") }, "Scoped cache reused mixed legacy rows")
    let firstQueries = CatalogFixtureProtocol.queries.count
    CatalogFixtureProtocol.failDrama = false
    await store.load(source, search: "", scope: .movies, force: true)
    state = store.state(source, search: "", scope: .movies)
    try require(state.error == nil && state.totalIsExact && state.total == 13_001 && state.items.count == 4, "Retry did not repair the partial scope")
    try require(CatalogFixtureProtocol.queries.dropFirst(firstQueries).allSatisfy { $0["t"] == "7" }, "Retry refetched already successful categories")
    let page = state.page
    CatalogFixtureProtocol.failActionPage = 2
    await store.load(source, search: "", scope: .movies, more: true)
    try require(store.state(source, search: "", scope: .movies).page == page && store.state(source, search: "", scope: .movies).error != nil, "A failed next page advanced the cursor")
    CatalogFixtureProtocol.failActionPage = nil
    let retryQuery = CatalogFixtureProtocol.queries.count
    await store.load(source, search: "", scope: .movies, force: true)
    try require(CatalogFixtureProtocol.queries.dropFirst(retryQuery).allSatisfy { $0["t"] == "6" && $0["pg"] == "2" && $0["h"] == nil }, "Retry skipped the failed normal page")
    state = store.state(source, search: "", scope: .movies)
    try require(state.items.count == 4 && state.page > page && state.hasMore, "A duplicate page stalled pagination")
    await store.load(source, search: "", scope: .movies, more: true)
    try require(store.state(source, search: "", scope: .movies).items.count == 5, "Paging stopped at a duplicate page")
    let restored = OnlineLibraryStore(client: client, directory: directory)
    await restored.load(source, search: "", scope: .movies)
    try require(restored.state(source, search: "", scope: .movies).fromCache && restored.state(source, search: "", scope: .movies).page == 5, "Per-category cursor was lost on restart")
    await store.load(source, search: "", scope: .series)
    try require(store.state(source, search: "", scope: .series).items.allSatisfy { $0.media.Type == "Series" } && store.state(source, search: "", scope: .series).total == 2, "Swapped category IDs mixed movies and series")
    let restricted = OnlineSource(name: "Restricted", url: URL(string: "https://catalog.fixture/api?t=6,7")!)
    await store.load(restricted, search: "", scope: .movies)
    try require(store.state(restricted, search: "", scope: .movies).total == 13_000, "Scoped paging expanded a custom source's category restriction")
    await store.load(source, search: "海洋", scope: .movies)
    try require(CatalogFixtureProtocol.queries.last?["wd"] == "海洋", "Scoped keyword was not sent to the API")
    try require(store.state(source, search: "", scope: .movies).items.count == 5, "A new keyword replaced the previous scope cache")
    let scopeKey = SHA256.hash(data: Data([source.id.uuidString, source.url.absoluteString, "", "", "movies"].joined(separator: "\n").utf8))
        .map { String(format: "%02x", $0) }.joined()
    let scopeFile = directory.appendingPathComponent(scopeKey + ".json")
    var snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: scopeFile)) as! [String: Any]
    var partitions = snapshot["partitions"] as! [String: [String: Any]]
    for id in Array(partitions.keys) { partitions[id]!["reconciledAt"] = 0 }
    snapshot["partitions"] = partitions
    try JSONSerialization.data(withJSONObject: snapshot).write(to: scopeFile)
    CatalogFixtureProtocol.removeOldItem = true
    let reconciled = OnlineLibraryStore(client: client, directory: directory)
    await reconciled.load(source, search: "", scope: .movies, force: true)
    try require(reconciled.state(source, search: "", scope: .movies).items.count == 4 && reconciled.state(source, search: "", scope: .movies).total == 13_000, "Daily reconciliation retained a removed movie or stale total")
    CatalogFixtureProtocol.removeOldItem = false
    print("PASS: legacy 67-row cache, full totals, scoped categories, partial retry, deduplication and independent paging cursors")
}

private final class CatalogFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [[String: String]] = []
    private static var failing = false
    private static var actionPage: Int?
    private static var removing = false
    static var queries: [[String: String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    static var failDrama: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); defer { lock.unlock() }; failing = newValue }
    }
    static var failActionPage: Int? {
        get { lock.lock(); defer { lock.unlock() }; return actionPage }
        set { lock.lock(); defer { lock.unlock() }; actionPage = newValue }
    }
    static var removeOldItem: Bool {
        get { lock.lock(); defer { lock.unlock() }; return removing }
        set { lock.lock(); defer { lock.unlock() }; removing = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        Self.lock.lock(); Self.recorded.append(query); Self.lock.unlock()
        if query["t"] == "7", Self.failDrama { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        if query["t"] == "6", Int(query["pg"] ?? "1") == Self.failActionPage { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let categories: [[String: Any]] = [["type_id": 1, "type_name": "电视剧"], ["type_id": 2, "type_name": "电影"],
                                         ["type_id": 6, "type_pid": 2, "type_name": "动作片"], ["type_id": 7, "type_pid": 2, "type_name": "剧情片"]]
        let category = query["t"] ?? "", page = Int(query["pg"] ?? "1") ?? 1
        let ids: [Int]
        let total: Int
        let pages: Int
        switch category {
        case "1": ids = [11, 12]; total = 2; pages = 1
        case "2": ids = [21]; total = 1; pages = 1
        case "6": ids = page < 3 ? Self.removeOldItem ? [61] : [61, 62] : [63]; total = Self.removeOldItem ? 4_999 : 5_000; pages = 250
        case "7": ids = [71]; total = 8_000; pages = 1
        default: ids = [999]; total = query["h"] == nil ? 118_596 : 1; pages = query["h"] == nil ? 5930 : 1
        }
        let rows: [[String: Any]] = ids.map { ["vod_id": $0, "vod_name": "Fixture \($0)", "type_id": category, "type_name": "未知"] }
        let object: [String: Any] = query["ac"] == "list" ? ["class": categories, "list": []] : ["list": rows, "total": total, "pagecount": pages]
        let data = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
