import AppKit
import Security
import MuxiCore

@main @MainActor struct OnlineCheck {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CatalogError(message) }
    }

    static func wait(_ message: String, condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CatalogError("Timed out: " + message)
    }

    static func events(_ name: String) -> [[String: Any]] {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: ".local/smoke/events.jsonl"))) ?? Data()
        return data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }.filter { $0["event"] as? String == name }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await fixture()
                if CommandLine.arguments.contains("--live") { try await live() }
                print("PASS: online source, cache and actual libmpv playback checks")
                exit(0)
            } catch { print("FAIL: " + error.localizedDescription); exit(1) }
        }
        app.run()
    }

    static func fixture() async throws {
        let source = OnlineSource(name: "Fixture CMS", url: URL(string: "http://127.0.0.1:18796/emby/cms")!)
        let offline = OnlineSource(name: "Offline fixture", url: URL(string: "http://127.0.0.1:18796/emby/offline-cms")!)
        let suite = "com.hectorgao.muxi-player.online-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let credentials = CredentialStore(service: suite)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: suite,
                           kSecAttrAccount as String: "online-sources-v1"] as CFDictionary)
        }
        let store = OnlineLibraryStore(credentials: credentials, directory: directory, defaults: defaults)
        await store.restore()
        await store.saveSources([source, offline])
        let saved = try await credentials.loadOnlineSources()
        try require(saved?.map(\.id) == [source.id, offline.id], "Sources did not persist in the isolated Keychain")

        async let healthy: Void = store.load(source, search: "fixture")
        async let unhealthy: Void = store.load(offline, search: "fixture")
        _ = await (healthy, unhealthy)
        try require(store.state(source, search: "fixture").items.count == 1, "A failing source blocked healthy results")
        try require(store.state(offline, search: "fixture").error != nil, "Failed source lacks a visible status")
        let firstCount = events("OnlineQuery").count
        await store.load(source, search: "fixture")
        let restored = OnlineLibraryStore(credentials: credentials, directory: directory, defaults: defaults)
        await restored.load(source, search: "fixture")
        try require(events("OnlineQuery").count == firstCount, "A cached search repeated the API query")
        try require(restored.state(source, search: "fixture").fromCache, "Disk cache did not survive a new store")
        await store.load(source, search: "fixture", force: true)
        try require(events("OnlineQuery").last?["h"] is String, "Repeated search omitted the CMS incremental window")
        let failedCount = events("OfflineOnlineQuery").count
        await store.load(offline, search: "fixture")
        try require(events("OfflineOnlineQuery").count == failedCount, "Source cooldown was ignored")

        guard let entry = store.state(source, search: "fixture").items.first else { throw CatalogError("Missing fixture movie") }
        store.toggleFavorite(entry)
        let reopened = OnlineLibraryStore(credentials: credentials, directory: directory, defaults: defaults)
        try require(reopened.isFavorite(entry), "Online favorite was lost on restart")
        store.toggleFavorite(entry)
        print("PASS: source persistence, parallel failure isolation, disk search cache, incremental window, cooldown and favorites")

        let playback = PlaybackController(headless: true, resumeDefaults: defaults)
        playback.volume = 0
        playback.playOnline(entry, source: source, route: 0, episode: 0, fromStart: true)
        try await wait("CMS stream decode") { playback.isPlaying && playback.position > 0.3 }
        try require(playback.audioTracks.count == 2 && playback.subtitleTracks.count == 2, "Actual online audio/subtitle discovery failed")
        try require(!playback.canConvertVideo, "Public stream falsely claims server transcoding")
        let audio = playback.audioTracks[1], subtitle = playback.subtitleTracks[1]
        playback.selectAudio(id: audio.id); playback.selectSubtitle(id: subtitle.id)
        playback.seek(to: 18)
        try await wait("online seek and tracks") {
            abs(playback.position - 18) < 1 && playback.engine?.selectedAudioID == audio.id && playback.engine?.selectedSubtitleID == subtitle.id
        }
        await playback.stop()
        try require(playback.item == nil && (playback.onlineRecent?.position ?? 0) > 17, "Stopping did not keep the online bookmark")
        let bookmark = defaults.data(forKey: "onlineRecentPlayback")!
        try require(!String(decoding: bookmark, as: UTF8.self).contains("/Videos/"), "Online bookmark contains a media URL")

        let resumed = PlaybackController(headless: true, resumeDefaults: defaults)
        resumed.volume = 0; resumed.resumeOnline(source: source)
        try await wait("online resume") {
            resumed.isPlaying && resumed.position > 17 && resumed.engine?.selectedAudioID == audio.id && resumed.engine?.selectedSubtitleID == subtitle.id
        }
        try require(resumed.engine?.selectedAudioID == audio.id, "Audio selection was lost during resume")
        try require(resumed.engine?.selectedSubtitleID == subtitle.id, "Subtitle selection was lost during resume")
        try require(resumed.canPlayNext, "CMS episodes did not expose next episode")
        await resumed.stop()
        let previousClosed = events("StreamClosed").count
        resumed.playOnline(entry, source: source, route: 1, episode: 0, fromStart: true)
        try await wait("slow online stream") { resumed.isPlaying }
        await resumed.stop()
        try await wait("stream cancellation") { events("StreamClosed").count > previousClosed }
        try require(events("StreamClosed").last?["complete"] as? Bool == false, "Stopping continued to download the entire stream")
        print("PASS: actual online MKV decode, tracks, seek, stop, persisted resume and early network cancellation")
    }

    static func live() async throws {
        let client = OnlineCatalogClient()
        for source in OnlineSource.defaults {
            let page = try await client.page(source: source)
            try require(!page.items.isEmpty, "A default public catalog returned no movies")
            print("PASS: live default catalog " + source.name + " (\(page.items.count) items)")
        }
        let source = OnlineSource.defaults[0]
        let item = OnlineItem(sourceID: source.id, remoteID: "BigBuckBunny_328", media: MediaItem(id: "public-film", name: "Big Buck Bunny"))
        let routes = try await client.routes(for: item, source: source)
        guard let url = routes.first?.episodes.first?.url else { throw CatalogError("No public stream URL") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        try require((response as? HTTPURLResponse)?.statusCode == 206 && data.count == 1024, "Public media range request failed")
        var movie = MediaItem(id: "live-rating", name: "Blade Runner 2049")
        movie.ProviderIds = ["Imdb": "tt1856101"]
        let rating = await MovieRatings.shared.rating(for: movie)
        try require(rating?.source == "IMDb" && (rating?.value ?? 0) > 0, "Live IMDb rating was unavailable")
        print("PASS: live public media Range 206 and attributed IMDb rating")
    }
}
