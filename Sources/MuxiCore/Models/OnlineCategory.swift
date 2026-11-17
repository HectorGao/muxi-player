import Foundation

public enum OnlineCatalogScope: String, Codable {
    case all, movies, series

    public init(selection: String) { self = Self(rawValue: selection) ?? .all }
    public var label: String {
        switch self {
        case .all: return "内容"
        case .movies: return "电影"
        case .series: return "剧集"
        }
    }

    public var mediaType: String? {
        switch self {
        case .all: return nil
        case .movies: return "Movie"
        case .series: return "Series"
        }
    }
}

public struct OnlineCategory: Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let parentID: String?

    public init(id: String, name: String, parentID: String? = nil) {
        self.id = id; self.name = name; self.parentID = parentID == "0" ? nil : parentID
    }

    public static func mediaType(name: String) -> String? {
        if name.contains("解说") || name.contains("预告") || name.contains("体育") || name.contains("赛事") { return "Video" }
        if name.contains("电影") || name.hasSuffix("片") { return "Movie" }
        if name.contains("剧") || name.contains("动漫") || name.contains("综艺") { return "Series" }
        return nil
    }

    public static func mediaType(id: String, in categories: [OnlineCategory]) -> String? {
        var current = categories.first { $0.id == id }
        var seen = Set<String>()
        while let category = current, seen.insert(category.id).inserted {
            if let type = mediaType(name: category.name) { return type }
            current = category.parentID.flatMap { parent in categories.first { $0.id == parent } }
        }
        return nil
    }

    public static func ids(for scope: OnlineCatalogScope, in categories: [OnlineCategory]) -> [String] {
        guard scope != .all else { return [] }
        return categories.filter { mediaType(id: $0.id, in: categories) == scope.mediaType }.map(\.id)
    }
}
