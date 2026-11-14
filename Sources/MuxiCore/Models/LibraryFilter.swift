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

public enum LibraryResolution: String, CaseIterable {
    case uhd = "4K", fullHD = "1080p", hd = "720p", sd = "标清", bluray = "蓝光", unknown = "未标注"
}
public enum LibraryVideoRange: String, CaseIterable {
    case dolbyVision = "杜比视界", hdr10 = "HDR10", hlg = "HLG", sdr = "SDR", unknown = "未标注"
}
public enum LibraryAudio: String, CaseIterable {
    case atmos = "杜比全景声", dolby = "杜比音频", lossless = "无损音频", dts = "DTS", aac = "AAC", unknown = "未标注"
}
public enum LibraryRegion: String, CaseIterable {
    case mainland = "大陆", hongKongTaiwan = "港台", western = "欧美", japanKorea = "日韩", other = "其他地区"
    func matches(_ countries: [String]) -> Bool {
        let countries = Set(countries.map { $0.lowercased() })
        let mainland: Set<String> = ["china", "cn", "中国", "中国大陆", "mainland china"]
        let hk: Set<String> = ["hong kong", "taiwan", "香港", "台湾", "中国香港", "中国台湾", "hk", "tw"]
        let jp: Set<String> = ["japan", "south korea", "korea", "日本", "韩国", "jp", "kr"]
        let west: Set<String> = ["united states", "united states of america", "usa", "us", "united kingdom", "uk", "gb", "france", "germany", "italy", "spain", "canada", "sweden", "norway", "denmark", "finland", "iceland", "netherlands", "belgium", "switzerland", "austria", "ireland", "poland", "russia", "czech republic", "portugal", "greece", "美国", "英国", "法国", "德国", "意大利", "西班牙", "加拿大", "俄罗斯", "瑞典", "挪威", "丹麦", "芬兰", "冰岛", "荷兰", "比利时", "瑞士", "奥地利", "爱尔兰", "波兰", "葡萄牙", "希腊", "捷克"]
        switch self {
        case .mainland: return !countries.isDisjoint(with: mainland)
        case .hongKongTaiwan: return !countries.isDisjoint(with: hk)
        case .japanKorea: return !countries.isDisjoint(with: jp)
        case .western: return !countries.isDisjoint(with: west)
        case .other: return !countries.isEmpty && countries.isDisjoint(with: mainland.union(hk).union(jp).union(west))
        }
    }
}

public struct LibraryFilter: Hashable {
    public var sort: LibrarySort = .added
    public var year: Int?
    public var decade: Int?
    public var genre: String?
    public var country: String?
    public var region: LibraryRegion?
    public var played: Bool?
    public var kind: String?
    public var resolution: LibraryResolution?
    public var videoRange: LibraryVideoRange?
    public var audio: LibraryAudio?
    public init() {}
    public var isActive: Bool {
        year != nil || decade != nil || genre != nil || country != nil || region != nil || played != nil ||
        kind != nil || resolution != nil || videoRange != nil || audio != nil
    }

    public func apply(to items: [MediaItem], search: String = "") -> [MediaItem] {
        items.filter { item in
            (year == nil || item.ProductionYear == year) &&
            (decade == nil || item.ProductionYear.map { decade == -1 ? $0 < 1980 : ($0 >= decade! && $0 < decade! + 10) } == true) &&
            (genre == nil || item.Genres?.contains(genre!) == true) &&
            (country == nil || (country == "" ? (item.ProductionLocations ?? []).isEmpty : item.ProductionLocations?.contains(country!) == true)) &&
            (region == nil || region!.matches(item.ProductionLocations ?? [])) &&
            (played == nil || (item.UserData?.Played ?? false) == played) &&
            (kind == nil || item.Type == kind) &&
            (resolution == nil || item.matches(resolution!)) &&
            (videoRange == nil || item.matches(videoRange!)) &&
            (audio == nil || item.matches(audio!)) &&
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

private extension MediaItem {
    var videos: [MediaStream] { (MediaStreams ?? []).filter { $0.Type == "Video" } }
    var audios: [MediaStream] { (MediaStreams ?? []).filter { $0.Type == "Audio" } }
    func matches(_ resolution: LibraryResolution) -> Bool {
        if resolution == .bluray { return VideoType?.lowercased() == "bluray" }
        let width = videos.compactMap(\.Width).max() ?? Width ?? 0
        let height = videos.compactMap(\.Height).max() ?? Height ?? 0
        switch resolution {
        case .uhd: return width >= 3800 || height >= 2100
        case .fullHD: return (width >= 1900 || height >= 1000) && width < 3800 && height < 2100
        case .hd: return (width >= 1200 || height >= 700) && width < 1900 && height < 1000
        case .sd: return width > 0 && width < 1200 && height < 700
        case .unknown: return width == 0 && height == 0
        case .bluray: return false
        }
    }
    func matches(_ range: LibraryVideoRange) -> Bool {
        let values = videos.map { stream -> LibraryVideoRange in
            let hint = [stream.VideoRangeType, stream.VideoRange, stream.ExtendedVideoType, stream.ExtendedVideoSubType, stream.ColorTransfer].compactMap { $0 }.joined(separator: " ").lowercased()
            if (stream.DvProfile ?? 0) > 0 || hint.contains("dovi") || hint.contains("dolbyvision") || hint.contains("dolby vision") { return .dolbyVision }
            if hint.contains("hlg") || hint.contains("hyperloggamma") || hint.contains("arib") { return .hlg }
            if hint.contains("hdr") || hint.contains("smpte2084") { return .hdr10 }
            if hint.contains("sdr") || hint.contains("bt709") { return .sdr }
            return .unknown
        }
        return values.isEmpty ? range == .unknown : values.contains(range)
    }
    func matches(_ audio: LibraryAudio) -> Bool {
        if audio == .unknown { return audios.isEmpty }
        return audios.contains { stream in
            let codec = stream.Codec?.lowercased() ?? ""
            let hint = [stream.Profile, stream.Title, stream.DisplayTitle].compactMap { $0 }.joined(separator: " ").lowercased()
            switch audio {
            case .atmos: return hint.contains("atmos")
            case .dolby: return ["ac3", "eac3", "truehd"].contains(codec)
            case .lossless: return ["truehd", "flac", "alac", "pcm_s16le", "pcm_s24le"].contains(codec) || hint.contains("dts-hd ma")
            case .dts: return codec.hasPrefix("dts")
            case .aac: return codec == "aac"
            case .unknown: return false
            }
        }
    }
}
