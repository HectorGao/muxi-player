import Foundation

public enum LibrarySort: String, CaseIterable {
    case added, newest, oldest, rating, name
    public var label: String {
        switch self {
        case .added: return "最近添加"
        case .newest: return "年份从新到旧"
        case .oldest: return "年份从旧到新"
        case .rating: return "评分从高到低"
        case .name: return "名称 A–Z"
        }
    }
    public var field: String {
        switch self {
        case .added: return "DateCreated"
        case .newest, .oldest: return "ProductionYear"
        case .rating: return "CommunityRating"
        case .name: return "SortName"
        }
    }
    public var descending: Bool { self != .name && self != .oldest }
}

public struct LibraryFilter: Hashable {
    public var sort: LibrarySort = .added
    public var year: Int?
    public var genre: String?
    // nil means all countries; an empty string means missing server metadata.
    public var country: String?
    public var played: Bool?
    public init() {}
    public var isActive: Bool { year != nil || genre != nil || country != nil || played != nil }

    public func apply(to items: [MediaItem], search: String = "") -> [MediaItem] {
        items.filter { item in
            (year == nil || item.ProductionYear == year) &&
            (genre == nil || item.Genres?.contains(genre!) == true) &&
            (country == nil || (country == "" ? (item.ProductionLocations ?? []).isEmpty : item.ProductionLocations?.contains(country!) == true)) &&
            (played == nil || (item.UserData?.Played ?? false) == played) &&
            (search.isEmpty || item.Name.localizedStandardContains(search) || item.OriginalTitle?.localizedStandardContains(search) == true)
        }.sorted { lhs, rhs in
            func compare<T: Comparable>(_ a: T?, _ b: T?) -> Bool {
                if a == b { return lhs.id < rhs.id }
                guard let a else { return false }
                guard let b else { return true }
                return sort.descending ? a > b : a < b
            }
            switch sort {
            case .added: return compare(lhs.DateCreated, rhs.DateCreated)
            case .newest, .oldest: return compare(lhs.ProductionYear, rhs.ProductionYear)
            case .rating: return compare(lhs.CommunityRating, rhs.CommunityRating)
            case .name:
                let order = (lhs.SortName ?? lhs.Name).localizedStandardCompare(rhs.SortName ?? rhs.Name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
        }
    }
}
