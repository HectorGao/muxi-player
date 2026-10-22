import Foundation
import Testing
@testable import MuxiCore

@Suite(.serialized) struct EmbyClientTests {
    private let base = URL(string: "https://media.example.test/proxy/emby")!

    @Test func testAddressPreservesProxyAndPort() throws {
        #expect(try ServerAddress.normalize("  https://media.test:8920/proxy/emby/// \n").absoluteString == "https://media.test:8920/proxy/emby")
        for value in ["media.test", "file:///etc/passwd", "https://u:p@media.test", "https://media.test?api_key=secret", "https://media.test/#x", "http://media.test:0"] {
            #expect(throws: (any Error).self) { _ = try ServerAddress.normalize(value) }
        }
    }

    @Test func testStreamURLPreservesReverseProxyAndEscapesToken() throws {
        for path in ["/Videos/42/master.m3u8?x=1", "/emby/Videos/42/master.m3u8?x=1", "/proxy/emby/Videos/42/master.m3u8?x=1"] {
            let url = try ServerAddress.stream(path, base: base, token: "a&b=c")
            #expect(url.path == "/proxy/emby/Videos/42/master.m3u8")
            let values = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(values.first { $0.name == "x" }?.value == "1")
            #expect(values.first { $0.name == "api_key" }?.value == "a&b=c")
        }
    }

    @Test func testTokenDoesNotLeakToCDNAndDowngradeIsRejected() throws {
        let signed = "https://cdn.test/video.mp4?signature=abc"
        #expect(try ServerAddress.stream(signed, base: base, token: "private-token").absoluteString == signed)
        for url in ["file:///tmp/video.mp4", "http://media.example.test/stream", "https://u:p@cdn.test/a", "//cdn.test/a"] {
            #expect(throws: (any Error).self) { _ = try ServerAddress.stream(url, base: base, token: "private-token") }
        }
        #expect(ServerAddress.sameOrigin(URL(string: "https://a.test")!, URL(string: "https://a.test:443/path")!))
        #expect(!(ServerAddress.sameOrigin(URL(string: "https://a.test")!, URL(string: "https://a.test:444/path")!)))
    }

    @Test func testQualityAndTracksReachEmbyNegotiation() throws {
        var settings = PlaybackSettings()
        settings.maxHeight = 720
        settings.maxBitrate = 5_000_000
        settings.audioIndex = 2
        settings.subtitleIndex = 4
        let body = PlaybackRequest.body(userID: "user", settings: settings, sourceID: "version")
        #expect(body["EnableDirectPlay"] as? Bool == false)
        #expect(body["AllowVideoStreamCopy"] as? Bool == false)
        #expect(body["MaxStreamingBitrate"] as? Int == 5_000_000)
        #expect(body["AudioStreamIndex"] as? Int == 2)
        #expect(body["SubtitleStreamIndex"] as? Int == 4)
        #expect(body["MediaSourceId"] as? String == "version")
        #expect(body["StartTimeTicks"] as? Int == 0)
        let profile = try #require(body["DeviceProfile"] as? [String: Any])
        let transcodes = try #require(profile["TranscodingProfiles"] as? [[String: Any]])
        #expect(transcodes.first?["MaxHeight"] as? Int == 720)
        _ = try JSONSerialization.data(withJSONObject: body)
    }

    @Test func testDefaultProfileDoesNotClaimMKVSupport() throws {
        let body = PlaybackRequest.body(userID: "u", settings: .init(), sourceID: nil)
        #expect(body["EnableDirectPlay"] as? Bool == true)
        #expect(body["SubtitleStreamIndex"] as? Int == -1)
        let profile = try #require(body["DeviceProfile"] as? [String: Any])
        let direct = try #require(profile["DirectPlayProfiles"] as? [[String: Any]])
        let containers = direct.first?["Container"] as? String ?? ""
        #expect(containers.contains("mkv") == false)
    }

