import Foundation

public struct ViewingSite: Codable, Identifiable, Hashable {
    public enum Kind: String, Codable, CaseIterable {
        case web, emby, jellyfin, cms, archive, reference

        public var label: String {
            switch self {
            case .web: return "观影网站"
            case .emby: return "Emby"
            case .jellyfin: return "Jellyfin"
            case .cms: return "CMS 接口"
            case .archive: return "公开档案"
            case .reference: return "资讯与开通"
            }
        }
    }

    public let id: UUID
    public var name: String
    public var url: URL
    public var kind: Kind
    public var enabled: Bool
    public var isDefault: Bool
    public var note: String
    public var collection: String?

    public init(id: UUID = UUID(), name: String, url: URL, kind: Kind = .web,
                enabled: Bool = true, isDefault: Bool = false, note: String = "", collection: String? = nil) {
        self.id = id; self.name = name; self.url = url; self.kind = kind
        self.enabled = enabled; self.isDefault = isDefault; self.note = note; self.collection = collection
    }

    public var monitored: Bool { enabled && kind != .reference }
    public var canAutoOpen: Bool { monitored && kind == .web }

    public static func checkedURL(_ value: String) throws -> URL {
        let url = try OnlineCatalogClient.checkedURL(value)
        guard url.port == nil || (1...65535).contains(url.port!) else { throw EmbyError.invalidAddress }
        return url
    }

    public static func addressKey(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased(); parts.fragment = nil
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string ?? url.absoluteString
    }

    public static func mergingDefaults(into saved: [ViewingSite]) -> [ViewingSite] {
        saved + defaults.filter { preset in
            !saved.contains { $0.id == preset.id || addressKey($0.url) == addressKey(preset.url) }
        }
    }

    public static let defaults: [ViewingSite] = [
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000001")!, name: "可可影视 · Jeffern", url: URL(string: "https://www.kkys20.com/")!, isDefault: true),
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000002")!, name: "OmoFun · Jeffern", url: URL(string: "https://omofun.in/")!, isDefault: true),
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000003")!, name: "注视影视 · Jeffern", url: URL(string: "https://gaze.red/")!, isDefault: true),
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000004")!, name: "爱迪影视 · Jeffern", url: URL(string: "https://adys.tv/")!, isDefault: true),
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000005")!, name: "CCTV 直播", url: URL(string: "https://tv.cctv.com/live/")!, isDefault: true),
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000006")!, name: "LibreTV 演示站", url: URL(string: "https://tv.bagiinlink.eu.org/")!, isDefault: true,
              note: "LibreTV 项目公布的演示入口，访问方式见项目说明。可用性以检测结果为准。"),
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000007")!, name: "鹿院 Emby · Jeffern", url: URL(string: "https://dongman.theluyuan.com/")!, kind: .emby, isDefault: true,
              note: "参考项目公布的入口，使用站方提供的有效账号连接，开放情况和客户端要求以站方为准。"),
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000008")!, name: "Jellyfin 官方演示", url: URL(string: "https://demo.jellyfin.org/stable/")!, kind: .jellyfin, isDefault: true,
              note: "官方测试媒体演示，登录方式见 Jellyfin 官网。"),
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000009")!, name: "Emby 公益服指北", url: URL(string: "https://wiki.freeembyguide.eu.org/")!, kind: .reference, isDefault: true,
              note: "查看公益服介绍和开通要求，取得个人账号后可添加 Emby / Jellyfin。"),
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000010")!, name: "终点站公告", url: URL(string: "https://t.me/s/embypub")!, kind: .reference, isDefault: true,
              note: "查看站方最新公告、账号开放与保号条件。"),
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000011")!, name: "LibreTV 项目与部署", url: URL(string: "https://github.com/LibreSpark/LibreTV")!, kind: .reference, isDefault: true),
        .init(id: UUID(uuidString: "76260000-1117-4000-8000-000000000012")!, name: "Jeffern / Joyflix 项目", url: URL(string: "https://github.com/jeffernn/Joyflix-Mac-Objective-C")!, kind: .reference, isDefault: true)
    ]
}

public struct SiteHealth: Codable, Equatable {
    public enum Status: String, Codable {
        case unknown, online, offline, error
        public var label: String {
            switch self {
            case .unknown: return "待检测"
            case .online: return "在线"
            case .offline: return "离线"
            case .error: return "错误"
            }
        }
    }
    public var status: Status
    public var milliseconds: Int?
    public var checkedAt: Date?
    public var failures: Int
    public var message: String?

    public init(status: Status = .unknown, milliseconds: Int? = nil, checkedAt: Date? = nil,
                failures: Int = 0, message: String? = nil) {
        self.status = status; self.milliseconds = milliseconds; self.checkedAt = checkedAt
        self.failures = failures; self.message = message
    }

    public func following(_ previous: SiteHealth?) -> SiteHealth {
        var next = self
        next.failures = status == .online ? 0 : (previous?.failures ?? 0) + 1
        return next
    }

    public static func sorted(_ sites: [ViewingSite], health: [UUID: SiteHealth]) -> [ViewingSite] {
        sites.sorted { a, b in
            let left = health[a.id] ?? SiteHealth(), right = health[b.id] ?? SiteHealth()
            if (left.status == .online) != (right.status == .online) { return left.status == .online }
            if left.status == .online, left.milliseconds != right.milliseconds {
                return (left.milliseconds ?? .max) < (right.milliseconds ?? .max)
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
