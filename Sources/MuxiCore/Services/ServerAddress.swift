import Foundation

public enum EmbyError: Error, LocalizedError, Equatable {
    case invalidAddress, invalidResponse, unauthorized, forbidden, webChallenge, http(Int), noPlayableSource, conversionUnavailable, unsafeURL

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入完整的 http:// 或 https:// 服务器地址，不要包含账号、密码或查询参数。"
        case .invalidResponse: return "服务器返回了无法识别的数据，请确认地址指向 Emby 或 Jellyfin。"
        case .unauthorized: return "账号或密码不正确，或登录已过期。请重新连接。"
        case .forbidden: return "服务器拒绝了此请求（HTTP 403）。请检查账号权限及服务器的客户端访问限制。"
        case .webChallenge: return "服务器返回了网页验证或拦截，尚未取得 Emby 接口响应。请向服务商确认此客户端的接入方式或 API 地址。"
        case .http(let code): return "服务器请求失败（HTTP \(code)），请稍后重试。"
        case .noPlayableSource: return "没有可播放的视频流。请尝试原始画质、关闭字幕，或检查服务器的转码权限。"
        case .conversionUnavailable: return "此账号不允许服务器转码或转封装，无法应用所选字幕、音轨或画质。请恢复原始播放。"
        case .unsafeURL: return "服务器返回了不安全的播放地址。"
        }
    }

    public static func message(_ error: Error) -> String {
        if let error = error as? EmbyError { return error.localizedDescription }
        if error is DecodingError { return EmbyError.invalidResponse.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "连接超时，请检查服务器地址和网络后重试。"
            case .notConnectedToInternet: return "当前网络不可用。"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate: return "无法验证服务器的 HTTPS 证书。请修复服务器证书后重试。"
            case .cancelled: return "操作已取消。"
            default: return "无法连接服务器，请检查地址、网络和代理设置。"
            }
        }
        return "操作失败，请重试。"
    }
}

public enum ServerAddress {
    public static func normalize(_ input: String) throws -> URL {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!) else { throw EmbyError.invalidAddress }
        parts.scheme = parts.scheme?.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard !parts.path.split(separator: "/").contains(".."), let url = parts.url else { throw EmbyError.invalidAddress }
        return url
    }

    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }

    public static func endpoint(base: URL, path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url!
    }

    public static func stream(_ raw: String, base: URL, token: String, serverKind: MediaServerKind = .emby) throws -> URL {
        guard let given = URLComponents(string: raw), given.user == nil, given.password == nil else { throw EmbyError.unsafeURL }
        let url: URL
        if given.scheme != nil || given.host != nil {
            guard let absolute = given.url, ["http", "https"].contains(absolute.scheme?.lowercased() ?? ""),
                  absolute.host != nil, !(base.scheme == "https" && absolute.scheme == "http") else { throw EmbyError.unsafeURL }
            url = absolute
        } else {
            var path = given.path
            let prefix = base.path
            if !prefix.isEmpty, path.hasPrefix(prefix + "/") {
                path = String(path.dropFirst(prefix.count))
            } else if prefix.hasSuffix("/emby"), path.hasPrefix("/emby/") {
                path = String(path.dropFirst(5))
            }
            url = endpoint(base: base, path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), query: given.queryItems ?? [])
        }
        // CDN links keep their own signature; never send the Emby token to another origin.
        guard sameOrigin(base, url) else { return url }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var query = parts.queryItems ?? []
        query.removeAll { ["api_key", "apikey"].contains($0.name.lowercased()) }
        query.append(URLQueryItem(name: serverKind == .jellyfin ? "ApiKey" : "api_key", value: token))
        parts.queryItems = query
        return parts.url!
    }
}

final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url, ServerAddress.sameOrigin(original, target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