    @Test func testMPVNegotiatesOriginalFilesAndLocalTracks() throws {
        var settings = PlaybackSettings()
        settings.audioIndex = 2
        settings.subtitleIndex = 4
        #expect(settings.requiresConversion)
        #expect(!settings.requiresServerConversion(engine: .mpv))
        let body = PlaybackRequest.body(userID: "u", settings: settings, sourceID: "version", engine: .mpv)
        #expect(body["EnableDirectPlay"] as? Bool == true)
        #expect(body["EnableTranscoding"] as? Bool == false)
        #expect(body["AudioStreamIndex"] == nil && body["SubtitleStreamIndex"] == nil)
        let profile = try #require(body["DeviceProfile"] as? [String: Any])
        let direct = try #require(profile["DirectPlayProfiles"] as? [[String: Any]])
        #expect((direct.first?["Container"] as? String)?.split(separator: ",").contains("mkv") == true)
        let subtitles = try #require(profile["SubtitleProfiles"] as? [[String: String]])
        #expect(subtitles.contains(["Format": "ass", "Method": "Embed"]))
        #expect(subtitles.contains(["Format": "ass", "Method": "External"]))
        #expect(!subtitles.contains { $0["Method"] == "Encode" })
        settings.maxHeight = 720
        #expect(settings.requiresServerConversion(engine: .mpv))
        let limited = PlaybackRequest.body(userID: "u", settings: settings, sourceID: nil, engine: .mpv)
        #expect(limited["EnableDirectPlay"] as? Bool == false)
        #expect(limited["EnableTranscoding"] as? Bool == true)
        let transcodeOnly = try decode(PlaybackInfo.self, #"{"PlaySessionId":"ps","MediaSources":[{"Id":"s","SupportsTranscoding":true,"TranscodingUrl":"/videos/42/master.m3u8"}]}"#)
        #expect(throws: (any Error).self) {
            _ = try PlaybackRequest.plan(info: transcodeOnly, itemID: "42", settings: .init(), base: base, token: "t", deviceID: "d", engine: .mpv)
        }
        _ = try JSONSerialization.data(withJSONObject: body)
        _ = try JSONSerialization.data(withJSONObject: limited)
    }

