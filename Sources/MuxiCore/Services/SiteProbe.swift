import Foundation

public struct SiteProbe {
    private let session: URLSession
    private let catalog: OnlineCatalogClient
    private let network: PublicNetwork

    public init(session: URLSession? = nil, catalog: OnlineCatalogClient? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
        let network = PublicNetwork(primary: self.session)
        self.network = network
        self.catalog = catalog ?? OnlineCatalogClient(network: network)
    }

    public func check(_ site: ViewingSite) async throws -> SiteHealth {
        let start = Date()
        do {
            _ = try ViewingSite.checkedURL(site.url.absoluteString)
            if site.kind == .cms || site.kind == .archive {
                _ = try await catalog.page(source: OnlineSource(id: site.id, name: site.name, url: site.url,
                                                               kind: site.kind == .archive ? .archive : .cms, collection: site.collection))
            } else {
                let server = site.kind == .emby || site.kind == .jellyfin
                let url = server ? ServerAddress.endpoint(base: site.url, path: "System/Info/Public") : site.url
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                request.setValue("Mozilla/5.0 (Macintosh) muxi/0.1", forHTTPHeaderField: "User-Agent")
                let (bytes, response) = try await (server ? session.bytes(for: request) : network.bytes(for: request))
                defer { bytes.task.cancel() }
                guard let response = response as? HTTPURLResponse else { throw CatalogError("响应格式无效") }
                guard (200..<300).contains(response.statusCode) else { throw CatalogError("HTTP \(response.statusCode)") }
                var prefix = Data()
                for try await byte in bytes {
                    prefix.append(byte)
                    if prefix.count >= 32_768 { break }
                }
                try Self.validate(prefix, response: response, server: server)
            }
            try Task.checkCancellation()
            return SiteHealth(status: .online, milliseconds: max(1, Int(Date().timeIntervalSince(start) * 1000)), checkedAt: Date())
        } catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw error }
            let offline = error is URLError
            let message = (error as? CatalogError)?.localizedDescription ?? (offline ? "连接超时或网络不可达" : "接口或页面格式异常")
            return SiteHealth(status: offline ? .offline : .error, checkedAt: Date(), message: message)
        }
    }

    static func validate(_ data: Data, response: HTTPURLResponse, server: Bool) throws {
        if server {
            guard let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = info["Id"] as? String, !id.isEmpty, info["Version"] is String else {
                throw CatalogError("公共接口未返回 Emby / Jellyfin 数据")
            }
            return
        }
        let html = String(decoding: data, as: UTF8.self).lowercased()
        if response.value(forHTTPHeaderField: "cf-mitigated") == "challenge" || html.contains("/cdn-cgi/challenge-platform/") {
            throw CatalogError("站点需要网页验证")
        }
        if html.contains("domain is for sale") || html.contains("buy this domain") || html.contains("sedoparking.com") {
            throw CatalogError("域名停放页")
        }
        guard !data.isEmpty, response.mimeType?.contains("html") == true else { throw CatalogError("未返回观影网页") }
    }
}
