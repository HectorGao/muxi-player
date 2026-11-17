import Foundation
import CFNetwork

public actor PublicNetwork {
    public static let shared = PublicNetwork()
    private let primary: URLSession
    private var fallback: URLSession?
    private let injectedFallback: URLSession?
    private var preferFallbackUntil = Date.distantPast

    public init(primary: URLSession = .shared, fallback: URLSession? = nil) {
        self.primary = primary; self.injectedFallback = fallback
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if preferFallbackUntil > Date(), let fallback {
            return try await fallback.data(for: request)
        }
        do { return try await primary.data(for: request) }
        catch {
            let retry = try retrySession(for: request, after: error)
            let result = try await retry.data(for: request)
            fallback = retry; preferFallbackUntil = Date().addingTimeInterval(60)
            return result
        }
    }

    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        if preferFallbackUntil > Date(), let fallback { return try await fallback.bytes(for: request) }
        do { return try await primary.bytes(for: request) }
        catch {
            let retry = try retrySession(for: request, after: error)
            let result = try await retry.bytes(for: request)
            fallback = retry; preferFallbackUntil = Date().addingTimeInterval(60)
            return result
        }
    }

    private func retrySession(for request: URLRequest, after error: Error) throws -> URLSession {
        try Task.checkCancellation()
        let failure = error as NSError
        guard ["GET", "HEAD"].contains(request.httpMethod ?? "GET"), failure.domain == NSURLErrorDomain,
              [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost].contains(failure.code),
              let retry = injectedFallback ?? Self.manualProxySession(for: request.url) else { throw error }
        return retry
    }

    private static func manualProxySession(for url: URL?) -> URLSession? {
        guard var proxies = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        let enabled = [url?.scheme == "https" ? "HTTPS" : "HTTP", "SOCKS"].contains { name in
            (proxies[name + "Enable"] as? NSNumber)?.boolValue == true && !(proxies[name + "Proxy"] as? String ?? "").isEmpty
        }
        guard enabled else { return nil }
        // A stale WPAD setting can time out before the configured manual proxy is tried.
        proxies[kCFNetworkProxiesProxyAutoConfigEnable as String] = 0
        proxies[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] = 0
        proxies.removeValue(forKey: kCFNetworkProxiesProxyAutoConfigURLString as String)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = proxies
        return URLSession(configuration: configuration)
    }
}
