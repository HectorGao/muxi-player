import AppKit
import WebKit
import Security
import MuxiCore

@main @MainActor struct SiteCheck {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CatalogError(message) }
    }
    static func wait(_ message: String, condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CatalogError("Timed out: " + message)
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await fixture()
                if CommandLine.arguments.contains("--live") { try await live() }
                print("PASS: viewing sites, startup selection, cache and WebKit history")
                exit(0)
            } catch { print("FAIL: " + error.localizedDescription); exit(1) }
        }
        app.run()
    }

    static func fixture() async throws {
        let suite = "com.hectorgao.muxi-player.site-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let credentials = CredentialStore(service: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: suite,
                           kSecAttrAccount as String: "viewing-sites-v1"] as CFDictionary)
        }
        let fast = ViewingSite(name: "Fast", url: URL(string: "http://127.0.0.1:18796/emby/site/home")!)
        let slow = ViewingSite(name: "Slow", url: URL(string: "http://127.0.0.1:18796/emby/site/slow")!)
        let failing = ViewingSite(name: "Fail", url: URL(string: "http://127.0.0.1:18796/emby/site/error")!)
        let reference = ViewingSite(name: "Info", url: fast.url, kind: .reference)
        let server = ViewingSite(name: "Emby", url: URL(string: "http://127.0.0.1:18796/emby")!, kind: .emby)
        let disabled = ViewingSite(name: "Disabled", url: slow.url, enabled: false)
        let presets = ViewingSite.defaults.map { site -> ViewingSite in var value = site; value.enabled = false; return value }
        try await credentials.saveViewingSites(presets + [fast, slow, failing, reference, server, disabled])
        let store = ViewingSiteStore(credentials: credentials, defaults: defaults)
        store.autoOpenFastest = true
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "muxi-site-check", .value: "session"] )!
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        await store.start(online: [], servers: [])
        try require(store.startupSite?.id == fast.id, "Startup failed to select the fastest eligible website")
        try require(store.health[server.id]?.status == .online, "Public server endpoint was not checked")
        try require(store.health[reference.id] == nil && store.health[disabled.id] == nil, "Reference or disabled site was monitored")
        try require(store.health[failing.id]?.failures == 1, "Failure was not recorded")
        await store.check(failing)
        try require(store.health[failing.id]?.failures == 2, "Consecutive failure count was reset")
        await store.start(online: [], servers: [])
        try require(defaults.integer(forKey: "viewingSiteLaunches") == 1, "A second window counted as another app launch")

        let cms = OnlineSource(name: "Fixture CMS", url: URL(string: "http://127.0.0.1:18796/emby/cms")!)
        store.synchronize(online: [cms], servers: [])
        await store.check(store.allSites.first { $0.id == cms.id })
        try require(store.health[cms.id]?.status == .online, "Synced CMS source did not validate its API")
        store.synchronize(online: [], servers: [])
        try require(!store.allSites.contains { $0.id == cms.id }, "Removed CMS source stayed in the monitor roster")
        let duplicate = await store.upsert(nil, name: "Duplicate", address: fast.url.absoluteString + "/", kind: .web)
        try require(!duplicate, "Equivalent custom site was duplicated")
        try require(await store.upsert(nil, name: "New", address: "http://127.0.0.1:18796/emby/site/new", kind: .web), "Custom site save failed")

        let browser = WebsiteBrowser(store: store)
        browser.load(fast.url)
        do { try await wait("WebKit initial page") { browser.title == "观影测试站" && !store.visits.isEmpty } }
        catch { throw CatalogError("WebKit initial page: title=\(browser.title), visits=\(store.visits.count), loading=\(browser.loading), error=\(browser.error ?? "none")") }
        let second = URL(string: "http://127.0.0.1:18796/emby/site/second")!
        browser.load(second)
        try await wait("WebKit second page") { browser.title == "第二页" && store.visits.count == 2 }
        try require(browser.canGoBack, "Website browser lost back navigation")
        browser.webView.goBack()
        try await wait("WebKit back navigation") { browser.title == "观影测试站" }
        try require(store.visits.count == 2, "Revisiting a page duplicated history")
        _ = try await browser.webView.evaluateJavaScript("document.title = '单页观影'; history.pushState({}, '', '/emby/site/spa')")
        try await wait("SPA history") { store.visits.first?.url.path == "/emby/site/spa" && store.visits.first?.title == "单页观影" }
        store.recordVisit(url: URL(string: "http://127.0.0.1/secret?api_key=secret")!, title: "Secret")
        try require(store.visits.count == 3, "Sensitive login URL entered browsing history")

        let secondLaunch = ViewingSiteStore(credentials: credentials, defaults: defaults)
        await secondLaunch.start(online: [], servers: [])
        try require(secondLaunch.visits.count == 3 && secondLaunch.health[failing.id]?.failures == 3, "History or health failed to persist")
        try require(secondLaunch.lastCacheClear == nil, "Cache cleared before the third app launch")
        let thirdLaunch = ViewingSiteStore(credentials: credentials, defaults: defaults)
        await thirdLaunch.start(online: [], servers: [])
        try require(thirdLaunch.lastCacheClear != nil && thirdLaunch.visits.count == 3, "Third launch failed to clear caches while keeping history")
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        try require(cookies.contains { $0.name == cookie.name && $0.value == cookie.value }, "Cache cleanup removed a login cookie")
        await WKWebsiteDataStore.default().httpCookieStore.deleteCookie(cookie)
        thirdLaunch.removeVisit(thirdLaunch.visits[0].id)
        try require(thirdLaunch.visits.count == 2, "Single visit removal failed")
        thirdLaunch.clearVisits()
        try require(ViewingSiteStore(credentials: credentials, defaults: defaults).visits.isEmpty, "Cleared visits returned on restart")
        try require(await thirdLaunch.upsert(failing, name: "Recovered", address: "http://127.0.0.1:18796/emby/site/recovered", kind: .web), "Site edit failed")
        try require(thirdLaunch.health[failing.id] == nil, "Edited address retained an old health result")
        await thirdLaunch.check(thirdLaunch.savedSites.first { $0.id == failing.id })
        try require(thirdLaunch.health[failing.id]?.status == .online && thirdLaunch.health[failing.id]?.failures == 0, "A successful check did not reset failures")
        print("PASS: custom sites, roster sync, failures, startup once, fastest choice, history and third-launch cache cleanup")
    }

    static func live() async throws {
        let probe = SiteProbe()
        let catalogs = OnlineSource.defaults.map {
            ViewingSite(id: $0.id, name: $0.name, url: $0.url, kind: $0.kind == .cms ? .cms : .archive, collection: $0.collection)
        }
        for site in ViewingSite.defaults.filter(\.monitored) + catalogs {
            let result = try await probe.check(site)
            print("LIVE: \(site.name) \(result.status.rawValue) \(result.milliseconds.map(String.init) ?? "-") ms \(result.message ?? "")")
        }
    }
}
