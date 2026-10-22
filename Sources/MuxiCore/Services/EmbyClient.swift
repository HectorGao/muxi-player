import Foundation

public final class EmbyClient {
    public let baseURL: URL
    public let deviceID: String
    public let connection: Connection?
    public let clientIdentity: EmbyClientIdentity
    public let serverKind: MediaServerKind
    private let session: URLSession

    public init(baseURL: URL, deviceID: String, connection: Connection? = nil, clientIdentity: EmbyClientIdentity = .senPlayer,
                serverKind: MediaServerKind = .emby, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.deviceID = deviceID
        self.connection = connection
        self.serverKind = connection?.serverKind ?? serverKind
        // Keep legacy saved sessions on their original identity; only new logins use the default.
        self.clientIdentity = self.serverKind == .jellyfin ? .muxi : connection.map { $0.clientIdentity ?? .muxi } ?? clientIdentity
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        self.session = session ?? URLSession(configuration: config, delegate: SameOriginRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: ServerAddress.endpoint(base: baseURL, path: path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MuxiPlayer/0.1.0", forHTTPHeaderField: "User-Agent")
        if serverKind == .jellyfin {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed)! }
            var authorization = "MediaBrowser Client=\"\(encoded(clientIdentity.rawValue))\", Device=\"Mac\", DeviceId=\"\(encoded(deviceID))\", Version=\"0.1.0\""
            if let connection { authorization += ", Token=\"\(encoded(connection.token))\"" }
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Emby Client=\"\(clientIdentity.rawValue)\", Device=\"Mac\", DeviceId=\"\(deviceID)\", Version=\"0.1.0\"", forHTTPHeaderField: "Authorization")
            if let connection { request.setValue(connection.token, forHTTPHeaderField: "X-Emby-Token") }
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        if response.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge" { throw EmbyError.webChallenge }
        if response.mimeType == "text/html", response.value(forHTTPHeaderField: "Server")?.lowercased().contains("cloudflare") == true {
            // Some gateways strip cf-mitigated; inspect only known challenge markup, never expose the response body.
            let html = String(decoding: data.prefix(32_768), as: UTF8.self).lowercased()
            if html.contains("/cdn-cgi/challenge-platform/") || html.contains("cf-error-details") { throw EmbyError.webChallenge }
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401: throw EmbyError.unauthorized
        case 403: throw EmbyError.forbidden
        default: throw EmbyError.http(response.statusCode)
        }
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: await data(for: request(path, query: query)))
    }

    public func authenticate(username: String, password: String) async throws -> Connection {
        let data = try await data(for: request("Users/AuthenticateByName", method: "POST", body: ["Username": username, "Pw": password]))
        let auth = try JSONDecoder().decode(Authentication.self, from: data)
        guard !auth.AccessToken.isEmpty, !auth.User.Id.isEmpty else { throw EmbyError.invalidResponse }
        return Connection(baseURL: baseURL, authentication: auth, clientIdentity: clientIdentity, serverKind: serverKind)
    }

    private var userPath: String { "Users/\(connection?.user.Id ?? "")" }

    public func libraries() async throws -> [MediaItem] {
        let page: ItemPage = try await get("\(userPath)/Views", query: [
            .init(name: "EnableImages", value: "true"), .init(name: "ImageTypeLimit", value: "1")
        ])
        return page.Items
    }

    public func resume() async throws -> [MediaItem] {
        let page: ItemPage = try await get("\(userPath)/Items/Resume", query: [
            .init(name: "Limit", value: "18"), .init(name: "MediaTypes", value: "Video"), .init(name: "Fields", value: "Overview,ProductionYear,CommunityRating"),
            .init(name: "EnableImages", value: "true"), .init(name: "ImageTypeLimit", value: "1")
        ])
        return page.Items
    }

    public func items(parent: String? = nil, type: String? = nil, search: String = "", start: Int = 0, recursive: Bool = true,
                      limit: Int = 60, sortBy: String? = nil, descending: Bool = false,
                      favoritesOnly: Bool = false, unplayedOnly: Bool = false, metadataOnly: Bool = false) async throws -> ItemPage {
        var query: [URLQueryItem] = [
            .init(name: "Fields", value: metadataOnly ? "Genres,ProductionLocations,ProductionYear,CommunityRating,DateCreated,SortName,OriginalTitle" : "Overview,PrimaryImageAspectRatio,ProductionYear,CommunityRating"), .init(name: "EnableUserData", value: "true"),
            .init(name: "EnableImages", value: "true"), .init(name: "ImageTypeLimit", value: "1"),
            .init(name: "StartIndex", value: String(start)), .init(name: "Limit", value: String(limit)),
            .init(name: "Recursive", value: String(recursive)),
            .init(name: "SortBy", value: sortBy ?? (recursive ? "SortName" : "ParentIndexNumber,IndexNumber,SortName")),
            .init(name: "SortOrder", value: descending ? "Descending" : "Ascending")
        ]
        if let parent { query.append(.init(name: "ParentId", value: parent)) }
        if let type { query.append(.init(name: "IncludeItemTypes", value: type)) }
        if !search.isEmpty { query.append(.init(name: "SearchTerm", value: search)) }
        let filters = [(favoritesOnly, "IsFavorite"), (unplayedOnly, "IsUnplayed")].filter { $0.0 }.map { $0.1 }
        if !filters.isEmpty { query.append(.init(name: "Filters", value: filters.joined(separator: ","))) }
        return try await get("\(userPath)/Items", query: query)
    }

    public func item(id: String) async throws -> MediaItem { try await get("\(userPath)/Items/\(id)") }

    public func setFavorite(itemID: String, isFavorite: Bool) async throws -> UserData {
        guard connection != nil else { throw EmbyError.unauthorized }
        let data = try await data(for: request("\(userPath)/FavoriteItems/\(itemID)", method: isFavorite ? "POST" : "DELETE"))
        let updated = try JSONDecoder().decode(UserData.self, from: data)
        guard updated.IsFavorite != nil else { throw EmbyError.invalidResponse }
        return updated
    }

    public func mediaSources(itemID: String, engine: PlaybackEngine = .avPlayer) async throws -> [MediaSource] {
        guard let connection else { throw EmbyError.unauthorized }
        let body = PlaybackRequest.body(userID: connection.user.Id, settings: .init(), sourceID: nil, engine: engine, isPlayback: false)
        let info = try JSONDecoder().decode(PlaybackInfo.self, from: await data(for: request("Items/\(itemID)/PlaybackInfo", method: "POST", body: body)))
        guard info.ErrorCode == nil else { throw EmbyError.noPlayableSource }
        return info.MediaSources ?? []
    }

    public func playback(itemID: String, settings: PlaybackSettings, sourceID: String? = nil,
                         engine: PlaybackEngine = .avPlayer) async throws -> PlaybackPlan {
        guard let connection else { throw EmbyError.unauthorized }
        if settings.requiresServerConversion(engine: engine), let policy = connection.user.Policy {
            let allConversionDenied = policy.EnableVideoPlaybackTranscoding == false
                && policy.EnableAudioPlaybackTranscoding == false && policy.EnablePlaybackRemuxing == false
            let videoConversionDenied = engine == .mpv && policy.EnableVideoPlaybackTranscoding == false
            if allConversionDenied || videoConversionDenied { throw EmbyError.conversionUnavailable }
        }
        let body = PlaybackRequest.body(userID: connection.user.Id, settings: settings, sourceID: sourceID, engine: engine)
        let info = try JSONDecoder().decode(PlaybackInfo.self, from: await data(for: request("Items/\(itemID)/PlaybackInfo", method: "POST", body: body)))
        return try PlaybackRequest.plan(info: info, itemID: itemID, settings: settings, base: baseURL, token: connection.token, deviceID: deviceID, sourceID: sourceID, engine: engine, serverKind: serverKind)
    }

    public func externalSubtitleURL(for stream: MediaStream) throws -> URL? {
        guard stream.Type == "Subtitle",
              stream.IsExternal == true || stream.IsExternalUrl == true || stream.DeliveryMethod == "External",
              let raw = stream.DeliveryUrl, !raw.isEmpty else { return nil }
        guard let connection else { throw EmbyError.unauthorized }
        return try ServerAddress.stream(raw, base: baseURL, token: connection.token, serverKind: serverKind)
    }

    public func report(_ event: String, itemID: String, plan: PlaybackPlan, ticks: Int64, paused: Bool, settings: PlaybackSettings) async throws {
        var body: [String: Any] = ["ItemId": itemID, "MediaSourceId": plan.source.Id, "PlaySessionId": plan.sessionID,
                                  "PositionTicks": ticks, "IsPaused": paused, "CanSeek": true, "PlayMethod": plan.method,
                                  "SubtitleStreamIndex": settings.subtitleIndex]
        if let audio = settings.audioIndex ?? plan.source.DefaultAudioStreamIndex { body["AudioStreamIndex"] = audio }
        if event == "Progress" { body["EventName"] = "TimeUpdate" }
        let suffix = event.isEmpty ? "" : "/" + event
        _ = try await data(for: request("Sessions/Playing" + suffix, method: "POST", body: body))
    }

    public func stopTranscoding(sessionID: String) async throws {
        _ = try await data(for: request("Videos/ActiveEncodings", query: [.init(name: "DeviceId", value: deviceID), .init(name: "PlaySessionId", value: sessionID)], method: "DELETE"))
    }

    public func logout() async throws { _ = try await data(for: request("Sessions/Logout", method: "POST")) }

    public func imageRequest(item: MediaItem, backdrop: Bool = false) throws -> URLRequest? {
        if backdrop, let tag = item.BackdropImageTags?.first {
            return try request("Items/\(item.Id)/Images/Backdrop/0", query: [.init(name: "MaxWidth", value: "1280"), .init(name: "Tag", value: tag), .init(name: "Quality", value: "85")])
        }
        guard let tag = item.ImageTags?["Primary"] else { return nil }
        return try request("Items/\(item.Id)/Images/Primary", query: [.init(name: "MaxWidth", value: "400"), .init(name: "Tag", value: tag), .init(name: "Quality", value: "90")])
    }
}