    @Test func testDirectPlayUsesServerEndpointNotFilesystemPath() throws {
        let info = try decode(PlaybackInfo.self, #"{"PlaySessionId":"ps","MediaSources":[{"Id":"source","Path":"/private/movie.mp4","SupportsDirectPlay":true}]}"#)
        let plan = try PlaybackRequest.plan(info: info, itemID: "42", settings: .init(), base: base, token: "t", deviceID: "d")
        #expect(plan.method == "DirectPlay")
        #expect(plan.url.path == "/proxy/emby/Videos/42/stream")
        #expect(plan.url.query!.contains("MediaSourceId=source"))
    }

    @Test func testTranscodeSelectionAndConstraints() throws {
        let info = try decode(PlaybackInfo.self, #"{"PlaySessionId":"ps","MediaSources":[{"Id":"source","SupportsDirectPlay":true,"SupportsTranscoding":true,"TranscodingUrl":"/videos/42/master.m3u8?MaxHeight=2160&StartTimeTicks=90000"}]}"#)
        var settings = PlaybackSettings()
        settings.maxHeight = 720
        settings.maxBitrate = 5_000_000
        let plan = try PlaybackRequest.plan(info: info, itemID: "42", settings: settings, base: base, token: "t", deviceID: "d")
        #expect(plan.method == "Transcode")
        let items = URLComponents(url: plan.url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.filter { $0.name == "MaxHeight" }.map(\.value) == ["720"])
        #expect(items.first { $0.name == "StartTimeTicks" }?.value == "0")
        #expect(items.first { $0.name == "AllowVideoStreamCopy" }?.value == "false")
    }

    @Test func testUnavailableTranscodeDoesNotSilentlyPlayOriginalQuality() throws {
        let info = try decode(PlaybackInfo.self, #"{"PlaySessionId":"ps","MediaSources":[{"Id":"s","SupportsDirectPlay":true,"SupportsDirectStream":true,"DirectStreamUrl":"/videos/42/stream?Static=true"}]}"#)
        var settings = PlaybackSettings()
        settings.maxHeight = 720
        #expect(throws: (any Error).self) { _ = try PlaybackRequest.plan(info: info, itemID: "42", settings: settings, base: base, token: "t", deviceID: "d") }
        #expect(throws: (any Error).self) { _ = try PlaybackRequest.plan(info: info, itemID: "42", settings: settings, base: base, token: "t", deviceID: "d", engine: .mpv) }
    }

    @Test func testRequestedSourceCannotFallBackToAnotherVersion() throws {
        let info = try decode(PlaybackInfo.self, #"{"PlaySessionId":"ps","MediaSources":[{"Id":"first","SupportsDirectPlay":true},{"Id":"selected","Container":"mkv","SupportsDirectPlay":true},{"Id":"unavailable","RequiresOpening":true,"SupportsDirectPlay":true}]}"#)
        var settings = PlaybackSettings()
        settings.subtitleIndex = 4
        let plan = try PlaybackRequest.plan(info: info, itemID: "42", settings: settings, base: base, token: "t", deviceID: "d", sourceID: "selected", engine: .mpv)
        #expect(plan.source.Id == "selected")
        #expect(plan.method == "DirectPlay")
        #expect(plan.url.query!.contains("MediaSourceId=selected"))
        for missing in ["absent", "unavailable"] {
            #expect(throws: (any Error).self) {
                _ = try PlaybackRequest.plan(info: info, itemID: "42", settings: .init(), base: base, token: "t", deviceID: "d", sourceID: missing, engine: .mpv)
            }
        }
    }

    @Test func testServerPlaybackErrorAndNoSourcesAreReadable() throws {
        for json in [#"{"ErrorCode":"NotAllowed"}"#, #"{"PlaySessionId":"ps","MediaSources":[]}"#] {
            let info = try decode(PlaybackInfo.self, json)
            #expect(throws: (any Error).self) { _ = try PlaybackRequest.plan(info: info, itemID: "42", settings: .init(), base: base, token: "t", deviceID: "d") }
        }
    }

    @Test func testSparseItemAndEpisodeResumeDecode() throws {
        let item = try decode(MediaItem.self, #"{"Id":"e","Name":"Episode","Type":"Episode","SeriesName":"Series","ParentIndexNumber":2,"IndexNumber":3,"UserData":{"PlaybackPositionTicks":123000000}}"#)
        #expect(item.subtitle == "Series · 第 2 季 · 第 3 集")
        #expect(item.resumeTicks == 123_000_000)
        #expect(!(item.isContainer))
        #expect(try decode(MediaItem.self, #"{"Id":"s","Name":"Series","Type":"Series"}"#).isContainer)
    }

    @Test func testTimeHandlesInvalidAVPlayerTimes() {
        #expect(PlaybackTime.ticks(.nan) == 0)
        #expect(PlaybackTime.ticks(.infinity) == 0)
        #expect(PlaybackTime.ticks(-4) == 0)
        #expect(PlaybackTime.ticks(1.25) == 12_500_000)
        #expect(PlaybackTime.label(3670) == "1:01:10")
        #expect(PlaybackTime.label(.nan) == "00:00")
    }

    @Test func testAPIAuthenticationAndPlaybackReporting() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let client = EmbyClient(baseURL: base, deviceID: "device-test", session: URLSession(configuration: config))
        let connection = try await client.authenticate(username: "demo", password: "test-password")
        #expect(connection.user.Id == "u")
        let authenticated = EmbyClient(baseURL: base, deviceID: "device-test", connection: connection, session: URLSession(configuration: config))
        let request = try authenticated.request("Users/u/Items", query: [.init(name: "SearchTerm", value: "山 & 海")])
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token")
        #expect(!(request.url!.absoluteString.contains("fixture-token")))
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first?.value == "山 & 海")
        let items = try await authenticated.items(type: "Movie", search: "山 & 海", start: 60)
        #expect(items.TotalRecordCount == 61)
        let plan = try await authenticated.playback(itemID: "42", settings: .init())
        try await authenticated.report("Stopped", itemID: "42", plan: plan, ticks: 123_000_000, paused: true, settings: .init())
    }

    @Test func testHTTPFailuresDoNotExposeServerBodyOrCredentials() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let client = EmbyClient(baseURL: base, deviceID: "device-test", session: URLSession(configuration: config))
        for code in [401, 403, 500] {
            do { _ = try await client.data(for: client.request("failure/\(code)")); Issue.record("Expected HTTP failure") }
            catch {
                #expect(!(EmbyError.message(error).contains("fixture-token")))
                if code == 401 { #expect(error as? EmbyError == .unauthorized) }
                if code == 403 { #expect(error as? EmbyError == .forbidden) }
            }
        }
    }

    @Test func testClientIdentitySurvivesAuthenticationAndSavedConnection() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let login = EmbyClient(baseURL: base, deviceID: "compatibility-test", clientIdentity: .senPlayer, session: URLSession(configuration: config))
        let connection = try await login.authenticate(username: "demo", password: "test-password")
        let restored = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(connection))
        #expect(restored.clientIdentity == .senPlayer)
        let client = EmbyClient(baseURL: base, deviceID: "compatibility-test", connection: restored)
        let request = try client.request("Users/u/Views")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Client=\"SenPlayer\"") == true)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "MuxiPlayer/0.1.0")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token")
        let item = try decode(MediaItem.self, #"{"Id":"42","Name":"Film","ImageTags":{"Primary":"tag"}}"#)
        #expect(try client.imageRequest(item: item)?.value(forHTTPHeaderField: "Authorization") == request.value(forHTTPHeaderField: "Authorization"))
        let old = try decode(Connection.self, #"{"baseURL":"https://media.test","token":"fixture-token","user":{"Id":"u","Name":"demo"}}"#)
        #expect(old.clientIdentity == nil)
        #expect(old.serverKind == nil)
        #expect(EmbyClient(baseURL: old.baseURL, deviceID: "old", connection: old).serverKind == .emby)
        #expect(EmbyClient(baseURL: old.baseURL, deviceID: "old", connection: old).clientIdentity == .muxi)
    }

    @Test func testNewConnectionsDefaultToCompatibleIdentityWithoutChangingSavedIdentity() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let login = EmbyClient(baseURL: base, deviceID: "default-identity", session: URLSession(configuration: config))
        #expect(login.clientIdentity == .senPlayer)
        let saved = try await login.authenticate(username: "demo", password: "test-password")
        #expect(saved.clientIdentity == .senPlayer)
        for identity in EmbyClientIdentity.allCases {
            let auth = try decode(Authentication.self, #"{"AccessToken":"fixture-token","User":{"Id":"u","Name":"demo"}}"#)
            let connection = Connection(baseURL: base, authentication: auth, clientIdentity: identity)
            let restored = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(connection))
            let client = EmbyClient(baseURL: base, deviceID: "saved-identity", connection: restored)
            #expect(client.clientIdentity == identity)
            #expect(try client.request("Users/u/Views").value(forHTTPHeaderField: "Authorization")?.contains("Client=\"\(identity.rawValue)\"") == true)
        }
        #expect(EmbyClient(baseURL: base, deviceID: "jellyfin-default", serverKind: .jellyfin).clientIdentity == .muxi)
    }

    @Test func testJellyfinAuthenticationAndCommonLibraryAPI() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let login = EmbyClient(baseURL: base, deviceID: "jellyfin-test", clientIdentity: .senPlayer, serverKind: .jellyfin, session: URLSession(configuration: config))
        let saved = try await login.authenticate(username: "demo", password: "test-password")
        let restored = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(saved))
        #expect(restored.serverKind == .jellyfin && restored.clientIdentity == .muxi)
        let client = EmbyClient(baseURL: base, deviceID: "jellyfin-test", connection: restored, session: URLSession(configuration: config))
        #expect(client.serverKind == .jellyfin)
        let request = try client.request("Users/u/Views")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Client=\"Muxi%20Player\", Device=\"Mac\", DeviceId=\"jellyfin-test\", Version=\"0.1.0\", Token=\"fixture-token\"")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        #expect(try await client.libraries().first?.id == "42")
        #expect(try await client.resume().first?.resumeTicks == 120_000_000)
        #expect(try await client.items(type: "Movie", favoritesOnly: true).Items.first?.isFavorite == true)
        #expect(try await client.item(id: "42").Name == "Film")
        #expect(try await client.setFavorite(itemID: "42", isFavorite: true).IsFavorite == true)
        #expect(try await client.setFavorite(itemID: "42", isFavorite: false).IsFavorite == false)
        let plan = try await client.playback(itemID: "42", settings: .init(), engine: .mpv)
        let query = URLComponents(url: plan.url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "ApiKey" }?.value == "fixture-token")
        #expect(query.allSatisfy { $0.name != "api_key" })
        let stream = try decode(MediaStream.self, #"{"Index":4,"Type":"Subtitle","IsExternal":true,"DeliveryUrl":"/Videos/42/Subtitles/4/Stream.srt?api_key=old"}"#)
        let subtitle = try #require(try client.externalSubtitleURL(for: stream))
        #expect(URLComponents(url: subtitle, resolvingAgainstBaseURL: false)!.queryItems?.last?.name == "ApiKey")
    }

    @Test func testJellyfinTokenEncodingAndCrossOriginIsolation() throws {
        let auth = try decode(Authentication.self, #"{"AccessToken":"a&\"b","User":{"Id":"u","Name":"demo"}}"#)
        let client = EmbyClient(baseURL: base, deviceID: "mac\"device", connection: Connection(baseURL: base, authentication: auth, serverKind: .jellyfin))
        let request = try client.request("Users/u/Views")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"a%26%22b\"") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("DeviceId=\"mac%22device\"") == true)
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        for path in ["/Videos/42/master.m3u8?api_key=old&ApiKey=other", "/proxy/emby/Videos/42/master.m3u8?api_key=old"] {
            let url = try ServerAddress.stream(path, base: base, token: "a&b", serverKind: .jellyfin)
            #expect(url.path == "/proxy/emby/Videos/42/master.m3u8")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.filter { ["apikey", "api_key"].contains($0.name.lowercased()) } == [.init(name: "ApiKey", value: "a&b")])
        }
        let cdn = "https://cdn.test/video.mp4?signature=external"
        #expect(try ServerAddress.stream(cdn, base: base, token: "private-token", serverKind: .jellyfin).absoluteString == cdn)
        #expect(throws: (any Error).self) {
            _ = try ServerAddress.stream("http://media.example.test/stream", base: base, token: "private-token", serverKind: .jellyfin)
        }
        let info = try decode(PlaybackInfo.self, #"{"PlaySessionId":"ps","MediaSources":[{"Id":"s","SupportsTranscoding":true,"TranscodingUrl":"/Videos/42/master.m3u8?api_key=old"}]}"#)
        var settings = PlaybackSettings()
        settings.maxHeight = 480
        let plan = try PlaybackRequest.plan(info: info, itemID: "42", settings: settings, base: base, token: "private-token", deviceID: "d", engine: .mpv, serverKind: .jellyfin)
        #expect(plan.method == "Transcode")
        let query = URLComponents(url: plan.url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "ApiKey" }?.value == "private-token")
        #expect(query.first { $0.name == "MaxHeight" }?.value == "480")
        #expect(query.allSatisfy { $0.name != "api_key" })
    }

    @Test func testExplicitConversionPolicyBlocksOnlyConvertedPlayback() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        for (policy, blocked) in [
            (#","Policy":{"EnableVideoPlaybackTranscoding":false,"EnableAudioPlaybackTranscoding":false,"EnablePlaybackRemuxing":false}"#, true),
            ("", false),
            (#","Policy":{"EnableVideoPlaybackTranscoding":false}"#, false)
        ] {
            let auth = try decode(Authentication.self, #"{"AccessToken":"fixture-token","User":{"Id":"u","Name":"demo"\#(policy)}}"#)
            let connection = Connection(baseURL: base, authentication: auth)
            let restored = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(connection))
            let client = EmbyClient(baseURL: base, deviceID: "policy-test", connection: restored, session: URLSession(configuration: config))
            #expect(try await client.playback(itemID: "42", settings: .init()).method == "DirectPlay")
            var settings = PlaybackSettings()
            settings.maxHeight = 480
            if blocked {
                do {
                    _ = try await client.playback(itemID: "must-not-request", settings: settings)
                    Issue.record("Explicitly denied conversion must fail before requesting playback")
                } catch { #expect(error as? EmbyError == .conversionUnavailable) }
            } else {
                #expect(try await client.playback(itemID: "42", settings: settings).method == "Transcode")
            }
        }
    }

    @Test func testMPVDiscoversVersionsAndPlaysLocalTracksWithoutTranscodingPermission() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let auth = try decode(Authentication.self, #"{"AccessToken":"fixture-token","User":{"Id":"u","Name":"demo","Policy":{"EnableVideoPlaybackTranscoding":false,"EnableAudioPlaybackTranscoding":false,"EnablePlaybackRemuxing":false}}}"#)
        let connection = Connection(baseURL: base, authentication: auth, clientIdentity: .senPlayer)
        let client = EmbyClient(baseURL: base, deviceID: "native-test", connection: connection, session: URLSession(configuration: config))
        let sources = try await client.mediaSources(itemID: "inspect", engine: .mpv)
        #expect(sources.map(\.Id) == ["s", "alternate"])
        let alternate = try #require(sources.last)
        #expect(alternate.Bitrate == 8_000_000 && alternate.Size == 4_000_000_000)
        let stream = try #require(alternate.MediaStreams?.first)
        #expect(stream.Index == 7 && stream.Channels == 6 && stream.label == "Original audio")
        var settings = PlaybackSettings()
        settings.audioIndex = 2
        settings.subtitleIndex = 4
        let plan = try await client.playback(itemID: "native", settings: settings, sourceID: "s", engine: .mpv)
        #expect(plan.method == "DirectPlay")
        settings.maxBitrate = 2_000_000
        do {
            _ = try await client.playback(itemID: "must-not-request", settings: settings, engine: .mpv)
            Issue.record("Quality conversion must still respect the server policy")
        } catch { #expect(error as? EmbyError == .conversionUnavailable) }
    }

    @Test func testMPVQualityRespectsVideoPolicyIndependently() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        for (policy, blocked) in [
            (#","Policy":{"EnableVideoPlaybackTranscoding":false,"EnableAudioPlaybackTranscoding":true,"EnablePlaybackRemuxing":true}"#, true),
            (#","Policy":{"EnableVideoPlaybackTranscoding":false}"#, true),
            ("", false)
        ] {
            let auth = try decode(Authentication.self, #"{"AccessToken":"fixture-token","User":{"Id":"u","Name":"demo"\#(policy)}}"#)
            let client = EmbyClient(baseURL: base, deviceID: "quality-policy", connection: Connection(baseURL: base, authentication: auth), session: URLSession(configuration: config))
            var settings = PlaybackSettings()
            settings.subtitleIndex = 4
            settings.audioIndex = 2
            #expect(try await client.playback(itemID: "42", settings: settings, engine: .mpv).method == "DirectPlay")
            settings.maxHeight = 720
            if blocked {
                do {
                    _ = try await client.playback(itemID: "must-not-request", settings: settings, engine: .mpv)
                    Issue.record("Video policy must prevent mpv quality conversion before a request")
                } catch { #expect(error as? EmbyError == .conversionUnavailable) }
            } else {
                #expect(try await client.playback(itemID: "42", settings: settings, engine: .mpv).method == "Transcode")
            }
        }
    }

    @Test func testExternalSubtitlesPreserveURLSecurity() throws {
        let auth = try decode(Authentication.self, #"{"AccessToken":"fixture-token","User":{"Id":"u","Name":"demo"}}"#)
        let client = EmbyClient(baseURL: base, deviceID: "subtitle-test", connection: Connection(baseURL: base, authentication: auth))
        let relative = try decode(MediaStream.self, #"{"Index":4,"Type":"Subtitle","IsExternal":false,"DeliveryMethod":"External","DeliveryUrl":"/Videos/42/Subtitles/4/Stream.ass","DeliveryFormat":"ass","IsForced":true}"#)
        let url = try #require(try client.externalSubtitleURL(for: relative))
        #expect(url.path == "/proxy/emby/Videos/42/Subtitles/4/Stream.ass")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "api_key" }?.value == "fixture-token")
        #expect(relative.DeliveryFormat == "ass" && relative.IsForced == true)
        let external = try decode(MediaStream.self, #"{"Index":5,"Type":"Subtitle","IsExternalUrl":true,"DeliveryUrl":"https://cdn.test/subtitle.ass?signature=abc"}"#)
        #expect(try client.externalSubtitleURL(for: external)?.absoluteString == "https://cdn.test/subtitle.ass?signature=abc")
        for raw in ["file:///private/subtitle.ass", "https://u:p@cdn.test/subtitle.ass", "http://cdn.test/subtitle.ass", "//cdn.test/subtitle.ass"] {
            let stream = try decode(MediaStream.self, #"{"Index":6,"Type":"Subtitle","IsExternal":true,"DeliveryUrl":"\#(raw)"}"#)
            #expect(throws: (any Error).self) { _ = try client.externalSubtitleURL(for: stream) }
        }
        let embedded = try decode(MediaStream.self, #"{"Index":8,"Type":"Subtitle","DeliveryMethod":"Embed","Path":"/private/subtitle.ass"}"#)
        #expect(try client.externalSubtitleURL(for: embedded) == nil)
    }

    @Test func testMediaWallQueryPreservesFiltersSortAndPagination() async throws {
        let auth = try decode(Authentication.self, #"{"AccessToken":"fixture-token","User":{"Id":"u","Name":"demo"}}"#)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let client = EmbyClient(baseURL: base, deviceID: "media-wall-query", connection: Connection(baseURL: base, authentication: auth, clientIdentity: .senPlayer), session: URLSession(configuration: config))
        let page = try await client.items(parent: "library-1", type: "Movie,Series", search: "山 & 海", start: 18,
                                          limit: 18, sortBy: "CommunityRating,DateCreated", descending: true,
                                          favoritesOnly: true, unplayedOnly: true)
        #expect(page.TotalRecordCount == 21)
        #expect(page.Items.first?.isFavorite == true)
        #expect(page.Items.first?.UserData?.Played == false)
    }

    @Test func testAllMediaWallListsRequestArtworkMetadata() async throws {
        let auth = try decode(Authentication.self, #"{"AccessToken":"fixture-token","User":{"Id":"u","Name":"demo"}}"#)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        for kind in MediaServerKind.allCases {
            let connection = Connection(baseURL: base, authentication: auth, serverKind: kind)
            let client = EmbyClient(baseURL: base, deviceID: "media-wall-artwork", connection: connection, session: URLSession(configuration: config))
            let libraries = try await client.libraries()
            let resumed = try await client.resume()
            let items = try await client.items().Items
            for list in [libraries, resumed, items] {
                let item = try #require(list.first)
                #expect(item.ImageTags?["Primary"] == "poster-tag")
                #expect(item.BackdropImageTags == ["backdrop-tag"])
                #expect(item.ProductionYear == 2017)
                #expect(item.CommunityRating == 7.598)
                #expect(try client.imageRequest(item: item) != nil)
                #expect(try client.imageRequest(item: item, backdrop: true) != nil)
            }
        }
    }

    @Test func testFavoriteMutationReturnsConfirmedServerState() async throws {
        let auth = try decode(Authentication.self, #"{"AccessToken":"fixture-token","User":{"Id":"u","Name":"demo"}}"#)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let client = EmbyClient(baseURL: base, deviceID: "favorites-test", connection: Connection(baseURL: base, authentication: auth, clientIdentity: .senPlayer), session: URLSession(configuration: config))
        let added = try await client.setFavorite(itemID: "42", isFavorite: true)
        #expect(added.IsFavorite == true)
        #expect(added.PlaybackPositionTicks == 364_000_000)
        let removed = try await client.setFavorite(itemID: "42", isFavorite: false)
        #expect(removed.IsFavorite == false)
        #expect(try await client.setFavorite(itemID: "unchanged", isFavorite: true).IsFavorite == false)
        do {
            _ = try await client.setFavorite(itemID: "missing-state", isFavorite: true)
            Issue.record("A missing server favorite state must not be reported as success")
        } catch { #expect(error as? EmbyError == .invalidResponse) }
        do {
            _ = try await client.setFavorite(itemID: "denied", isFavorite: true)
            Issue.record("A refused favorite mutation must not be reported as success")
        } catch { #expect(error as? EmbyError == .forbidden) }
        let unauthenticated = EmbyClient(baseURL: base, deviceID: "favorites-test", session: URLSession(configuration: config))
        do {
            _ = try await unauthenticated.setFavorite(itemID: "must-not-request", isFavorite: true)
            Issue.record("Favorite mutation requires a user connection")
        } catch { #expect(error as? EmbyError == .unauthorized) }
    }

    @Test func testBackdropRequestKeepsAuthenticationAndFallsBackToPoster() throws {
        let auth = try decode(Authentication.self, #"{"AccessToken":"fixture-token","User":{"Id":"u","Name":"demo"}}"#)
        let client = EmbyClient(baseURL: base, deviceID: "artwork-test", connection: Connection(baseURL: base, authentication: auth, clientIdentity: .senPlayer))
        let artwork = try decode(MediaItem.self, #"{"Id":"42","Name":"Film","ImageTags":{"Primary":"poster-tag"},"BackdropImageTags":["backdrop-tag"]}"#)
        let request = try #require(try client.imageRequest(item: artwork, backdrop: true))
        #expect(request.url?.path == "/proxy/emby/Items/42/Images/Backdrop/0")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Client=\"SenPlayer\"") == true)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "Tag" }?.value == "backdrop-tag")
        #expect(query.first { $0.name == "MaxWidth" }?.value == "1280")
        #expect(query.allSatisfy { $0.name != "api_key" })
        let posterOnly = try decode(MediaItem.self, #"{"Id":"42","Name":"Film","ImageTags":{"Primary":"poster-tag"}}"#)
        #expect(try client.imageRequest(item: posterOnly, backdrop: true)?.url?.path == "/proxy/emby/Items/42/Images/Primary")
        #expect(!posterOnly.isFavorite)
        let noArtwork = try decode(MediaItem.self, #"{"Id":"42","Name":"Film"}"#)
        #expect(try client.imageRequest(item: noArtwork, backdrop: true) == nil)
    }

    @Test func testGatewayChallengesAreNotReportedAsAccountPermissions() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let client = EmbyClient(baseURL: base, deviceID: "device-test", session: URLSession(configuration: config))
        for path in ["challenge/header", "challenge/header200", "challenge/html"] {
            do {
                _ = try await client.data(for: client.request(path))
                Issue.record("A gateway challenge must not be accepted as an Emby response")
            } catch {
                #expect(EmbyError.message(error).contains("验证或拦截"))
                #expect(error as? EmbyError == .webChallenge)
                #expect(EmbyError.message(error).contains("转码权限") == false)
                #expect(EmbyError.message(error).contains("fixture-token") == false)
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T { try JSONDecoder().decode(type, from: Data(value.utf8)) }
}

final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let jellyfin = request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("MediaBrowser ") == true
        if jellyfin {
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Client=\"Muxi%20Player\"") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"fixture-token\"") == !path.hasSuffix("AuthenticateByName"))
        }
        #expect(!path.contains("/must-not-request/"))
        var status = 200
        var headers = ["Content-Type": "application/json"]
        let response: String
        if path.hasSuffix("AuthenticateByName") {
            #expect(request.httpMethod == "POST")
            let authorization = request.value(forHTTPHeaderField: "Authorization")!
            let expectedClient = jellyfin ? "Muxi%20Player" : "SenPlayer"
            #expect(authorization.contains("Client=\"\(expectedClient)\""))
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "MuxiPlayer/0.1.0")
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
            let body = readBody()
            #expect(body["Username"] as? String == "demo")
            #expect(body["Pw"] as? String == "test-password")
            response = #"{"AccessToken":"fixture-token","User":{"Id":"u","Name":"demo"},"ServerId":"test"}"#
        } else if path.hasSuffix("PlaybackInfo") {
            if path.contains("/inspect/") || path.contains("/native/") {
                let body = readBody()
                #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Client=\"SenPlayer\"") == true)
                #expect(body["IsPlayback"] as? Bool == path.contains("/native/"))
                #expect(body["AutoOpenLiveStream"] as? Bool == false)
                #expect(body["AudioStreamIndex"] == nil && body["SubtitleStreamIndex"] == nil)
                #expect(body["MediaSourceId"] as? String == (path.contains("/native/") ? "s" : nil))
            }
            response = #"{"PlaySessionId":"ps","MediaSources":[{"Id":"s","SupportsDirectPlay":true,"SupportsTranscoding":true,"TranscodingUrl":"/videos/42/master.m3u8"},{"Id":"alternate","Container":"mkv","Bitrate":8000000,"Size":4000000000,"SupportsDirectPlay":true,"MediaStreams":[{"Index":7,"Type":"Audio","Title":"Original audio","Codec":"dts","Channels":6}]}]}"#
        } else if path.hasSuffix("Stopped") {
            let body = readBody()
            #expect(body["PositionTicks"] as? Int64 == 123_000_000)
            #expect(body["PlaySessionId"] as? String == "ps")
            #expect(body["MediaSourceId"] as? String == "s")
            status = 204
            response = ""
        } else if path.contains("/FavoriteItems/") {
            #expect(path.hasPrefix("/proxy/emby/Users/u/FavoriteItems/"))
            if !jellyfin {
                #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token")
                #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Client=\"SenPlayer\"") == true)
            }
            #expect(request.httpMethod == "POST" || request.httpMethod == "DELETE")
            #expect(request.url?.query == nil)
            if path.hasSuffix("denied") {
                status = 403
                response = ""
            } else if path.hasSuffix("missing-state") {
                response = "{}"
            } else {
                let favorite = request.httpMethod == "POST" && !path.hasSuffix("unchanged")
                response = "{\"IsFavorite\":\(favorite),\"PlaybackPositionTicks\":364000000,\"Played\":false}"
            }
        } else if request.value(forHTTPHeaderField: "Authorization")?.contains("DeviceId=\"media-wall-artwork\"") == true {
            #expect(["/proxy/emby/Users/u/Views", "/proxy/emby/Users/u/Items/Resume", "/proxy/emby/Users/u/Items"].contains(path))
            #expect(request.httpMethod == "GET")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            #expect(query.filter { $0.name == "EnableImages" }.map(\.value) == ["true"])
            #expect(query.filter { $0.name == "ImageTypeLimit" }.map(\.value) == ["1"])
            #expect(query.allSatisfy { $0.name != "ImageTypes" })
            if !path.hasSuffix("/Views") {
                let fields = query.first { $0.name == "Fields" }?.value?.split(separator: ",") ?? []
                #expect(fields.contains("ProductionYear") && fields.contains("CommunityRating"))
            }
            response = #"{"Items":[{"Id":"42","Name":"Film","ImageTags":{"Primary":"poster-tag"},"BackdropImageTags":["backdrop-tag"],"ProductionYear":2017,"CommunityRating":7.598}],"TotalRecordCount":1}"#
        } else if jellyfin {
            #expect(["/proxy/emby/Users/u/Views", "/proxy/emby/Users/u/Items/Resume", "/proxy/emby/Users/u/Items", "/proxy/emby/Users/u/Items/42"].contains(path))
            #expect(request.httpMethod == "GET")
            #expect(request.url?.absoluteString.contains("fixture-token") == false)
            let item = #"{"Id":"42","Name":"Film","UserData":{"IsFavorite":true,"Played":false,"PlaybackPositionTicks":120000000}}"#
            response = path.hasSuffix("/42") ? item : "{\"Items\":[\(item)],\"TotalRecordCount\":1}"
        } else if request.value(forHTTPHeaderField: "Authorization")?.contains("DeviceId=\"media-wall-query\"") == true {
            #expect(path == "/proxy/emby/Users/u/Items")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Client=\"SenPlayer\"") == true)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            for (name, value) in ["ParentId": "library-1", "IncludeItemTypes": "Movie,Series", "SearchTerm": "山 & 海",
                                  "StartIndex": "18", "Limit": "18", "SortBy": "CommunityRating,DateCreated", "SortOrder": "Descending",
                                  "Filters": "IsFavorite,IsUnplayed", "Recursive": "true", "EnableUserData": "true",
                                  "EnableImages": "true", "ImageTypeLimit": "1"] {
                #expect(query.first { $0.name == name }?.value == value)
            }
            #expect(query.first { $0.name == "Fields" }?.value?.contains("Overview") == true)
            response = #"{"Items":[{"Id":"42","Name":"Film","UserData":{"IsFavorite":true,"Played":false}}],"TotalRecordCount":21}"#
        } else if path.contains("challenge") {
            status = path.hasSuffix("header200") ? 200 : 403
            headers = ["Content-Type": "text/html; charset=UTF-8", "Server": "cloudflare"]
            if !path.hasSuffix("html") { headers["cf-mitigated"] = "challenge" }
            response = "<html><title>Just a moment...</title><script src='/cdn-cgi/challenge-platform/test'></script>fixture-token</html>"
        } else if path.contains("failure") {
            status = Int(request.url!.lastPathComponent)!
            headers["Server"] = "cloudflare"
            response = "fixture-token must never reach an error message"
        } else {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.first { $0.name == "StartIndex" }?.value == "60")
            response = #"{"Items":[{"Id":"42","Name":"Film"}],"TotalRecordCount":61}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private func readBody() -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size <= 0 { break }
                data.append(buffer, count: size)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
