import Foundation
import Testing
@testable import MuxiCore

@Suite(.serialized) struct ViewingSiteTests {
    @Test func siteUpgradeKeepsEditedDefaultsAndDisabledCustomSites() throws {
        var saved = ViewingSite.defaults[0]
        saved.name = "我的名称"; saved.enabled = false
        let custom = ViewingSite(name: "自建 MoonTV", url: URL(string: "http://localhost:8080/tv")!)
        let merged = ViewingSite.mergingDefaults(into: [saved, custom])
        #expect(merged.count == ViewingSite.defaults.count + 1)
        #expect(merged[0].name == "我的名称" && !merged[0].enabled)
        #expect(merged.contains(custom))
        #expect(ViewingSite.addressKey(URL(string: "https://EXAMPLE.test:443/path/#home")!) == ViewingSite.addressKey(URL(string: "https://example.test/path")!))
        for value in ["file:///tmp/movie", "javascript:alert(1)", "https://user:pass@example.test", "http://example.test:0"] {
            #expect(throws: (any Error).self) { _ = try ViewingSite.checkedURL(value) }
        }
        #expect(try ViewingSite.checkedURL("https://site.test/tv/#/play/1").fragment == "/play/1")
    }

    @Test func statusSortingFailuresAndAutoOpenRespectSitePurpose() {
        let fast = ViewingSite(name: "Fast", url: URL(string: "https://fast.test")!)
        let slow = ViewingSite(name: "Slow", url: URL(string: "https://slow.test")!)
        let offline = ViewingSite(name: "A offline", url: URL(string: "https://off.test")!)
        let health = [fast.id: SiteHealth(status: .online, milliseconds: 20), slow.id: SiteHealth(status: .online, milliseconds: 200), offline.id: SiteHealth(status: .offline)]
        #expect(SiteHealth.sorted([offline, slow, fast], health: health).map(\.id) == [fast.id, slow.id, offline.id])
        let failed = SiteHealth(status: .error).following(SiteHealth(status: .offline, failures: 2))
        #expect(failed.failures == 3)
        #expect(SiteHealth(status: .online).following(failed).failures == 0)
        #expect(ViewingSite.defaults.filter { $0.kind == .reference }.allSatisfy { !$0.monitored && !$0.canAutoOpen })
        #expect(ViewingSite.defaults.filter { $0.kind == .emby || $0.kind == .jellyfin }.allSatisfy { $0.monitored && !$0.canAutoOpen })
        var disabled = fast; disabled.enabled = false
        #expect(!disabled.monitored && !disabled.canAutoOpen)
    }

    @Test func probeRejectsChallengeParkingAndHTMLPretendingToBeAServer() throws {
        let response = HTTPURLResponse(url: URL(string: "https://test.example")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        for html in ["<html><script src='/cdn-cgi/challenge-platform/script'></script></html>", "<html>This domain is for sale</html>", "<html>ordinary site</html>"] {
            #expect(throws: (any Error).self) { try SiteProbe.validate(Data(html.utf8), response: response, server: true) }
        }
        #expect(throws: (any Error).self) { try SiteProbe.validate(Data("Buy this domain".utf8), response: response, server: false) }
        #expect(throws: (any Error).self) { try SiteProbe.validate(Data("/cdn-cgi/challenge-platform/".utf8), response: response, server: false) }
        try SiteProbe.validate(Data("<html>Film catalog</html>".utf8), response: response, server: false)
        try SiteProbe.validate(Data(#"{"Id":"public-id","Version":"1.0"}"#.utf8), response: response, server: true)
    }

    @Test func probeChecksPublicServerAPIWithoutLoginAndClassifiesFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiteFixtureProtocol.self]
        let probe = SiteProbe(session: URLSession(configuration: configuration))
        let site = ViewingSite(name: "Server", url: URL(string: "https://test.example/reverse/emby")!, kind: .emby)
        #expect(try await probe.check(site).status == .online)
        #expect(SiteFixtureProtocol.lastRequest?.url?.path == "/reverse/emby/System/Info/Public")
        #expect(SiteFixtureProtocol.lastRequest?.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        #expect(SiteFixtureProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
        let bad = ViewingSite(name: "Error", url: URL(string: "https://test.example/fail")!)
        #expect(try await probe.check(bad).status == .error)
        let unreachable = ViewingSite(name: "Offline", url: URL(string: "https://test.example/offline")!)
        #expect(try await probe.check(unreachable).status == .offline)
    }
}

private final class SiteFixtureProtocol: URLProtocol {
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if request.url!.path == "/offline" { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let failed = request.url!.path == "/fail"
        let response = HTTPURLResponse(url: request.url!, statusCode: failed ? 503 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"Id":"test","Version":"1.0"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
