import Foundation

// Wire models keep Emby's field names so optional server fields stay explicit.
public struct MediaItem: Decodable, Identifiable, Hashable {
    public let Id: String
    public let Name: String
    public var `Type`: String?
    public var Overview: String?
    public var ProductionYear: Int?
    public var CommunityRating: Double?
    public var RunTimeTicks: Int64?
    public var SeriesName: String?
    public var IndexNumber: Int?
    public var ParentIndexNumber: Int?
    public var ImageTags: [String: String]?
    public var BackdropImageTags: [String]?
    public var UserData: UserData?
    public var IsFolder: Bool?
    public var Genres: [String]?
    public var ProductionLocations: [String]?
    public var DateCreated: String?
    public var SortName: String?
    public var OriginalTitle: String?

    public var id: String { Id }
    public var isContainer: Bool { IsFolder == true || ["Series", "Season", "CollectionFolder", "BoxSet", "Folder"].contains(Type ?? "") }
    public var isFavorite: Bool { UserData?.IsFavorite == true }
    public var resumeTicks: Int64 { max(0, UserData?.PlaybackPositionTicks ?? 0) }
    public var subtitle: String {
        if Type == "Episode" {
            return [SeriesName, ParentIndexNumber.map { "第 \($0) 季" }, IndexNumber.map { "第 \($0) 集" }].compactMap { $0 }.joined(separator: " · ")
        }
        return [ProductionYear.map(String.init), RunTimeTicks.map { "\($0 / 600_000_000) 分钟" }].compactMap { $0 }.joined(separator: " · ")
    }
}

public struct UserData: Decodable, Hashable {
    public var PlaybackPositionTicks: Int64?
    public var PlayedPercentage: Double?
    public var Played: Bool?
    public var IsFavorite: Bool?

    public init(playbackPositionTicks: Int64? = nil, playedPercentage: Double? = nil, played: Bool? = nil, isFavorite: Bool? = nil) {
        PlaybackPositionTicks = playbackPositionTicks
        PlayedPercentage = playedPercentage
        Played = played
        IsFavorite = isFavorite
    }
}

public struct ItemPage: Decodable {
    public let Items: [MediaItem]
    public var TotalRecordCount: Int?
    public init(Items: [MediaItem], TotalRecordCount: Int?) {
        self.Items = Items
        self.TotalRecordCount = TotalRecordCount
    }
}

public struct EmbyUser: Codable {
    public let Id: String
    public let Name: String
    public let Policy: EmbyUserPolicy?
}

public struct EmbyUserPolicy: Codable {
    public let EnableVideoPlaybackTranscoding: Bool?
    public let EnableAudioPlaybackTranscoding: Bool?
    public let EnablePlaybackRemuxing: Bool?
}

public struct Authentication: Decodable {
    public let AccessToken: String
    public let User: EmbyUser
    public var ServerId: String?
}

public enum EmbyClientIdentity: String, Codable, CaseIterable {
    case senPlayer = "SenPlayer"
    case infuse = "Infuse"
    case muxi = "Muxi Player"

    public var label: String {
        switch self {
        case .infuse: return "Infuse 兼容"
        case .senPlayer: return "SenPlayer 兼容（默认）"
        case .muxi: return "muxi 原生标识"
        }
    }
}

public enum MediaServerKind: String, Codable, CaseIterable {
    case emby, jellyfin
    public var label: String { self == .emby ? "Emby" : "Jellyfin" }
}

public struct Connection: Codable {
    public let baseURL: URL
    public let token: String
    public let user: EmbyUser
    public let serverID: String?
    public let clientIdentity: EmbyClientIdentity?
    public let serverKind: MediaServerKind?

    public init(baseURL: URL, authentication: Authentication, clientIdentity: EmbyClientIdentity = .senPlayer, serverKind: MediaServerKind = .emby) {
        self.baseURL = baseURL
        self.clientIdentity = serverKind == .jellyfin ? .muxi : clientIdentity
        self.serverKind = serverKind
        token = authentication.AccessToken
        user = authentication.User
        serverID = authentication.ServerId
    }
}

public struct PlaybackInfo: Decodable {
    public var MediaSources: [MediaSource]?
    public var PlaySessionId: String?
    public var ErrorCode: String?
}

public struct MediaSource: Decodable, Identifiable {
    public let Id: String
    public var Name: String?
    public var Container: String?
    public var Bitrate: Int?
    public var Size: Int64?
    public var SupportsDirectPlay: Bool?
    public var SupportsDirectStream: Bool?
    public var SupportsTranscoding: Bool?
    public var DirectStreamUrl: String?
    public var TranscodingUrl: String?
    public var MediaStreams: [MediaStream]?
    public var DefaultAudioStreamIndex: Int?
    public var DefaultSubtitleStreamIndex: Int?
    public var RunTimeTicks: Int64?
    public var RequiresOpening: Bool?
    public var id: String { Id }
    public var playbackLabel: String {
        [Name ?? Id, MediaStreams?.first { $0.Type == "Video" }?.Height.map { "\($0)p" },
         Bitrate.map { String(format: "%.1f Mbps", Double($0) / 1_000_000) }].compactMap { $0 }.joined(separator: " · ")
    }
}

public struct MediaStream: Decodable, Identifiable {
    public let Index: Int
    public let `Type`: String
    public var DisplayTitle: String?
    public var Title: String?
    public var Language: String?
    public var Codec: String?
    public var Channels: Int?
    public var Width: Int?
    public var Height: Int?
    public var BitRate: Int?
    public var IsExternal: Bool?
    public var IsDefault: Bool?
    public var IsForced: Bool?
    public var DeliveryMethod: String?
    public var DeliveryUrl: String?
    public var DeliveryFormat: String?
    public var IsExternalUrl: Bool?
    public var id: Int { Index }
    public var label: String { DisplayTitle ?? Title ?? [Language, Codec?.uppercased()].compactMap { $0 }.joined(separator: " · ") }
}

public enum PlaybackEngine {
    case avPlayer, mpv
}

public struct PlaybackSettings: Equatable {
    public var audioIndex: Int?
    public var subtitleIndex: Int = -1
    public var maxHeight: Int = 0
    public var maxBitrate: Int = 0
    public init() {}
    public var requiresConversion: Bool { requiresServerConversion(engine: .avPlayer) }
    public func requiresServerConversion(engine: PlaybackEngine) -> Bool {
        maxHeight > 0 || maxBitrate > 0 || (engine == .avPlayer && (subtitleIndex >= 0 || audioIndex != nil))
    }
    public static let resolutions = [0, 2160, 1080, 720, 480]
    public static let bitrates = [0, 80_000_000, 40_000_000, 20_000_000, 10_000_000, 5_000_000, 2_000_000]
}

public struct PlaybackPlan {
    public let url: URL
    public let source: MediaSource
    public let sessionID: String
    public let method: String
}

public enum PlaybackTime {
    public static func ticks(_ seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(min(seconds * 10_000_000, Double(Int64.max / 2)))
    }
    public static func label(_ seconds: Double) -> String {
        let value = Int(min(max(seconds.isFinite ? seconds : 0, 0), 864_000))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
