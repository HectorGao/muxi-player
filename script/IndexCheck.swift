import Foundation
import MuxiCore

final class IndexProtocol: URLProtocol {
    static var revision = 0
    static var fullRequests = 0
    static var deltaRequests = 0
    static var fail = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.fail { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let delta = value("MinDateLastSaved") != nil || value("MinDateLastSavedForUser") != nil
        let idsOnly = value("EnableImages") == "false"
        if delta { Self.deltaRequests += 1 } else if !idsOnly { Self.fullRequests += 1 }
        let ids = Self.revision == 0 ? ["a", "b"] : ["a", "c"]
        let filtered = delta ? ["a", "c"] : ids
        let items: [[String: Any]] = filtered.map { id in
            ["Id": id, "Name": "Film " + id, "Type": "Movie", "ProductionYear": Self.revision == 0 ? 2024 : 2025,
             "MediaStreams": [["Index": 0, "Type": "Video", "Width": 3840, "Height": 2160, "DeliveryUrl": "https://private.test/?api_key=must-not-cache"]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["Items": items, "TotalRecordCount": items.count])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor struct IndexCheck {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "IndexCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async {
        do {
            let directory = URL(filePath: ".local/index-check-" + UUID().uuidString)
            let auth = try JSONDecoder().decode(Authentication.self, from: Data(#"{"AccessToken":"secret-fixture-token","User":{"Id":"one","Name":"Test"}}"#.utf8))
            let base = URL(string: "https://index.test")!
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IndexProtocol.self]
            let client = EmbyClient(baseURL: base, deviceID: "index-check", connection: Connection(baseURL: base, authentication: auth), session: URLSession(configuration: config))
            let first = LibraryStore(indexCache: LibraryIndexCache(directory: directory))
            await first.prepareFilters(client: client, selection: "movies")
            try check(first.filterIndex?.count == 2 && IndexProtocol.fullRequests == 1, "initial complete index")
            first.resetBrowsing()
            await first.prepareFilters(client: client, selection: "movies")
            try check(IndexProtocol.fullRequests == 1, "navigation reuses metadata without a rescan")
            let reopened = LibraryStore(indexCache: LibraryIndexCache(directory: directory))
            await reopened.prepareFilters(client: client, selection: "movies")
            try check(reopened.filterIndex?.count == 2 && IndexProtocol.fullRequests == 1, "disk cache survives store recreation")
            IndexProtocol.revision = 1
            await reopened.prepareFilters(client: client, selection: "movies", force: true)
            try check(Set(reopened.filterIndex!.map(\.id)) == ["a", "c"] && reopened.filterIndex?.allSatisfy { $0.ProductionYear == 2025 } == true,
                      "incremental merge updates, adds and reconciles deleted IDs")
            try check(IndexProtocol.fullRequests == 1 && IndexProtocol.deltaRequests == 2, "incremental pass only asks for changed metadata")
            IndexProtocol.fail = true
            await reopened.prepareFilters(client: client, selection: "movies", force: true)
            try check(reopened.filterIndex?.count == 2 && reopened.indexError != nil, "network failure preserves usable cache")
            IndexProtocol.fail = false
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let text = try String(contentsOf: file, encoding: .utf8)
                try check(!text.contains("must-not-cache") && !text.contains(auth.AccessToken), "cache must not contain credentials or delivery URLs")
            }
            let other = LibraryStore(indexCache: LibraryIndexCache(directory: directory))
            await other.prepareFilters(client: client, selection: "series")
            try check(IndexProtocol.fullRequests == 2, "category scopes stay isolated")
            let anotherAuth = try JSONDecoder().decode(Authentication.self, from: Data(#"{"AccessToken":"other-token","User":{"Id":"two","Name":"Other"}}"#.utf8))
            let otherClient = EmbyClient(baseURL: base, deviceID: "index-check", connection: Connection(baseURL: base, authentication: anotherAuth), session: URLSession(configuration: config))
            await other.prepareFilters(client: otherClient, selection: "movies")
            try check(IndexProtocol.fullRequests == 3, "users on the same server never share private metadata")
            print("PASS: disk cache, navigation reuse, delta merge, removals, failed sync, URL redaction and category isolation")
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
}
